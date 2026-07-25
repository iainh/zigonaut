const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");
const Search = @import("search.zig").State;
const SearchMatch = @import("search.zig").Match;
const log = std.log.scoped(.session);

/// Heap-owned runtime with a stable address shared by Win32 and the reader thread.
/// Call `destroy` only after no caller can submit input or rendering work.
pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    pty: ?Pty = null,
    reader_thread: ?std.Thread = null,
    terminal_mutex: std.Thread.Mutex = .{},
    content_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    title: std.ArrayList(u8) = .empty,
    title_generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    search: Search = .{},

    pub fn create(
        allocator: std.mem.Allocator,
        command: []const u8,
        working_directory: []const u8,
        terminal_theme: theme.Theme,
        columns: u16,
        rows: u16,
    ) !*SessionRuntime {
        const self = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .terminal = try Terminal.init(columns, rows, terminal_theme),
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
        self.search.deinit(self.allocator);
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
        defer self.terminal_mutex.unlock();
        const scroll_state = self.terminal.scrollbar() catch Terminal.Scrollbar{ .total = 0, .offset = 0, .len = 0 };
        renderer.searchState(self.search.enabled, self.search.query.items, self.search.matches.items, self.search.active, scroll_state.offset, self.search.scanning);
        try self.terminal.renderViewport(renderer);
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

    pub fn searchTick(self: *SessionRuntime, rows_budget: usize) void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        if (self.search.query.items.len == 0) return;
        const generation = self.contentGeneration();
        if (!self.search.scanning and generation != self.search.scanned_generation) self.search.reset();
        const total = self.terminal.totalRows() catch return;
        var count: usize = 0;
        while (self.search.scanning and self.search.next_row < total and count < rows_budget) : (count += 1) {
            self.terminal.searchRow(self.allocator, self.search.next_row, self.search.query.items, &self.search.matches) catch return;
            self.search.next_row += 1;
        }
        if (self.search.next_row >= total) {
            self.search.scanning = false;
            self.search.scanned_generation = generation;
        }
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

    pub fn titleAlloc(self: *SessionRuntime, allocator: std.mem.Allocator) ![]u8 {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return allocator.dupe(u8, self.title.items);
    }

    pub fn resize(self: *SessionRuntime, columns: u16, rows: u16, cell_width: u32, cell_height: u32) void {
        self.terminal_mutex.lock();
        self.terminal.resize(columns, rows, cell_width, cell_height) catch |err| {
            log.warn("unable to resize terminal grid: {}", .{err});
        };
        self.terminal_mutex.unlock();
        if (self.pty) |*pty| pty.resize(columns, rows) catch |err| {
            log.warn("unable to resize pseudoconsole: {}", .{err});
        };
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

    pub fn sendKey(self: *SessionRuntime, key: Terminal.Key, action: Terminal.KeyAction, modifiers: u16) !void {
        var buffer: [128]u8 = undefined;
        self.terminal_mutex.lock();
        const encoded = self.terminal.encodeKey(key, action, modifiers, &buffer) catch |err| {
            self.terminal_mutex.unlock();
            return err;
        };
        self.terminal_mutex.unlock();
        try self.write(encoded);
    }

    fn readerMain(self: *SessionRuntime) void {
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            const count = self.pty.?.read(&buffer) catch break;
            if (count == 0) break;

            self.terminal_mutex.lock();
            self.terminal.feed(buffer[0..count]);
            self.terminal_mutex.unlock();
            _ = self.content_generation.fetchAdd(1, .monotonic);
        }
    }

    /// Ghostty invokes this synchronously from `Terminal.feed`, while the reader
    /// already holds `terminal_mutex`. Readers acquire that mutex in `titleAlloc`.
    fn titleChanged(context: ?*anyopaque, title: []const u8) void {
        const self: *SessionRuntime = @ptrCast(@alignCast(context orelse return));
        self.title.ensureTotalCapacity(self.allocator, title.len) catch return;
        self.title.clearRetainingCapacity();
        self.title.appendSliceAssumeCapacity(title);
        _ = self.title_generation.fetchAdd(1, .release);
    }
};
