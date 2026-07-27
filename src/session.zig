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

/// Heap-owned runtime with a stable address shared by Win32 and the reader thread.
/// Call `destroy` only after no caller can submit input or rendering work.
pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    pty: ?Pty = null,
    reader_thread: ?std.Thread = null,
    refresh: Refresh,
    terminal_mutex: std.Thread.Mutex = .{},
    content_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    search_content_generation: u64 = 0,
    title: std.ArrayList(u8) = .empty,
    title_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    search: Search = .{},
    progress_parser: progress.Parser = .{},
    taskbar_progress: ?TaskbarProgress = null,
    progress_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    notifications: NotificationQueue = .{},
    render_snapshot: Terminal.RenderSnapshot = .{},
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

    pub fn create(
        allocator: std.mem.Allocator,
        command: []const u8,
        working_directory: []const u8,
        terminal_theme: theme.Theme,
        columns: u16,
        rows: u16,
        refresh: Refresh,
    ) !*SessionRuntime {
        const self = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .terminal = try Terminal.init(columns, rows, terminal_theme),
            .refresh = refresh,
            .columns = columns,
            .rows = rows,
        };
        errdefer self.terminal.deinit();
        try self.terminal.setTitleChanged(titleChanged, self);

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
            pty.stopIo(self.reader_thread);
            if (self.reader_thread) |thread| thread.join();
            pty.closeConsole();
            pty.finishClose();
        }
        self.title.deinit(self.allocator);
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

    pub fn linkAtAlloc(self: *SessionRuntime, allocator: std.mem.Allocator, point: Terminal.Point) !?Terminal.Link {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.linkAtAlloc(allocator, point);
    }

    pub fn renderViewport(self: *SessionRuntime, renderer: anytype) !void {
        self.terminal_mutex.lock();
        const scroll_state = self.terminal.scrollbar() catch Terminal.Scrollbar{ .total = 0, .offset = 0, .len = 0 };
        const search_enabled = self.search.enabled;
        const search_active = self.search.active;
        const search_scanning = self.search.scanning;
        self.render_snapshot.capture(self.allocator, &self.terminal) catch |err| {
            self.terminal_mutex.unlock();
            return err;
        };
        self.terminal_mutex.unlock();

        renderer.searchState(search_enabled, self.search.query.items, self.search.matches.items, search_active, scroll_state.offset, search_scanning);
        self.render_snapshot.replay(renderer);
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
                self.processOutputChunk(buffer[offset..end]);
                self.refresh.request();
                offset = end;
            }
        }
        self.refresh.request();
    }

    fn processOutputChunk(self: *SessionRuntime, bytes: []const u8) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        self.progress_parser.feedEach(bytes, ProgressHandler{ .runtime = self });
        self.terminal.feed(bytes);
        self.search_content_generation +%= 1;
        _ = self.content_generation.fetchAdd(1, .monotonic);
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
};

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
