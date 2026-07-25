const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");
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

    pub fn create(
        allocator: std.mem.Allocator,
        command: []const u8,
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

        self.pty = Pty.spawn(allocator, command, columns, rows) catch |err| {
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
        self.terminal.deinit();
        self.allocator.destroy(self);
    }

    pub fn writeViewportText(self: *SessionRuntime, output: []u8) ![]const u8 {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.writeViewportText(output);
    }

    pub fn renderViewport(self: *SessionRuntime, renderer: anytype) !void {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
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
