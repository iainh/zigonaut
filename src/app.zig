const std = @import("std");
const directwrite_renderer = @import("directwrite_renderer.zig");
const SessionRuntime = @import("session.zig").SessionRuntime;

test {
    _ = directwrite_renderer;
    _ = @import("win32.zig");
}
const theme = @import("theme.zig");

pub const Shell = enum {
    powershell,
    pwsh,
    cmd,
    wsl,
    custom,

    pub fn title(self: Shell) []const u8 {
        return switch (self) {
            .powershell => "PowerShell",
            .pwsh => "PowerShell 7",
            .cmd => "Command Prompt",
            .wsl => "WSL",
            .custom => "Custom",
        };
    }

    pub fn command(self: Shell) []const u8 {
        return switch (self) {
            .powershell => "powershell.exe",
            .pwsh => "pwsh.exe",
            .cmd => "cmd.exe",
            .wsl => "wsl.exe",
            .custom => "",
        };
    }
};

pub const Session = struct {
    id: u32,
    shell: Shell,
    runtime: ?*SessionRuntime,
    background: theme.Color,
    title: std.ArrayList(u8) = .empty,
    title_generation: u64 = 0,
    hold_on_exit: bool = false,

    pub fn displayTitle(self: *const Session) []const u8 {
        return if (self.title.items.len > 0 and std.unicode.utf8ValidateSlice(self.title.items)) self.title.items else self.shell.title();
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    terminal_theme: theme.Theme,
    randomize_tab_background: bool,
    sessions: std.ArrayList(Session) = .empty,
    active: ?usize = null,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, terminal_theme: theme.Theme, randomize_tab_background: bool) App {
        return .{
            .allocator = allocator,
            .terminal_theme = terminal_theme,
            .randomize_tab_background = randomize_tab_background,
        };
    }

    pub fn deinit(self: *App) void {
        for (self.sessions.items) |*session| {
            if (session.runtime) |runtime| runtime.destroy();
            session.title.deinit(self.allocator);
        }
        self.sessions.deinit(self.allocator);
    }

    pub fn addSession(self: *App, shell: Shell, profile_title: []const u8, command: []const u8, working_directory: []const u8, hold_on_exit: bool, columns: u16, rows: u16) !usize {
        if (command.len == 0) return error.ProfileNotConfigured;
        const terminal_theme = if (self.randomize_tab_background)
            theme.randomizedBackground(self.terminal_theme, std.crypto.random.int(u16))
        else
            self.terminal_theme;
        const runtime = try SessionRuntime.create(self.allocator, command, working_directory, terminal_theme, columns, rows);
        const index = self.addSessionRecord(shell, runtime, terminal_theme.background) catch |err| {
            runtime.destroy();
            return err;
        };
        errdefer self.closeSession(index);
        if (shell == .custom) try self.sessions.items[index].title.appendSlice(self.allocator, profile_title);
        self.sessions.items[index].hold_on_exit = hold_on_exit;
        return index;
    }

    fn addSessionRecord(self: *App, shell: Shell, runtime: ?*SessionRuntime, background: theme.Color) !usize {
        const index = self.sessions.items.len;
        try self.sessions.append(self.allocator, .{
            .id = self.next_id,
            .shell = shell,
            .runtime = runtime,
            .background = background,
        });
        self.next_id +%= 1;
        self.active = index;
        return index;
    }

    pub fn closeSession(self: *App, index: usize) void {
        if (index >= self.sessions.items.len) return;
        const active = self.active;
        var removed = self.sessions.orderedRemove(index);
        if (removed.runtime) |runtime| runtime.destroy();
        removed.title.deinit(self.allocator);

        if (self.sessions.items.len == 0) {
            self.active = null;
        } else if (active) |active_index| {
            self.active = if (active_index > index)
                active_index - 1
            else
                @min(active_index, self.sessions.items.len - 1);
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

    pub fn applySettings(self: *App, terminal_theme: theme.Theme, randomize_tab_background: bool) void {
        self.terminal_theme = terminal_theme;
        self.randomize_tab_background = randomize_tab_background;
        for (self.sessions.items) |*session| {
            const session_theme = if (randomize_tab_background)
                theme.randomizedBackground(terminal_theme, std.crypto.random.int(u16))
            else
                terminal_theme;
            session.background = session_theme.background;
            if (session.runtime) |runtime| runtime.setTheme(session_theme);
        }
    }

    pub fn titlesGeneration(self: *const App) u64 {
        var generation: u64 = 0;
        for (self.sessions.items) |session| {
            if (session.runtime) |runtime| generation +%= runtime.titleGeneration();
        }
        return generation;
    }

    pub fn hasCleanlyExitedSession(self: *const App) bool {
        for (self.sessions.items) |session| {
            if (session.runtime) |runtime| {
                if (runtime.exitedCleanly()) return true;
            }
        }
        return false;
    }

    pub fn closeCleanlyExitedSessions(self: *App) bool {
        var changed = false;
        var index = self.sessions.items.len;
        while (index > 0) {
            index -= 1;
            const runtime = self.sessions.items[index].runtime orelse continue;
            if (!runtime.exitedCleanly() or self.sessions.items[index].hold_on_exit) continue;
            self.closeSession(index);
            changed = true;
        }
        return changed;
    }

    pub fn syncTitles(self: *App) bool {
        var changed = false;
        for (self.sessions.items) |*session| {
            const runtime = session.runtime orelse continue;
            const generation = runtime.titleGeneration();
            if (generation == session.title_generation) continue;
            const title = runtime.titleAlloc(self.allocator) catch continue;
            session.title.deinit(self.allocator);
            session.title = .fromOwnedSlice(title);
            session.title_generation = generation;
            changed = true;
        }
        return changed;
    }
};

test "sessions are added and selected" {
    var app = App.init(std.testing.allocator, theme.rasmus, true);
    defer app.deinit();

    try std.testing.expectEqual(@as(usize, 0), try app.addSessionRecord(.powershell, null, theme.rasmus.background));
    try std.testing.expectEqual(@as(usize, 1), try app.addSessionRecord(.wsl, null, theme.rasmus.background));
    try std.testing.expectEqual(Shell.wsl, app.activeSession().?.shell);

    app.activate(0);
    try std.testing.expectEqual(Shell.powershell, app.activeSession().?.shell);
}

test "closing the active session selects its nearest neighbor" {
    var app = App.init(std.testing.allocator, theme.rasmus, true);
    defer app.deinit();

    _ = try app.addSessionRecord(.powershell, null, theme.rasmus.background);
    _ = try app.addSessionRecord(.wsl, null, theme.rasmus.background);
    app.closeSession(1);
    try std.testing.expectEqual(Shell.powershell, app.activeSession().?.shell);

    app.closeSession(0);
    try std.testing.expect(app.activeSession() == null);
}

test "closing a session before the active session preserves the selection" {
    var app = App.init(std.testing.allocator, theme.rasmus, true);
    defer app.deinit();

    _ = try app.addSessionRecord(.powershell, null, theme.rasmus.background);
    _ = try app.addSessionRecord(.wsl, null, theme.rasmus.background);
    app.closeSession(0);

    try std.testing.expectEqual(Shell.wsl, app.activeSession().?.shell);
}

test "applying settings updates existing session backgrounds" {
    var app = App.init(std.testing.allocator, theme.rasmus, true);
    defer app.deinit();

    _ = try app.addSessionRecord(.powershell, null, theme.rasmus.background);
    app.applySettings(theme.campbell, false);

    try std.testing.expectEqual(theme.campbell.background, app.sessions.items[0].background);
    try std.testing.expectEqual(theme.campbell, app.terminal_theme);
    try std.testing.expect(!app.randomize_tab_background);
}

test {
    _ = @import("config.zig");
}
