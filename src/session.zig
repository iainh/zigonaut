const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");
const Search = @import("search.zig").State;
const SearchMatch = @import("search.zig").Match;
const win = @import("win32.zig").c;
const log = std.log.scoped(.session);
const reader_buffer_bytes = 16 * 1024;
const feed_chunk_bytes = 4 * 1024;
const pty_write_queue_max_bytes = 8 * 1024 * 1024;
const synchronized_output_timeout_ms = 1000;
const notification_max_bytes = 4096;

/// Heap-owned runtime with a stable address shared by Win32 and the reader thread.
/// Call `destroy` only after no caller can submit input or rendering work.
pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    pty: ?Pty = null,
    reader_thread: ?std.Thread = null,
    writer_thread: ?std.Thread = null,
    refresh: Refresh,
    terminal_mutex: @import("win32.zig").Mutex = .{},
    pty_queue_mutex: @import("win32.zig").Mutex = .{},
    pty_writer_generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    pty_operations: std.ArrayList(PtyOperation) = .empty,
    outstanding_input_bytes: usize = 0,
    render_handoff: RenderHandoff = .{},
    closing: bool = false,
    writer_failed: bool = false,
    content_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    output_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    synchronized_output: SynchronizedOutput = .{},
    search_content_generation: u64 = 0,
    title: std.ArrayList(u8) = .empty,
    title_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    search: Search = .{},
    taskbar_progress: ?TaskbarProgress = null,
    progress_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    notifications: NotificationQueue = .{},
    clipboard_write_enabled: bool = false,
    clipboard_write_max_bytes: u32 = 1024 * 1024,
    pending_clipboard_write: ?PendingClipboardWrite = null,
    snapshot_mutex: @import("win32.zig").Mutex = .{},
    render_snapshot: Terminal.RenderSnapshot = .{},
    render_scroll_offset: usize = 0,
    // Search state is UI-thread-owned. The reader thread only changes terminal
    // content and generations, so synchronous rendering can borrow these lists.
    search_cache: Terminal.SearchCache = .{},
    search_cache_generation: u64 = std.math.maxInt(u64),
    link_scratch: Terminal.LinkScratch = .{},
    columns: u16,
    rows: u16,
    cell_width: u32 = 0,
    cell_height: u32 = 0,

    pub const Refresh = struct {
        callback: ?*const fn (?*anyopaque) void = null,
        context: ?*anyopaque = null,

        fn request(self: Refresh) void {
            if (self.callback) |callback| callback(self.context);
        }
    };

    const RenderHandoff = struct {
        demand: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        fn lock(self: *RenderHandoff, mutex: *@import("win32.zig").Mutex) void {
            _ = self.demand.fetchAdd(1, .monotonic);
            mutex.lock();
            _ = self.demand.fetchSub(1, .monotonic);
        }

        fn unlock(self: *RenderHandoff, mutex: *@import("win32.zig").Mutex) void {
            mutex.unlock();
            _ = self.generation.fetchAdd(1, .monotonic);
            std.os.windows.ntdll.RtlWakeAddressSingle(@ptrCast(&self.generation));
        }

        /// Give a waiting renderer one bounded opportunity to acquire the
        /// unfair SRW lock before the PTY reader begins its next read.
        fn yield(self: *RenderHandoff) void {
            if (self.demand.load(.monotonic) == 0) return;
            const generation = self.generation.load(.monotonic);
            if (self.demand.load(.monotonic) == 0) return;
            var expected = generation;
            var timeout: std.os.windows.LARGE_INTEGER = -10_000;
            _ = std.os.windows.ntdll.RtlWaitOnAddress(
                @ptrCast(&self.generation),
                @ptrCast(&expected),
                @sizeOf(u32),
                &timeout,
            );
        }
    };

    pub const TaskbarProgress = struct {
        state: Terminal.ProgressState,
        value: u8,
        updated_tick: u64,
    };

    pub const SearchTickResult = struct {
        changed: bool,
        scanning: bool,
    };

    pub const SearchStatus = struct {
        matches: usize,
        active: ?usize,
        scanning: bool,
    };

    const SynchronizedOutput = struct {
        deadline_tick: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        fn update(self: *SynchronizedOutput, enabled: bool, now: u64) bool {
            const deadline = self.deadline_tick.load(.acquire);
            if (enabled) {
                if (deadline != 0) return false;
                self.deadline_tick.store(now +| synchronized_output_timeout_ms, .release);
                return true;
            }
            if (deadline == 0) return false;
            self.deadline_tick.store(0, .release);
            return true;
        }

        fn remaining(self: *const SynchronizedOutput, now: u64) ?u32 {
            const deadline = self.deadline_tick.load(.acquire);
            if (deadline == 0) return null;
            if (deadline <= now) return 0;
            return @intCast(@min(deadline - now, std.math.maxInt(u32)));
        }

        fn clear(self: *SynchronizedOutput) void {
            self.deadline_tick.store(0, .release);
        }
    };

    pub const Notification = struct {
        payload: []u8,
        title_len: u16,

        pub fn title(self: Notification) []const u8 {
            return self.payload[0..self.title_len];
        }

        pub fn body(self: Notification) []const u8 {
            return self.payload[self.title_len..];
        }

        pub fn deinit(self: Notification, allocator: std.mem.Allocator) void {
            allocator.free(self.payload);
        }
    };

    const NotificationQueue = struct {
        const capacity = 32;
        slots: std.ArrayList(Notification) = .empty,
        head: usize = 0,
        count: usize = 0,

        fn assertValid(self: *const NotificationQueue) void {
            std.debug.assert(self.count <= capacity);
            std.debug.assert(self.head < capacity);
            std.debug.assert(self.slots.items.len == 0 or self.slots.items.len == capacity);
            if (self.count == 0) std.debug.assert(self.head == 0);
        }

        fn deinit(self: *NotificationQueue, allocator: std.mem.Allocator) void {
            self.assertValid();
            while (self.pop()) |notification| notification.deinit(allocator);
            self.slots.deinit(allocator);
            self.* = .{};
        }

        fn push(self: *NotificationQueue, allocator: std.mem.Allocator, notification: Notification) !void {
            self.assertValid();
            if (self.slots.items.len == 0) try self.slots.resize(allocator, capacity);
            if (self.count == capacity) {
                self.slots.items[self.head].deinit(allocator);
                self.slots.items[self.head] = notification;
                self.head = (self.head + 1) % capacity;
                self.assertValid();
                return;
            }
            const index = (self.head + self.count) % capacity;
            self.slots.items[index] = notification;
            self.count += 1;
            self.assertValid();
        }

        fn pop(self: *NotificationQueue) ?Notification {
            self.assertValid();
            if (self.count == 0) return null;
            const notification = self.slots.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            if (self.count == 0) self.head = 0;
            self.assertValid();
            return notification;
        }
    };

    pub const PendingClipboardWrite = union(enum) {
        clear,
        text: []u8,
    };

    const PtySize = struct {
        columns: u16,
        rows: u16,
    };

    const PtyOperation = union(enum) {
        input: std.ArrayList(u8),
        resize: PtySize,

        fn deinit(self: *PtyOperation, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .input => |*input| input.deinit(allocator),
                .resize => {},
            }
        }
    };

    pub fn create(
        allocator: std.mem.Allocator,
        command: []const u8,
        working_directory: []const u8,
        terminal_theme: theme.Theme,
        columns: u16,
        rows: u16,
        refresh: Refresh,
        clipboard_write_enabled: bool,
        clipboard_write_max_bytes: u32,
        scrollback_size: u32,
    ) !*SessionRuntime {
        const self = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .terminal = try Terminal.initWithScrollback(columns, rows, terminal_theme, scrollback_size),
            .refresh = refresh,
            .clipboard_write_enabled = clipboard_write_enabled,
            .clipboard_write_max_bytes = clipboard_write_max_bytes,
            .columns = columns,
            .rows = rows,
        };
        errdefer self.terminal.deinit();
        try self.terminal.setTitleChanged(titleChanged, self);
        try self.terminal.setWritePty(writePty, self);
        try self.terminal.setClipboardWrite(clipboardWrite, self);
        try self.terminal.setDesktopNotification(desktopNotification, self);
        try self.terminal.setProgressReport(progressReport, self);

        self.pty = Pty.spawn(allocator, command, working_directory, columns, rows) catch |err| {
            // Keep a terminal-only session so the pane can show the launch error.
            var message: [256]u8 = undefined;
            const text = std.fmt.bufPrint(
                &message,
                "\x1b[1;31mUnable to start {s}: {s}\x1b[0m\r\n",
                .{ command, @errorName(err) },
            ) catch "Unable to start shell.\r\n";
            self.terminal.feed(text);
            _ = self.content_generation.fetchAdd(1, .monotonic);
            return self;
        };
        errdefer {
            self.pty.?.closeIo();
            self.pty.?.closeConsole();
            self.pty.?.finishClose();
        }

        self.writer_thread = try std.Thread.spawn(.{}, writerMain, .{self});
        self.reader_thread = std.Thread.spawn(.{}, readerMain, .{self}) catch |err| {
            self.requestWriterClose();
            self.writer_thread.?.join();
            self.writer_thread = null;
            return err;
        };
        return self;
    }

    pub fn destroy(self: *SessionRuntime) void {
        if (self.pty) |*pty| {
            self.requestWriterClose();
            while (!workersStopped(self.reader_thread, self.writer_thread)) {
                pty.cancelIo(self.reader_thread, self.writer_thread);
                win.Sleep(1);
            }
            if (self.reader_thread) |thread| thread.join();
            if (self.writer_thread) |thread| thread.join();
            pty.closeIo();
            pty.closeConsole();
            pty.finishClose();
        }
        self.clearPtyOperations();
        self.outstanding_input_bytes = 0;
        self.pty_operations.deinit(self.allocator);
        self.title.deinit(self.allocator);
        if (self.pending_clipboard_write) |pending| self.freePendingClipboardWrite(pending);
        self.notifications.deinit(self.allocator);
        self.search.deinit(self.allocator);
        self.snapshot_mutex.lock();
        self.render_snapshot.deinit(self.allocator);
        self.snapshot_mutex.unlock();
        self.search_cache.deinit(self.allocator);
        self.link_scratch.deinit(self.allocator);
        self.terminal.deinit();
        self.allocator.destroy(self);
    }

    pub fn writeViewportText(self: *SessionRuntime, output: []u8) ![]const u8 {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.writeViewportText(output);
    }

    pub fn setSelection(self: *SessionRuntime, selection: ?Terminal.Selection) !void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        try self.terminal.setSelection(selection);
    }

    pub fn beginSelectionAnchor(self: *SessionRuntime, point: Terminal.Point) !void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.beginSelectionAnchor(point);
    }

    pub fn endSelectionAnchor(self: *SessionRuntime) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.terminal.endSelectionAnchor();
    }

    pub fn setDerivedSelection(self: *SessionRuntime, focus: Terminal.Point, unit: Terminal.SelectionUnit, rectangle: bool) !void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.setDerivedSelection(focus, unit, rectangle);
    }

    pub fn sendMouse(self: *SessionRuntime, action: Terminal.MouseAction, button: Terminal.MouseButton, position: Terminal.PixelPoint, modifiers: u16, geometry: Terminal.MouseGeometry, any_button_pressed: bool) !bool {
        var buffer: [128]u8 = undefined;
        self.terminal_mutex.lock();
        if (!self.terminal.mouseTracking()) {
            self.terminal_mutex.unlock();
            return false;
        }
        const encoded = self.terminal.encodeMouse(action, button, position, modifiers, geometry, any_button_pressed, &buffer) catch |err| {
            self.terminal_mutex.unlock();
            return err;
        };
        self.terminal_mutex.unlock();
        if (encoded.len == 0) return false;
        try self.write(encoded);
        return true;
    }

    pub fn mouseTracking(self: *SessionRuntime) bool {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.mouseTracking();
    }

    pub fn sendMouseWheel(self: *SessionRuntime, button: Terminal.MouseButton, count: usize, position: Terminal.PixelPoint, modifiers: u16, geometry: Terminal.MouseGeometry) !bool {
        if (count == 0) return true;
        const output = try self.allocator.alloc(u8, count * 128);
        defer self.allocator.free(output);
        var written: usize = 0;
        self.terminal_mutex.lock();
        if (!self.terminal.mouseTracking()) {
            self.terminal_mutex.unlock();
            return false;
        }
        for (0..count) |_| {
            const encoded = self.terminal.encodeMouse(.press, button, position, modifiers, geometry, false, output[written .. written + 128]) catch |err| {
                self.terminal_mutex.unlock();
                return err;
            };
            if (encoded.len == 0) {
                self.terminal_mutex.unlock();
                return false;
            }
            written += encoded.len;
        }
        self.terminal_mutex.unlock();
        try self.write(output[0..written]);
        return true;
    }

    pub fn selectedTextAlloc(self: *SessionRuntime, allocator: std.mem.Allocator) ![]u8 {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.selectedTextAlloc(allocator);
    }

    pub fn currentDirectoryAlloc(self: *SessionRuntime, allocator: std.mem.Allocator) !?[]u8 {
        self.terminal_mutex.lock();
        const reported = self.terminal.pwdAlloc(allocator) catch |err| {
            self.terminal_mutex.unlock();
            return err;
        };
        self.terminal_mutex.unlock();
        const value = reported orelse return null;
        defer allocator.free(value);

        var hostname_wide: [256]u16 = undefined;
        var hostname_length: win.DWORD = hostname_wide.len;
        if (win.GetComputerNameW(&hostname_wide, &hostname_length) == 0) return null;
        var hostname_utf8: [256 * 3]u8 = undefined;
        const utf8_length = std.unicode.utf16LeToUtf8(&hostname_utf8, hostname_wide[0..hostname_length]) catch return null;
        return osc7WindowsPathAlloc(allocator, value, hostname_utf8[0..utf8_length]);
    }

    pub fn linkAtAlloc(self: *SessionRuntime, allocator: std.mem.Allocator, point: Terminal.Point) !?Terminal.Link {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.linkAtAllocWithScratch(allocator, self.allocator, &self.link_scratch, point);
    }

    pub const RenderCapture = union(enum) {
        prepared: struct { content_generation: u64 },
        synchronized_output,
    };

    /// Captures terminal-owned render state only. This is safe on the frame
    /// latency callback; UI-owned search state and timers are deliberately not
    /// inspected here.
    pub fn captureRender(self: *SessionRuntime) !RenderCapture {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        self.render_handoff.lock(&self.terminal_mutex);
        if (self.synchronized_output.remaining(win.GetTickCount64()) != null) {
            self.render_handoff.unlock(&self.terminal_mutex);
            return .synchronized_output;
        }
        const scroll_state = self.terminal.scrollbar() catch Terminal.Scrollbar{ .total = 0, .offset = 0, .len = 0 };
        self.render_scroll_offset = scroll_state.offset;
        const generation = self.content_generation.load(.monotonic);
        self.render_snapshot.capture(self.allocator, &self.terminal) catch |err| {
            self.render_handoff.unlock(&self.terminal_mutex);
            return err;
        };
        self.render_handoff.unlock(&self.terminal_mutex);
        return .{ .prepared = .{ .content_generation = generation } };
    }

    /// Synchronous fallback used by GDI, resize, and wait-registration failure.
    pub fn prepareRender(self: *SessionRuntime) !bool {
        return switch (try self.captureRender()) {
            .prepared => true,
            .synchronized_output => false,
        };
    }

    pub fn replayPreparedViewport(self: *SessionRuntime, renderer: anytype) void {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        renderer.searchState(self.search.enabled, self.search.query.items, self.search.matches.items, self.search.active, self.render_scroll_offset, self.search.scanning);
        self.render_snapshot.replay(renderer);
    }

    pub fn replayPreparedViewportDirty(self: *SessionRuntime, renderer: anytype) void {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        renderer.searchState(self.search.enabled, self.search.query.items, self.search.matches.items, self.search.active, self.render_scroll_offset, self.search.scanning);
        self.render_snapshot.replayDirty(renderer);
    }

    pub fn replayPreparedViewportShifted(self: *SessionRuntime, renderer: anytype, delta: i32) void {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        renderer.searchState(self.search.enabled, self.search.query.items, self.search.matches.items, self.search.active, self.render_scroll_offset, self.search.scanning);
        self.render_snapshot.replayShifted(renderer, delta);
    }

    pub fn preparedViewportCanShift(self: *SessionRuntime, delta: i32) bool {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        return self.render_snapshot.canShift(delta);
    }

    pub fn preparedViewportHasImages(self: *SessionRuntime) bool {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        return self.render_snapshot.images.items.len != 0 or self.render_snapshot.placements.items.len != 0;
    }

    pub fn preparedScrollOffset(self: *SessionRuntime) usize {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        return self.render_scroll_offset;
    }

    /// Returns the delay before a synchronized-output frame may render. Once
    /// the watchdog expires, clear mode 2026 so subsequent output is visible.
    pub fn synchronizedOutputDelay(self: *SessionRuntime, now: u64) ?u32 {
        const remaining = self.synchronized_output.remaining(now) orelse return null;
        if (remaining != 0) return remaining;

        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        const locked_remaining = self.synchronized_output.remaining(now) orelse return null;
        if (locked_remaining != 0) return locked_remaining;
        if (self.terminal.synchronizedOutput()) {
            log.debug("synchronized output timed out; forcing redraw", .{});
            self.terminal.setSynchronizedOutput(false) catch |err| {
                log.warn("unable to clear synchronized output mode: {}", .{err});
            };
        }
        self.synchronized_output.clear();
        return null;
    }

    pub fn forceEndSynchronizedOutput(self: *SessionRuntime) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.terminal.setSynchronizedOutput(false) catch |err| {
            log.warn("unable to clear synchronized output mode: {}", .{err});
        };
        self.synchronized_output.clear();
    }

    pub fn scrollbar(self: *SessionRuntime) !Terminal.Scrollbar {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.scrollbar();
    }

    pub fn scrollViewport(self: *SessionRuntime, delta: isize) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.terminal.scrollViewport(delta);
    }

    pub fn navigatePrompt(self: *SessionRuntime, forward: bool) !bool {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        try self.terminal.setSelection(null);
        return self.terminal.navigatePrompt(forward);
    }

    pub fn lastCommandOutputAlloc(self: *SessionRuntime, allocator: std.mem.Allocator) !?[]u8 {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.lastCommandOutputAlloc(allocator);
    }

    pub fn searchBegin(self: *SessionRuntime) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        if (!self.search.enabled) {
            self.search.saved_offset = if (self.terminal.scrollbar()) |state| state.offset else |_| null;
        }
        self.search.enabled = true;
        self.search.reset();
    }

    pub fn searchCancel(self: *SessionRuntime) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        if (self.search.saved_offset) |target| {
            if (self.terminal.scrollbar()) |state| {
                const delta: isize = if (target >= state.offset)
                    @intCast(target - state.offset)
                else
                    -@as(isize, @intCast(state.offset - target));
                self.terminal.scrollViewport(delta);
            } else |_| {}
        }
        self.search.enabled = false;
        self.search.saved_offset = null;
        // Searching can materialize the entire scrollback. Release that peak
        // allocation when the search UI closes instead of retaining it for the
        // lifetime of the session.
        self.search.query.deinit(self.allocator);
        self.search.query = .empty;
        self.search.matches.deinit(self.allocator);
        self.search.matches = .empty;
        self.search.active = null;
        self.search.next_row = 0;
        self.search.scanning = false;
        self.search_cache.deinit(self.allocator);
    }

    pub fn searchSet(self: *SessionRuntime, bytes: []const u8) !void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        try self.search.query.ensureTotalCapacity(self.allocator, bytes.len);
        self.search.query.clearRetainingCapacity();
        self.search.query.appendSliceAssumeCapacity(bytes);
        self.search.reset();
    }

    pub fn searchStatus(self: *SessionRuntime) SearchStatus {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return .{
            .matches = self.search.matches.items.len,
            .active = self.search.active,
            .scanning = self.search.scanning,
        };
    }

    pub fn searchEnabled(self: *SessionRuntime) bool {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.search.enabled;
    }

    pub fn searchTick(self: *SessionRuntime, time_budget_ns: u64) SearchTickResult {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        if (self.search.query.items.len == 0) return .{ .changed = false, .scanning = false };
        const previous_matches = self.search.matches.items.len;
        const previous_scanning = self.search.scanning;
        const generation = self.contentGeneration();
        if (generation != self.search.scanned_generation) {
            self.search.reset();
            self.search.scanned_generation = generation;
        }
        if (self.search_cache_generation != self.search_content_generation) {
            self.search_cache.clear(self.allocator);
            self.search_cache_generation = self.search_content_generation;
        }
        const total = self.terminal.totalRows() catch return .{
            .changed = previous_matches != self.search.matches.items.len or previous_scanning != self.search.scanning,
            .scanning = self.search.scanning,
        };
        const started_at = @import("win32.zig").monotonicNanoseconds();
        var count: usize = 0;
        while (self.search.scanning and self.search.next_row < total) : (count += 1) {
            self.terminal.searchRowCached(self.allocator, &self.search_cache, self.search.next_row, self.search.query.items, &self.search.matches) catch break;
            self.search.next_row += 1;
            if (started_at) |start| {
                const now = @import("win32.zig").monotonicNanoseconds() orelse break;
                if (now -| start >= time_budget_ns) break;
            } else if (count >= 31) break;
        }
        if (self.search.next_row >= total) {
            self.search.scanning = false;
            self.search.scanned_generation = generation;
        }
        const changed = previous_matches != self.search.matches.items.len or previous_scanning != self.search.scanning;
        return .{
            .changed = changed,
            .scanning = self.search.scanning,
        };
    }

    pub fn searchNavigate(self: *SessionRuntime, forward: bool) ?SearchMatch {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        const match = self.search.navigate(forward) orelse return null;
        const state = self.terminal.scrollbar() catch return match;
        const target = @min(@as(u64, match.row), state.total -| state.len);
        const delta: isize = if (target >= state.offset) @intCast(target - state.offset) else -@as(isize, @intCast(state.offset - target));
        self.terminal.scrollViewport(delta);
        return match;
    }

    pub fn contentGeneration(self: *const SessionRuntime) u64 {
        return self.content_generation.load(.monotonic);
    }

    pub fn outputGeneration(self: *const SessionRuntime) u64 {
        return self.output_generation.load(.monotonic);
    }

    pub fn titleGeneration(self: *const SessionRuntime) u64 {
        return self.title_generation.load(.acquire);
    }

    pub fn progressGeneration(self: *const SessionRuntime) u64 {
        return self.progress_generation.load(.acquire);
    }

    pub fn taskbarProgress(self: *SessionRuntime) ?TaskbarProgress {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.taskbar_progress;
    }

    pub fn takeNotification(self: *SessionRuntime) ?Notification {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.notifications.pop();
    }

    pub fn hasPendingNotification(self: *SessionRuntime) bool {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.notifications.count > 0;
    }

    pub fn freeNotification(self: *SessionRuntime, notification: Notification) void {
        notification.deinit(self.allocator);
    }

    pub fn setClipboardWriteSettings(self: *SessionRuntime, enabled: bool, max_bytes: u32) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.clipboard_write_enabled = enabled;
        self.clipboard_write_max_bytes = max_bytes;
        if (self.pending_clipboard_write) |pending| if (!enabled or switch (pending) {
            .clear => false,
            .text => |text| text.len > max_bytes,
        }) {
            self.freePendingClipboardWrite(pending);
            self.pending_clipboard_write = null;
        };
    }

    pub fn takeClipboardWrite(self: *SessionRuntime) ?PendingClipboardWrite {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        const text = self.pending_clipboard_write;
        self.pending_clipboard_write = null;
        return text;
    }

    pub fn freeClipboardWrite(self: *SessionRuntime, pending: PendingClipboardWrite) void {
        self.freePendingClipboardWrite(pending);
    }

    fn freePendingClipboardWrite(self: *SessionRuntime, pending: PendingClipboardWrite) void {
        switch (pending) {
            .clear => {},
            .text => |text| self.allocator.free(text),
        }
    }

    pub fn copyTitle(self: *SessionRuntime, allocator: std.mem.Allocator, output: *std.ArrayList(u8)) !u64 {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        try output.ensureTotalCapacity(allocator, self.title.items.len);
        output.clearRetainingCapacity();
        output.appendSliceAssumeCapacity(self.title.items);
        return self.title_generation.load(.monotonic);
    }

    pub fn resize(self: *SessionRuntime, columns: u16, rows: u16, cell_width: u32, cell_height: u32) void {
        if (self.columns == columns and self.rows == rows and self.cell_width == cell_width and self.cell_height == cell_height) return;
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        const grid_changed = self.columns != columns or self.rows != rows;
        self.terminal_mutex.lock();
        const resized = resized: {
            self.terminal.resize(columns, rows, cell_width, cell_height) catch |err| {
                log.warn("unable to resize terminal grid: {}", .{err});
                break :resized false;
            };
            break :resized true;
        };
        if (!self.terminal.synchronizedOutput()) self.synchronized_output.clear();
        self.terminal_mutex.unlock();
        if (!resized) return;
        if (grid_changed) {
            self.terminal_mutex.lock();
            self.search_content_generation +%= 1;
            self.terminal_mutex.unlock();
            _ = self.content_generation.fetchAdd(1, .monotonic);
        }
        if (grid_changed) self.queuePtyResize(columns, rows);
        self.columns = columns;
        self.rows = rows;
        self.cell_width = cell_width;
        self.cell_height = cell_height;
    }

    pub fn setTheme(self: *SessionRuntime, value: theme.Theme) void {
        self.snapshot_mutex.lock();
        defer self.snapshot_mutex.unlock();
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.terminal.setTheme(value) catch |err| {
            log.warn("unable to apply terminal theme: {}", .{err});
            return;
        };
        self.render_snapshot.frame = null;
        _ = self.content_generation.fetchAdd(1, .monotonic);
    }

    /// Admit input to the bounded writer queue. Delivery is asynchronous so a
    /// terminal protocol response cannot block while `terminal_mutex` is held.
    pub fn write(self: *SessionRuntime, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        self.pty_queue_mutex.lock();
        defer self.pty_queue_mutex.unlock();
        if (self.pty == null or self.closing or self.writer_failed) return error.ShellNotRunning;
        try self.enqueuePtyInput(bytes);
        self.wakeWriter();
    }

    fn enqueuePtyInput(self: *SessionRuntime, bytes: []const u8) !void {
        std.debug.assert(self.outstanding_input_bytes <= pty_write_queue_max_bytes);
        if (bytes.len > pty_write_queue_max_bytes -| self.outstanding_input_bytes) return error.PtyWriteQueueFull;
        if (self.pty_operations.items.len != 0) {
            const operation = &self.pty_operations.items[self.pty_operations.items.len - 1];
            switch (operation.*) {
                .input => |*input| try input.appendSlice(self.allocator, bytes),
                .resize => try self.appendPtyInput(bytes),
            }
        } else try self.appendPtyInput(bytes);
        self.outstanding_input_bytes += bytes.len;
        std.debug.assert(self.outstanding_input_bytes <= pty_write_queue_max_bytes);
    }

    pub fn paste(self: *SessionRuntime, data: []u8) !void {
        self.terminal_mutex.lock();
        const encoded = self.terminal.encodePasteAlloc(self.allocator, data) catch |err| {
            self.terminal_mutex.unlock();
            return err;
        };
        self.terminal_mutex.unlock();
        defer self.allocator.free(encoded);
        try self.write(encoded);
    }

    pub fn exitedCleanly(self: *const SessionRuntime) bool {
        const pty = self.pty orelse return false;
        return pty.exitedCleanly();
    }

    pub fn sendKey(self: *SessionRuntime, key: Terminal.Key, action: Terminal.KeyAction, modifiers: u16, consumed_modifiers: u16, utf8: []const u8, unshifted_codepoint: u32) !bool {
        var buffer: [128]u8 = undefined;
        self.terminal_mutex.lock();
        const encoded = self.terminal.encodeKey(key, action, modifiers, consumed_modifiers, utf8, unshifted_codepoint, &buffer) catch |err| {
            self.terminal_mutex.unlock();
            return err;
        };
        self.terminal_mutex.unlock();
        try self.write(encoded);
        return encoded.len != 0;
    }

    fn readerMain(self: *SessionRuntime) void {
        var buffer: [reader_buffer_bytes]u8 = undefined;
        while (true) {
            const count = self.pty.?.read(&buffer) catch break;
            if (count == 0) break;
            if (self.processOutput(buffer[0..count], win.GetTickCount64())) self.refresh.request();
        }
        self.terminal_mutex.lock();
        self.terminal.setSynchronizedOutput(false) catch {};
        self.synchronized_output.clear();
        self.terminal_mutex.unlock();
        self.refresh.request();
    }

    fn writerMain(self: *SessionRuntime) void {
        var operations: std.ArrayList(PtyOperation) = .empty;
        defer {
            for (operations.items) |*operation| operation.deinit(self.allocator);
            operations.deinit(self.allocator);
        }
        while (true) {
            self.pty_queue_mutex.lock();
            if (self.closing) {
                self.pty_queue_mutex.unlock();
                return;
            }
            if (self.pty_operations.items.len != 0) {
                std.mem.swap(std.ArrayList(PtyOperation), &operations, &self.pty_operations);
            }
            const generation = self.pty_writer_generation.load(.acquire);
            self.pty_queue_mutex.unlock();

            if (operations.items.len == 0) {
                var expected = generation;
                _ = std.os.windows.ntdll.RtlWaitOnAddress(
                    @ptrCast(&self.pty_writer_generation),
                    @ptrCast(&expected),
                    @sizeOf(u32),
                    null,
                );
                continue;
            }

            for (operations.items) |*operation| switch (operation.*) {
                .resize => |size| self.pty.?.resize(size.columns, size.rows) catch |err| {
                    log.warn("unable to resize pseudoconsole: {}", .{err});
                },
                .input => |*input| {
                    self.pty.?.write(input.items) catch |err| {
                        log.debug("unable to write pseudoconsole input: {}", .{err});
                        self.pty_queue_mutex.lock();
                        self.writer_failed = true;
                        self.pty_queue_mutex.unlock();
                        self.refresh.request();
                        return;
                    };
                    self.pty_queue_mutex.lock();
                    std.debug.assert(input.items.len <= self.outstanding_input_bytes);
                    self.outstanding_input_bytes -= input.items.len;
                    self.pty_queue_mutex.unlock();
                },
            };
            for (operations.items) |*operation| operation.deinit(self.allocator);
            operations.clearRetainingCapacity();
        }
    }

    fn appendPtyInput(self: *SessionRuntime, bytes: []const u8) !void {
        var input: std.ArrayList(u8) = .empty;
        errdefer input.deinit(self.allocator);
        try input.appendSlice(self.allocator, bytes);
        try self.pty_operations.append(self.allocator, .{ .input = input });
    }

    fn clearPtyOperations(self: *SessionRuntime) void {
        var removed_input_bytes: usize = 0;
        for (self.pty_operations.items) |*operation| {
            switch (operation.*) {
                .input => |input| removed_input_bytes += input.items.len,
                .resize => {},
            }
            operation.deinit(self.allocator);
        }
        std.debug.assert(removed_input_bytes <= self.outstanding_input_bytes);
        self.pty_operations.clearRetainingCapacity();
        self.outstanding_input_bytes -= removed_input_bytes;
    }

    fn queuePtyResize(self: *SessionRuntime, columns: u16, rows: u16) void {
        self.pty_queue_mutex.lock();
        defer self.pty_queue_mutex.unlock();
        if (self.pty == null or self.closing or self.writer_failed) return;
        const size = PtySize{ .columns = columns, .rows = rows };
        self.enqueuePtyResize(size) catch {
            log.warn("unable to queue pseudoconsole resize", .{});
            return;
        };
        self.wakeWriter();
    }

    fn enqueuePtyResize(self: *SessionRuntime, size: PtySize) !void {
        if (self.pty_operations.items.len != 0) {
            const operation = &self.pty_operations.items[self.pty_operations.items.len - 1];
            switch (operation.*) {
                .resize => operation.* = .{ .resize = size },
                .input => try self.pty_operations.append(self.allocator, .{ .resize = size }),
            }
        } else try self.pty_operations.append(self.allocator, .{ .resize = size });
    }

    fn requestWriterClose(self: *SessionRuntime) void {
        self.pty_queue_mutex.lock();
        self.closing = true;
        self.clearPtyOperations();
        self.wakeWriter();
        self.pty_queue_mutex.unlock();
    }

    fn wakeWriter(self: *SessionRuntime) void {
        _ = self.pty_writer_generation.fetchAdd(1, .release);
        std.os.windows.ntdll.RtlWakeAddressSingle(@ptrCast(&self.pty_writer_generation));
    }

    fn workersStopped(reader_thread: ?std.Thread, writer_thread: ?std.Thread) bool {
        if (reader_thread) |thread| if (win.WaitForSingleObject(@ptrCast(thread.getHandle()), 0) != win.WAIT_OBJECT_0) return false;
        if (writer_thread) |thread| if (win.WaitForSingleObject(@ptrCast(thread.getHandle()), 0) != win.WAIT_OBJECT_0) return false;
        return true;
    }

    /// Apply one complete PTY read while holding the terminal lock. This keeps
    /// renderers from observing parser states between feed-sized chunks.
    fn processOutput(self: *SessionRuntime, bytes: []const u8, now: u64) bool {
        self.terminal_mutex.lock();
        var refresh = false;
        var offset: usize = 0;
        while (offset < bytes.len) {
            const end = @min(offset + feed_chunk_bytes, bytes.len);
            refresh = self.processOutputChunkLocked(bytes[offset..end], now) or refresh;
            offset = end;
        }
        self.terminal_mutex.unlock();
        self.render_handoff.yield();
        return refresh;
    }

    fn processOutputChunk(self: *SessionRuntime, bytes: []const u8, now: u64) bool {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.processOutputChunkLocked(bytes, now);
    }

    fn processOutputChunkLocked(self: *SessionRuntime, bytes: []const u8, now: u64) bool {
        self.terminal.feed(bytes);
        const synchronized = self.terminal.synchronizedOutput();
        const mode_changed = self.synchronized_output.update(synchronized, now);
        self.search_content_generation +%= 1;
        _ = self.output_generation.fetchAdd(1, .monotonic);
        _ = self.content_generation.fetchAdd(1, .monotonic);
        return !synchronized or mode_changed;
    }

    /// Ghostty invokes this synchronously from `Terminal.feed`. Keep the same
    /// bounded queue and ownership policy previously used by the local parser.
    fn desktopNotification(context: ?*anyopaque, title: []const u8, body: []const u8) void {
        const self: *SessionRuntime = @ptrCast(@alignCast(context orelse return));
        const payload_len = std.math.add(usize, title.len, body.len) catch return;
        if (payload_len > notification_max_bytes or title.len > std.math.maxInt(u16)) return;
        const payload = self.allocator.alloc(u8, payload_len) catch return;
        @memcpy(payload[0..title.len], title);
        @memcpy(payload[title.len..], body);
        const notification = Notification{ .payload = payload, .title_len = @intCast(title.len) };
        self.notifications.push(self.allocator, notification) catch notification.deinit(self.allocator);
        self.refresh.request();
    }

    /// Ghostty invokes this synchronously from `Terminal.feed` after parsing
    /// OSC 9;4, including sequences split across separate PTY reads.
    fn progressReport(context: ?*anyopaque, update: Terminal.ProgressUpdate) void {
        const self: *SessionRuntime = @ptrCast(@alignCast(context orelse return));
        self.taskbar_progress = switch (update) {
            .remove => null,
            .report => |report| value: {
                const previous = if (self.taskbar_progress) |current| current.value else 0;
                break :value .{
                    .state = report.state,
                    .value = report.value orelse if (report.state == .normal) 0 else previous,
                    .updated_tick = win.GetTickCount64(),
                };
            },
        };
        _ = self.progress_generation.fetchAdd(1, .release);
        self.refresh.request();
    }

    /// Ghostty invokes this synchronously from `Terminal.feed`, while the reader
    /// already holds `terminal_mutex`. Readers acquire that mutex in `copyTitle`.
    fn titleChanged(context: ?*anyopaque, title: []const u8) void {
        const self: *SessionRuntime = @ptrCast(@alignCast(context orelse return));
        self.title.ensureTotalCapacity(self.allocator, title.len) catch return;
        self.title.clearRetainingCapacity();
        self.title.appendSliceAssumeCapacity(title);
        _ = self.title_generation.fetchAdd(1, .release);
    }

    /// Ghostty invokes this synchronously while `terminal_mutex` is held. PTY
    /// writes use a separate mutex so replies cannot interleave with user input.
    fn writePty(context: ?*anyopaque, bytes: []const u8) void {
        const self: *SessionRuntime = @ptrCast(@alignCast(context orelse return));
        self.write(bytes) catch |err| log.debug("unable to write terminal response: {}", .{err});
    }

    /// Ghostty invokes this synchronously while `terminal_mutex` is held. Keep
    /// only the latest accepted write until the UI thread updates Win32.
    fn clipboardWrite(context: ?*anyopaque, operation: Terminal.ClipboardWriteOperation) Terminal.ClipboardWriteResult {
        const self: *SessionRuntime = @ptrCast(@alignCast(context orelse return .io_error));
        if (!self.clipboard_write_enabled) return .denied;
        const pending: PendingClipboardWrite = switch (operation) {
            .clear => .clear,
            .text => |text| text: {
                if (text.len > self.clipboard_write_max_bytes or std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return .invalid_data;
                break :text .{ .text = self.allocator.dupe(u8, text) catch return .io_error };
            },
        };
        if (self.pending_clipboard_write) |previous| self.freePendingClipboardWrite(previous);
        self.pending_clipboard_write = pending;
        self.refresh.request();
        return .success;
    }
};

test "PTY work queue preserves input ordering and coalesces adjacent resizes" {
    var runtime = SessionRuntime{
        .allocator = std.testing.allocator,
        .terminal = try Terminal.init(80, 24, theme.rasmus),
        .refresh = .{},
        .columns = 80,
        .rows = 24,
    };
    defer deinitTestRuntime(&runtime);

    try runtime.enqueuePtyInput("A");
    try runtime.enqueuePtyInput("B");
    try runtime.enqueuePtyResize(.{ .columns = 90, .rows = 30 });
    try runtime.enqueuePtyResize(.{ .columns = 100, .rows = 40 });
    try runtime.enqueuePtyInput("C");
    try runtime.enqueuePtyResize(.{ .columns = 110, .rows = 50 });

    try std.testing.expectEqual(@as(usize, 4), runtime.pty_operations.items.len);
    switch (runtime.pty_operations.items[0]) {
        .input => |input| try std.testing.expectEqualStrings("AB", input.items),
        .resize => return error.ExpectedInput,
    }
    switch (runtime.pty_operations.items[1]) {
        .resize => |size| {
            try std.testing.expectEqual(@as(u16, 100), size.columns);
            try std.testing.expectEqual(@as(u16, 40), size.rows);
        },
        .input => return error.ExpectedResize,
    }
    switch (runtime.pty_operations.items[2]) {
        .input => |input| try std.testing.expectEqualStrings("C", input.items),
        .resize => return error.ExpectedInput,
    }
    try std.testing.expectEqual(@as(usize, 3), runtime.outstanding_input_bytes);
}

test "synchronized output arms once and releases when disabled" {
    var state = SessionRuntime.SynchronizedOutput{};

    try std.testing.expect(state.update(true, 100));
    try std.testing.expectEqual(@as(?u32, 1000), state.remaining(100));
    try std.testing.expect(!state.update(true, 500));
    try std.testing.expectEqual(@as(?u32, 600), state.remaining(500));
    try std.testing.expect(state.update(false, 600));
    try std.testing.expectEqual(@as(?u32, null), state.remaining(600));
    try std.testing.expect(!state.update(false, 700));
}

test "render handoff gives a waiting snapshot lock its turn" {
    var mutex = @import("win32.zig").Mutex{};
    var handoff = SessionRuntime.RenderHandoff{};
    var entered = std.atomic.Value(bool).init(false);
    const Context = struct {
        const State = struct {
            handoff: *SessionRuntime.RenderHandoff,
            mutex: *@import("win32.zig").Mutex,
            entered: *std.atomic.Value(bool),
        };

        fn run(state: State) void {
            state.handoff.lock(state.mutex);
            state.entered.store(true, .release);
            state.handoff.unlock(state.mutex);
        }
    };

    mutex.lock();
    const thread = try std.Thread.spawn(.{}, Context.run, .{Context.State{
        .handoff = &handoff,
        .mutex = &mutex,
        .entered = &entered,
    }});
    var attempts: usize = 0;
    while (handoff.demand.load(.monotonic) == 0 and attempts < 100_000) : (attempts += 1)
        _ = win.SwitchToThread();
    if (handoff.demand.load(.monotonic) == 0) {
        mutex.unlock();
        thread.join();
        return error.RenderHandoffWaiterDidNotStart;
    }
    const generation = handoff.generation.load(.monotonic);
    mutex.unlock();
    handoff.yield();
    thread.join();

    try std.testing.expect(entered.load(.acquire));
    try std.testing.expect(handoff.generation.load(.monotonic) != generation);
    try std.testing.expectEqual(@as(u32, 0), handoff.demand.load(.monotonic));
}

test "synchronized output watchdog expires and clear releases rendering" {
    var state = SessionRuntime.SynchronizedOutput{};

    try std.testing.expect(state.update(true, 50));
    try std.testing.expectEqual(@as(?u32, 1), state.remaining(1049));
    try std.testing.expectEqual(@as(?u32, 0), state.remaining(1050));
    state.clear();
    try std.testing.expectEqual(@as(?u32, null), state.remaining(1050));
}

test "session defers synchronized chunks and prepares once mode ends" {
    var runtime = SessionRuntime{
        .allocator = std.testing.allocator,
        .terminal = try Terminal.init(80, 24, theme.rasmus),
        .refresh = .{},
        .columns = 80,
        .rows = 24,
    };
    defer deinitTestRuntime(&runtime);

    try std.testing.expectEqual(@as(u64, 0), runtime.outputGeneration());
    try std.testing.expect(runtime.processOutputChunk("before\x1b[?2026hpartial", 100));
    try std.testing.expectEqual(@as(u64, 1), runtime.outputGeneration());
    try std.testing.expect(!(try runtime.prepareRender()));
    try std.testing.expect(!runtime.processOutputChunk("more", 200));
    try std.testing.expectEqual(@as(u64, 2), runtime.outputGeneration());
    try std.testing.expect(runtime.processOutputChunk("final\x1b[?2026l", 300));
    try std.testing.expectEqual(@as(u64, 3), runtime.outputGeneration());
    try std.testing.expect(try runtime.prepareRender());
}

test "session consumes Ghostty progress and notification effects" {
    var runtime = SessionRuntime{
        .allocator = std.testing.allocator,
        .terminal = try Terminal.init(80, 24, theme.rasmus),
        .refresh = .{},
        .columns = 80,
        .rows = 24,
    };
    defer deinitTestRuntime(&runtime);
    try runtime.terminal.setProgressReport(SessionRuntime.progressReport, &runtime);
    try runtime.terminal.setDesktopNotification(SessionRuntime.desktopNotification, &runtime);

    _ = runtime.processOutputChunk("plain\x1b]9;4;", 100);
    try std.testing.expectEqual(@as(?SessionRuntime.TaskbarProgress, null), runtime.taskbarProgress());
    _ = runtime.processOutputChunk("1;47\x07\x1b]777;notify;Build;finished successfully\x1b\\", 200);
    const determinate = runtime.taskbarProgress().?;
    try std.testing.expectEqual(Terminal.ProgressState.normal, determinate.state);
    try std.testing.expectEqual(@as(u8, 47), determinate.value);

    const notification = runtime.takeNotification().?;
    defer runtime.freeNotification(notification);
    try std.testing.expectEqualStrings("Build", notification.title());
    try std.testing.expectEqualStrings("finished successfully", notification.body());

    _ = runtime.processOutputChunk("\x1b]9;4;4\x07", 300);
    const paused = runtime.taskbarProgress().?;
    try std.testing.expectEqual(Terminal.ProgressState.paused, paused.state);
    try std.testing.expectEqual(@as(u8, 47), paused.value);
    _ = runtime.processOutputChunk("\x1b]9;4;1\x07", 400);
    try std.testing.expectEqual(@as(u8, 0), runtime.taskbarProgress().?.value);
    _ = runtime.processOutputChunk("\x1b]9;4;0\x07", 500);
    try std.testing.expectEqual(@as(?SessionRuntime.TaskbarProgress, null), runtime.taskbarProgress());
}

test "session watchdog and resize release synchronized output" {
    var runtime = SessionRuntime{
        .allocator = std.testing.allocator,
        .terminal = try Terminal.init(80, 24, theme.rasmus),
        .refresh = .{},
        .columns = 80,
        .rows = 24,
    };
    defer deinitTestRuntime(&runtime);

    try std.testing.expect(runtime.processOutputChunk("\x1b[?2026hpartial", 100));
    try std.testing.expectEqual(@as(?u32, 1), runtime.synchronizedOutputDelay(1099));
    try std.testing.expectEqual(@as(?u32, null), runtime.synchronizedOutputDelay(1100));
    try std.testing.expect(!runtime.terminal.synchronizedOutput());
    try std.testing.expect(try runtime.prepareRender());

    try std.testing.expect(runtime.processOutputChunk("\x1b[?2026hpartial", 2000));
    runtime.resize(100, 40, 9, 18);
    try std.testing.expectEqual(@as(?u32, null), runtime.synchronizedOutputDelay(2001));
    try std.testing.expect(try runtime.prepareRender());
}

test "theme changes rebuild the prepared render snapshot" {
    var runtime = SessionRuntime{
        .allocator = std.testing.allocator,
        .terminal = try Terminal.init(4, 2, theme.rasmus),
        .refresh = .{},
        .columns = 4,
        .rows = 2,
    };
    defer deinitTestRuntime(&runtime);

    runtime.terminal.feed("\x1b[31mX");
    try std.testing.expect(try runtime.prepareRender());
    try std.testing.expectEqual(theme.rasmus.ansi[1], runtime.render_snapshot.cells.items[0].foreground);

    var replacement = theme.rasmus;
    replacement.ansi[1] = .{ .red = 1, .green = 2, .blue = 3 };
    runtime.setTheme(replacement);
    try std.testing.expectEqual(@as(?Terminal.Frame, null), runtime.render_snapshot.frame);
    try std.testing.expect(try runtime.prepareRender());
    try std.testing.expectEqual(replacement.ansi[1], runtime.render_snapshot.cells.items[0].foreground);
}

test "session applies clipboard write policy and decoded size limit" {
    var runtime = SessionRuntime{
        .allocator = std.testing.allocator,
        .terminal = try Terminal.init(80, 24, theme.rasmus),
        .refresh = .{},
        .clipboard_write_enabled = true,
        .clipboard_write_max_bytes = 5,
        .columns = 80,
        .rows = 24,
    };
    defer deinitTestRuntime(&runtime);
    try runtime.terminal.setClipboardWrite(SessionRuntime.clipboardWrite, &runtime);

    _ = runtime.processOutputChunk("\x1b]52;c;aGVsbG8=\x07", 100);
    const accepted = runtime.takeClipboardWrite().?;
    defer runtime.freeClipboardWrite(accepted);
    try std.testing.expectEqualStrings("hello", accepted.text);

    _ = runtime.processOutputChunk("\x1b]52;c;d29ybGQh\x07", 200);
    try std.testing.expect(runtime.takeClipboardWrite() == null);

    _ = runtime.processOutputChunk("\x1b]52;c;YQBi\x07", 250);
    try std.testing.expect(runtime.takeClipboardWrite() == null);

    _ = runtime.processOutputChunk("\x1b]52;c;aGVsbG8=\x07", 275);
    runtime.setClipboardWriteSettings(true, 4);
    try std.testing.expect(runtime.takeClipboardWrite() == null);

    _ = runtime.processOutputChunk("\x1b]52;c;\x07", 280);
    try std.testing.expect(runtime.takeClipboardWrite().? == .clear);

    runtime.setClipboardWriteSettings(false, 5);
    _ = runtime.processOutputChunk("\x1b]52;c;aGVsbG8=\x07", 300);
    try std.testing.expect(runtime.takeClipboardWrite() == null);

    _ = runtime.processOutputChunk("\x1b]52;c;?\x07", 400);
    try std.testing.expect(runtime.takeClipboardWrite() == null);
}

fn deinitTestRuntime(runtime: *SessionRuntime) void {
    runtime.clearPtyOperations();
    runtime.pty_operations.deinit(runtime.allocator);
    runtime.title.deinit(runtime.allocator);
    if (runtime.pending_clipboard_write) |pending| runtime.freePendingClipboardWrite(pending);
    runtime.notifications.deinit(runtime.allocator);
    runtime.search.deinit(runtime.allocator);
    runtime.render_snapshot.deinit(runtime.allocator);
    runtime.search_cache.deinit(runtime.allocator);
    runtime.link_scratch.deinit(runtime.allocator);
    runtime.terminal.deinit();
}

fn osc7WindowsPathAlloc(allocator: std.mem.Allocator, value: []const u8, local_hostname: []const u8) !?[]u8 {
    const uri = std.Uri.parse(value) catch return null;
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "file") or uri.user != null or uri.password != null or uri.port != null or uri.query != null or uri.fragment != null) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const temporary = arena.allocator();
    if (uri.host) |component| {
        if (!validPercentEncoding(component)) return null;
        const host = try component.toRawMaybeAlloc(temporary);
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost") and !std.ascii.eqlIgnoreCase(host, local_hostname)) return null;
    }
    if (!validPercentEncoding(uri.path)) return null;
    const path = try uri.path.toRawMaybeAlloc(temporary);
    if (path.len < 4 or path[0] != '/' or !std.ascii.isAlphabetic(path[1]) or path[2] != ':' or path[3] != '/' or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return null;

    const result = try allocator.dupe(u8, path[1..]);
    for (result) |*byte| if (byte.* == '/') {
        byte.* = '\\';
    };
    return result;
}

fn validPercentEncoding(component: std.Uri.Component) bool {
    const encoded = switch (component) {
        .raw => return true,
        .percent_encoded => |value| value,
    };
    var index: usize = 0;
    while (std.mem.indexOfScalarPos(u8, encoded, index, '%')) |percent| {
        if (percent + 2 >= encoded.len or !std.ascii.isHex(encoded[percent + 1]) or !std.ascii.isHex(encoded[percent + 2])) return false;
        index = percent + 3;
    }
    return true;
}

test "OSC 7 local file URIs become Windows working directories" {
    const allocator = std.testing.allocator;
    const plain = (try osc7WindowsPathAlloc(allocator, "file:///C:/Users/Alice/project", "DESKTOP-1")).?;
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("C:\\Users\\Alice\\project", plain);

    const escaped = (try osc7WindowsPathAlloc(allocator, "file://desktop-1/C:/My%20Files/%E2%9C%93", "DESKTOP-1")).?;
    defer allocator.free(escaped);
    try std.testing.expectEqualStrings("C:\\My Files\\✓", escaped);

    const localhost = (try osc7WindowsPathAlloc(allocator, "FILE://localhost/D:/work", "DESKTOP-1")).?;
    defer allocator.free(localhost);
    try std.testing.expectEqualStrings("D:\\work", localhost);
}

test "OSC 7 rejects remote malformed and non-Windows locations" {
    const allocator = std.testing.allocator;
    try std.testing.expect((try osc7WindowsPathAlloc(allocator, "file://remote/C:/work", "DESKTOP-1")) == null);
    try std.testing.expect((try osc7WindowsPathAlloc(allocator, "https://localhost/C:/work", "DESKTOP-1")) == null);
    try std.testing.expect((try osc7WindowsPathAlloc(allocator, "file:///home/alice", "DESKTOP-1")) == null);
    try std.testing.expect((try osc7WindowsPathAlloc(allocator, "file:///C:/bad%ZZpath", "DESKTOP-1")) == null);
    try std.testing.expect((try osc7WindowsPathAlloc(allocator, "file:///C:/bad%00path", "DESKTOP-1")) == null);
}

test "notification queue preserves FIFO order and evicts its oldest entry" {
    var queue = SessionRuntime.NotificationQueue{};
    defer queue.deinit(std.testing.allocator);

    for (0..33) |index| {
        const payload = try std.testing.allocator.alloc(u8, 1);
        payload[0] = @intCast(index);
        const notification = SessionRuntime.Notification{ .payload = payload, .title_len = 0 };
        queue.push(std.testing.allocator, notification) catch |err| {
            notification.deinit(std.testing.allocator);
            return err;
        };
    }

    try std.testing.expectEqual(@as(usize, 32), queue.count);
    const first = queue.pop().?;
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), first.body()[0]);
}
