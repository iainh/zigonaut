const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");
const Search = @import("search.zig").State;
const SearchMatch = @import("search.zig").Match;
const progress = @import("progress.zig");
const win = @import("win32.zig").c;
const log = std.log.scoped(.session);
const reader_buffer_bytes = 16 * 1024;
const feed_chunk_bytes = 4 * 1024;
const synchronized_output_timeout_ms = 1000;

/// Heap-owned runtime with a stable address shared by Win32 and the reader thread.
/// Call `destroy` only after no caller can submit input or rendering work.
pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    pty: ?Pty = null,
    reader_thread: ?std.Thread = null,
    refresh: Refresh,
    terminal_mutex: std.Thread.Mutex = .{},
    pty_mutex: std.Thread.Mutex = .{},
    closing: bool = false,
    content_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    synchronized_output: SynchronizedOutput = .{},
    search_content_generation: u64 = 0,
    title: std.ArrayList(u8) = .empty,
    title_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    search: Search = .{},
    progress_parser: progress.Parser = .{},
    taskbar_progress: ?TaskbarProgress = null,
    progress_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    notifications: NotificationQueue = .{},
    clipboard_write_enabled: bool = false,
    clipboard_write_max_bytes: u32 = 1024 * 1024,
    pending_clipboard_write: ?PendingClipboardWrite = null,
    render_snapshot: Terminal.RenderSnapshot = .{},
    render_search_enabled: bool = false,
    render_search_active: ?usize = null,
    render_search_scanning: bool = false,
    render_scroll_offset: usize = 0,
    // Search state is UI-thread-owned. The reader thread only changes terminal
    // content and generations, so synchronous rendering can borrow these lists.
    search_cache: Terminal.SearchCache = .{},
    search_cache_generation: u64 = std.math.maxInt(u64),
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

    pub const TaskbarProgress = struct {
        state: progress.State,
        value: u8,
        updated_tick: u64,
    };

    pub const SearchTickResult = struct {
        changed: bool,
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

        fn deinit(self: *NotificationQueue, allocator: std.mem.Allocator) void {
            while (self.pop()) |notification| notification.deinit(allocator);
            self.slots.deinit(allocator);
            self.* = .{};
        }

        fn push(self: *NotificationQueue, allocator: std.mem.Allocator, notification: Notification) !void {
            if (self.slots.items.len == 0) try self.slots.resize(allocator, capacity);
            if (self.count == capacity) {
                self.slots.items[self.head].deinit(allocator);
                self.slots.items[self.head] = notification;
                self.head = (self.head + 1) % capacity;
                return;
            }
            const index = (self.head + self.count) % capacity;
            self.slots.items[index] = notification;
            self.count += 1;
        }

        fn pop(self: *NotificationQueue) ?Notification {
            if (self.count == 0) return null;
            const notification = self.slots.items[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            if (self.count == 0) self.head = 0;
            return notification;
        }
    };

    pub const PendingClipboardWrite = union(enum) {
        clear,
        text: []u8,
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

        self.pty = Pty.spawn(allocator, command, working_directory, columns, rows) catch |err| {
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
            self.pty.?.stopIo(null);
            self.pty.?.closeConsole();
            self.pty.?.finishClose();
        }

        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        return self;
    }

    pub fn destroy(self: *SessionRuntime) void {
        if (self.pty) |*pty| {
            self.pty_mutex.lock();
            self.closing = true;
            pty.stopIo(self.reader_thread);
            self.pty_mutex.unlock();
            if (self.reader_thread) |thread| thread.join();
            pty.closeConsole();
            pty.finishClose();
        }
        self.title.deinit(self.allocator);
        if (self.pending_clipboard_write) |pending| self.freePendingClipboardWrite(pending);
        self.notifications.deinit(self.allocator);
        self.search.deinit(self.allocator);
        self.render_snapshot.deinit(self.allocator);
        self.search_cache.deinit(self.allocator);
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

        var hostname_wide: [std.Uri.host_name_max]u16 = undefined;
        var hostname_length: win.DWORD = hostname_wide.len;
        if (win.GetComputerNameW(&hostname_wide, &hostname_length) == 0) return null;
        var hostname_utf8: [std.Uri.host_name_max * 3]u8 = undefined;
        const utf8_length = std.unicode.utf16LeToUtf8(&hostname_utf8, hostname_wide[0..hostname_length]) catch return null;
        return osc7WindowsPathAlloc(allocator, value, hostname_utf8[0..utf8_length]);
    }

    pub fn linkAtAlloc(self: *SessionRuntime, allocator: std.mem.Allocator, point: Terminal.Point) !?Terminal.Link {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.linkAtAlloc(allocator, point);
    }

    /// Atomically admits a render and captures its terminal state. A mode 2026
    /// transition after this returns cannot affect the prepared frame.
    pub fn prepareRender(self: *SessionRuntime) !bool {
        self.terminal_mutex.lock();
        if (self.synchronized_output.remaining(win.GetTickCount64()) != null) {
            self.terminal_mutex.unlock();
            return false;
        }
        const scroll_state = self.terminal.scrollbar() catch Terminal.Scrollbar{ .total = 0, .offset = 0, .len = 0 };
        self.render_search_enabled = self.search.enabled;
        self.render_search_active = self.search.active;
        self.render_search_scanning = self.search.scanning;
        self.render_scroll_offset = scroll_state.offset;
        self.render_snapshot.capture(self.allocator, &self.terminal) catch |err| {
            self.terminal_mutex.unlock();
            return err;
        };
        self.terminal_mutex.unlock();
        return true;
    }

    pub fn replayPreparedViewport(self: *SessionRuntime, renderer: anytype) void {
        renderer.searchState(self.render_search_enabled, self.search.query.items, self.search.matches.items, self.render_search_active, self.render_scroll_offset, self.render_search_scanning);
        self.render_snapshot.replay(renderer);
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
        self.search.query.clearRetainingCapacity();
        self.search.reset();
    }

    pub fn searchAppend(self: *SessionRuntime, bytes: []const u8) !void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        try self.search.query.appendSlice(self.allocator, bytes);
        self.search.reset();
    }
    pub fn searchBackspace(self: *SessionRuntime) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        if (self.search.query.items.len > 0) {
            var end = self.search.query.items.len - 1;
            while (end > 0 and self.search.query.items[end] & 0xc0 == 0x80) end -= 1;
            self.search.query.shrinkRetainingCapacity(end);
            self.search.reset();
        }
    }

    pub fn searchClear(self: *SessionRuntime) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.search.query.clearRetainingCapacity();
        self.search.reset();
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
        var timer = std.time.Timer.start() catch null;
        var count: usize = 0;
        while (self.search.scanning and self.search.next_row < total) : (count += 1) {
            self.terminal.searchRowCached(self.allocator, &self.search_cache, self.search.next_row, self.search.query.items, &self.search.matches) catch break;
            self.search.next_row += 1;
            if (timer) |*clock| {
                if (clock.read() >= time_budget_ns) break;
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
        if (grid_changed) if (self.pty) |*pty| pty.resize(columns, rows) catch |err| {
            log.warn("unable to resize pseudoconsole: {}", .{err});
        };
        self.columns = columns;
        self.rows = rows;
        self.cell_width = cell_width;
        self.cell_height = cell_height;
    }

    pub fn setTheme(self: *SessionRuntime, value: theme.Theme) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.terminal.setTheme(value) catch |err| {
            log.warn("unable to apply terminal theme: {}", .{err});
            return;
        };
        _ = self.content_generation.fetchAdd(1, .monotonic);
    }

    pub fn write(self: *SessionRuntime, bytes: []const u8) !void {
        self.pty_mutex.lock();
        defer self.pty_mutex.unlock();
        if (self.closing) return error.ShellNotRunning;
        if (self.pty) |*pty| return pty.write(bytes);
        return error.ShellNotRunning;
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

    pub fn sendKey(self: *SessionRuntime, key: Terminal.Key, action: Terminal.KeyAction, modifiers: u16, unshifted_codepoint: u32) !bool {
        var buffer: [128]u8 = undefined;
        self.terminal_mutex.lock();
        const encoded = self.terminal.encodeKey(key, action, modifiers, unshifted_codepoint, &buffer) catch |err| {
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

            var offset: usize = 0;
            while (offset < count) {
                const end = @min(offset + feed_chunk_bytes, count);
                if (self.processOutputChunk(buffer[offset..end], win.GetTickCount64())) self.refresh.request();
                offset = end;
            }
        }
        self.terminal_mutex.lock();
        self.terminal.setSynchronizedOutput(false) catch {};
        self.synchronized_output.clear();
        self.terminal_mutex.unlock();
        self.refresh.request();
    }

    fn processOutputChunk(self: *SessionRuntime, bytes: []const u8, now: u64) bool {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.progress_parser.feedEach(bytes, ProgressHandler{ .runtime = self });
        self.terminal.feed(bytes);
        const synchronized = self.terminal.synchronizedOutput();
        const mode_changed = self.synchronized_output.update(synchronized, now);
        self.search_content_generation +%= 1;
        _ = self.content_generation.fetchAdd(1, .monotonic);
        return !synchronized or mode_changed;
    }

    const ProgressHandler = struct {
        runtime: *SessionRuntime,

        pub fn handle(self: ProgressHandler, update: progress.Update) void {
            const runtime = self.runtime;
            if (update == .notification) {
                const event = update.notification;
                const payload = runtime.allocator.alloc(u8, event.title.len + event.body.len) catch return;
                @memcpy(payload[0..event.title.len], event.title);
                @memcpy(payload[event.title.len..], event.body);
                const notification = Notification{ .payload = payload, .title_len = @intCast(event.title.len) };
                runtime.notifications.push(runtime.allocator, notification) catch notification.deinit(runtime.allocator);
                return;
            }
            runtime.taskbar_progress = switch (update) {
                .remove => null,
                .report => |report| value: {
                    const previous = if (runtime.taskbar_progress) |current| current.value else 0;
                    break :value .{
                        .state = report.state,
                        .value = progress.resolvedValue(report, previous),
                        .updated_tick = win.GetTickCount64(),
                    };
                },
                .notification => unreachable,
            };
            _ = runtime.progress_generation.fetchAdd(1, .release);
        }
    };

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

    try std.testing.expect(runtime.processOutputChunk("before\x1b[?2026hpartial", 100));
    try std.testing.expect(!(try runtime.prepareRender()));
    try std.testing.expect(!runtime.processOutputChunk("more", 200));
    try std.testing.expect(runtime.processOutputChunk("final\x1b[?2026l", 300));
    try std.testing.expect(try runtime.prepareRender());
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
    if (runtime.pending_clipboard_write) |pending| runtime.freePendingClipboardWrite(pending);
    runtime.render_snapshot.deinit(runtime.allocator);
    runtime.search_cache.deinit(runtime.allocator);
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
