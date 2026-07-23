const std = @import("std");
const SessionRuntime = @import("session.zig").SessionRuntime;

pub const Shell = enum {
    powershell,
    wsl,

    pub fn title(self: Shell) []const u8 {
        return switch (self) {
            .powershell => "PowerShell",
            .wsl => "WSL",
        };
    }

    pub fn command(self: Shell) []const u8 {
        return switch (self) {
            .powershell => "powershell.exe",
            .wsl => "wsl.exe",
        };
    }
};

pub const Session = struct {
    id: u32,
    shell: Shell,
    runtime: ?*SessionRuntime,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    sessions: std.ArrayList(Session) = .empty,
    active: ?usize = null,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *App) void {
        for (self.sessions.items) |session| {
            if (session.runtime) |runtime| runtime.destroy();
        }
        self.sessions.deinit(self.allocator);
    }

    pub fn addSession(self: *App, shell: Shell) !usize {
        const runtime = try SessionRuntime.create(self.allocator, shell.command());
        errdefer runtime.destroy();
        return self.addSessionRecord(shell, runtime);
    }

    fn addSessionRecord(self: *App, shell: Shell, runtime: ?*SessionRuntime) !usize {
        const index = self.sessions.items.len;
        try self.sessions.append(self.allocator, .{
            .id = self.next_id,
            .shell = shell,
            .runtime = runtime,
        });
        self.next_id +%= 1;
        self.active = index;
        return index;
    }

    pub fn closeSession(self: *App, index: usize) void {
        if (index >= self.sessions.items.len) return;
        const removed = self.sessions.orderedRemove(index);
        if (removed.runtime) |runtime| runtime.destroy();

        if (self.sessions.items.len == 0) {
            self.active = null;
        } else if (self.active) |active| {
            self.active = @min(active, self.sessions.items.len - 1);
        }
    }

    pub fn activate(self: *App, index: usize) void {
        if (index < self.sessions.items.len) self.active = index;
    }

    pub fn activeSession(self: *App) ?*Session {
        const index = self.active orelse return null;
        return &self.sessions.items[index];
    }

    pub fn resizeSessions(self: *App, columns: u16, rows: u16, cell_width: u32, cell_height: u32) void {
        for (self.sessions.items) |session| {
            if (session.runtime) |runtime| runtime.resize(columns, rows, cell_width, cell_height);
        }
    }
};

test "sessions are added and selected" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 0), try app.addSessionRecord(.powershell, null));
    try std.testing.expectEqual(@as(usize, 1), try app.addSessionRecord(.wsl, null));
    try std.testing.expectEqual(Shell.wsl, app.activeSession().?.shell);

    app.activate(0);
    try std.testing.expectEqual(Shell.powershell, app.activeSession().?.shell);
}

test "closing the active session selects its nearest neighbor" {
    var app = App.init(std.testing.allocator);
    defer app.deinit();

    _ = try app.addSessionRecord(.powershell, null);
    _ = try app.addSessionRecord(.wsl, null);
    app.closeSession(1);
    try std.testing.expectEqual(Shell.powershell, app.activeSession().?.shell);

    app.closeSession(0);
    try std.testing.expect(app.activeSession() == null);
}
