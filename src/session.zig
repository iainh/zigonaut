const std = @import("std");
const Pty = @import("pty.zig").Pty;
const Terminal = @import("terminal.zig").Terminal;

pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    pty: ?Pty = null,
    reader_thread: ?std.Thread = null,
    terminal_mutex: std.Thread.Mutex = .{},

    pub fn create(allocator: std.mem.Allocator, command: []const u8) !*SessionRuntime {
        const self = try allocator.create(SessionRuntime);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .terminal = try Terminal.init(100, 28),
        };
        errdefer self.terminal.deinit();

        self.pty = Pty.spawn(allocator, command, 100, 28) catch |err| {
            var message: [256]u8 = undefined;
            const text = std.fmt.bufPrint(
                &message,
                "\x1b[1;31mUnable to start {s}: {s}\x1b[0m\r\n",
                .{ command, @errorName(err) },
            ) catch "Unable to start shell.\r\n";
            self.terminal.feed(text);
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
        self.terminal.deinit();
        self.allocator.destroy(self);
    }

    pub fn writeViewportText(self: *SessionRuntime, output: []u8) ![]const u8 {
        self.terminal_mutex.lock();
        defer self.terminal_mutex.unlock();
        return self.terminal.writeViewportText(output);
    }

    pub fn resize(self: *SessionRuntime, columns: u16, rows: u16, cell_width: u32, cell_height: u32) void {
        self.terminal_mutex.lock();
        self.terminal.resize(columns, rows, cell_width, cell_height) catch {};
        self.terminal_mutex.unlock();
        if (self.pty) |*pty| pty.resize(columns, rows) catch {};
    }

    pub fn write(self: *SessionRuntime, bytes: []const u8) !void {
        if (self.pty) |*pty| return pty.write(bytes);
        return error.ShellNotRunning;
    }

    pub fn sendKey(self: *SessionRuntime, key: Terminal.Key, repeat: bool, modifiers: u16) !void {
        var buffer: [128]u8 = undefined;
        self.terminal_mutex.lock();
        const encoded = self.terminal.encodeKey(key, repeat, modifiers, &buffer) catch |err| {
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
        }
    }
};
