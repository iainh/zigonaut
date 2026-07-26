const std = @import("std");
const directwrite_renderer = @import("directwrite_renderer.zig");
const pane_tree = @import("pane_tree.zig");
const SessionRuntime = @import("session.zig").SessionRuntime;
const theme = @import("theme.zig");

test {
    _ = directwrite_renderer;
    _ = @import("win32.zig");
    _ = @import("config.zig");
}

pub const Shell = enum { powershell, windows, wsl };

pub const Session = struct {
    id: u32,
    shell: Shell,
    runtime: ?*SessionRuntime,
    background: theme.Color,
    profile_title: std.ArrayList(u8) = .empty,
    command: std.ArrayList(u8) = .empty,
    working_directory: std.ArrayList(u8) = .empty,
    title: std.ArrayList(u8) = .empty,
    title_generation: u64 = 0,
    hold_on_exit: bool = false,

    pub fn displayTitle(self: *const Session) []const u8 {
        return if (self.title.items.len > 0 and std.unicode.utf8ValidateSlice(self.title.items)) self.title.items else self.profile_title.items;
    }
};

pub const Pane = struct { id: pane_tree.PaneId, session: Session };

/// A pane removed from the model.  The owner must first detach and destroy its
/// native presentation, then call `destroyRemovedPane`.  Keeping removal and
/// destruction separate prevents reader callbacks and swap chains from
/// observing a freed SessionRuntime.
pub const RemovedPane = struct {
    pane_id: pane_tree.PaneId,
    session: Session,
    removed_tab: bool,
};

pub const Tab = struct {
    id: u64,
    tree: pane_tree.Tree,
    panes: std.ArrayList(Pane) = .empty,

    pub fn pane(self: *Tab, id: pane_tree.PaneId) ?*Pane {
        for (self.panes.items) |*value| if (value.id == id) return value;
        return null;
    }

    pub fn focusedPane(self: *Tab) ?*Pane {
        return self.pane(self.tree.focused orelse return null);
    }

    pub fn displayTitle(self: *Tab) []const u8 {
        const focused = self.focusedPane() orelse return "";
        return focused.session.displayTitle();
    }
};

pub const App = struct {
    allocator: std.mem.Allocator,
    terminal_theme: theme.Theme,
    randomize_tab_background: bool,
    tabs: std.ArrayList(Tab) = .empty,
    active_tab: ?usize = null,
    next_object_id: u64 = 1,
    next_session_id: u32 = 1,
    refresh: SessionRuntime.Refresh = .{},
    terminal_size: ?TerminalSize = null,

    const TerminalSize = struct { columns: u16, rows: u16, cell_width: u32, cell_height: u32 };

    pub fn init(allocator: std.mem.Allocator, terminal_theme: theme.Theme, randomize_tab_background: bool) App {
        return .{ .allocator = allocator, .terminal_theme = terminal_theme, .randomize_tab_background = randomize_tab_background };
    }

    pub fn deinit(self: *App) void {
        for (self.tabs.items) |*tab| self.deinitTab(tab);
        self.tabs.deinit(self.allocator);
    }

    fn deinitSession(self: *App, session: *Session) void {
        if (session.runtime) |runtime| runtime.destroy();
        session.profile_title.deinit(self.allocator);
        session.command.deinit(self.allocator);
        session.working_directory.deinit(self.allocator);
        session.title.deinit(self.allocator);
    }

    fn deinitTab(self: *App, tab: *Tab) void {
        for (tab.panes.items) |*pane| self.deinitSession(&pane.session);
        tab.panes.deinit(self.allocator);
        tab.tree.deinit();
    }

    fn takeObjectId(self: *App) u64 {
        const id = self.next_object_id;
        self.next_object_id += 1;
        return id;
    }

    pub fn setRefresh(self: *App, refresh: SessionRuntime.Refresh) void {
        self.refresh = refresh;
    }

    pub fn addSession(self: *App, shell: Shell, profile_title: []const u8, command: []const u8, working_directory: []const u8, hold_on_exit: bool, columns: u16, rows: u16) !usize {
        const terminal_theme = if (self.randomize_tab_background) theme.randomizedBackground(self.terminal_theme, std.crypto.random.int(u16)) else self.terminal_theme;
        const runtime = try SessionRuntime.create(self.allocator, command, working_directory, terminal_theme, columns, rows, self.refresh);
        const index = self.addSessionRecord(shell, profile_title, command, working_directory, runtime, terminal_theme.background) catch |err| {
            runtime.destroy();
            return err;
        };
        self.activeSession().?.hold_on_exit = hold_on_exit;
        self.resizeActiveSession();
        return index;
    }

    fn addSessionRecord(self: *App, shell: Shell, profile_title: []const u8, command: []const u8, working_directory: []const u8, runtime: ?*SessionRuntime, background: theme.Color) !usize {
        var session = Session{ .id = self.next_session_id, .shell = shell, .runtime = runtime, .background = background };
        errdefer self.deinitSession(&session);
        try session.profile_title.appendSlice(self.allocator, profile_title);
        try session.command.appendSlice(self.allocator, command);
        try session.working_directory.appendSlice(self.allocator, working_directory);
        const tab_id = self.takeObjectId();
        const pane_id = self.takeObjectId();
        var tree = try pane_tree.Tree.init(self.allocator, pane_id);
        errdefer tree.deinit();
        var tab = Tab{ .id = tab_id, .tree = tree };
        try tab.panes.append(self.allocator, .{ .id = pane_id, .session = session });
        errdefer tab.panes.deinit(self.allocator);
        try self.tabs.append(self.allocator, tab);
        self.next_session_id +%= 1;
        if (self.next_session_id == 0) self.next_session_id = 1;
        self.active_tab = self.tabs.items.len - 1;
        return self.active_tab.?;
    }

    pub fn tabCount(self: *const App) usize {
        return self.tabs.items.len;
    }
    pub fn activeTabIndex(self: *const App) ?usize {
        return self.active_tab;
    }
    pub fn activeTab(self: *App) ?*Tab {
        return &self.tabs.items[self.active_tab orelse return null];
    }
    pub fn activePane(self: *App) ?*Pane {
        return (self.activeTab() orelse return null).focusedPane();
    }
    pub fn activeSession(self: *App) ?*Session {
        return &(self.activePane() orelse return null).session;
    }

    pub fn paneById(self: *App, id: pane_tree.PaneId) ?*Pane {
        for (self.tabs.items) |*tab| if (tab.pane(id)) |value| return value;
        return null;
    }

    pub fn runtimeForPane(self: *App, id: pane_tree.PaneId) ?*SessionRuntime {
        return (self.paneById(id) orelse return null).session.runtime;
    }

    pub fn focusPane(self: *App, id: pane_tree.PaneId) bool {
        for (self.tabs.items, 0..) |*tab, index| if (tab.tree.focus(id)) {
            self.active_tab = index;
            return true;
        };
        return false;
    }

    pub fn focusDirection(self: *App, direction: pane_tree.Direction) bool {
        return (self.activeTab() orelse return false).tree.focusDirection(direction);
    }

    pub fn setSplitRatio(self: *App, split_id: pane_tree.SplitId, ratio: u16) bool {
        const tab = self.activeTab() orelse return false;
        tab.tree.setRatio(split_id, ratio) catch return false;
        return true;
    }

    pub fn activeLayout(self: *App, allocator: std.mem.Allocator) ![]pane_tree.Item {
        return (self.activeTab() orelse return allocator.alloc(pane_tree.Item, 0)).tree.flatten(allocator);
    }

    pub fn splitFocused(self: *App, axis: pane_tree.Axis) !pane_tree.PaneId {
        const tab = self.activeTab() orelse return error.NoFocusedPane;
        const source = tab.focusedPane() orelse return error.NoFocusedPane;
        const size = self.terminal_size orelse TerminalSize{ .columns = 80, .rows = 24, .cell_width = 9, .cell_height = 18 };
        const session_theme = if (self.randomize_tab_background) theme.randomizedBackground(self.terminal_theme, std.crypto.random.int(u16)) else self.terminal_theme;
        const runtime = try SessionRuntime.create(self.allocator, source.session.command.items, source.session.working_directory.items, session_theme, size.columns, size.rows, self.refresh);
        return self.splitFocusedRecord(axis, runtime, session_theme.background);
    }

    fn splitFocusedRecord(self: *App, axis: pane_tree.Axis, runtime: ?*SessionRuntime, background: theme.Color) !pane_tree.PaneId {
        const tab = self.activeTab() orelse return error.NoFocusedPane;
        const source = tab.focusedPane() orelse return error.NoFocusedPane;
        var session = Session{ .id = self.next_session_id, .shell = source.session.shell, .runtime = runtime, .background = background, .hold_on_exit = source.session.hold_on_exit };
        errdefer self.deinitSession(&session);
        try session.profile_title.appendSlice(self.allocator, source.session.profile_title.items);
        try session.command.appendSlice(self.allocator, source.session.command.items);
        try session.working_directory.appendSlice(self.allocator, source.session.working_directory.items);
        const source_id = source.id;
        const pane_id = self.takeObjectId();
        const split_id = self.takeObjectId();
        try tab.panes.ensureUnusedCapacity(self.allocator, 1);
        try tab.tree.split(source_id, pane_id, split_id, axis);
        tab.panes.appendAssumeCapacity(.{ .id = pane_id, .session = session });
        _ = tab.tree.focus(pane_id);
        self.next_session_id +%= 1;
        if (self.next_session_id == 0) self.next_session_id = 1;
        return pane_id;
    }

    pub fn extractFocusedPane(self: *App) ?RemovedPane {
        const tab_index = self.active_tab orelse return null;
        const tab = &self.tabs.items[tab_index];
        const pane_id = tab.tree.focused orelse return null;
        return self.extractPane(tab_index, pane_id);
    }

    fn extractPane(self: *App, tab_index: usize, pane_id: pane_tree.PaneId) ?RemovedPane {
        var tab = &self.tabs.items[tab_index];
        for (tab.panes.items, 0..) |pane_value, index| if (pane_value.id == pane_id) {
            const removed = tab.panes.orderedRemove(index);
            _ = tab.tree.close(pane_id);
            const final = tab.panes.items.len == 0;
            if (final) {
                var empty_tab = self.tabs.orderedRemove(tab_index);
                empty_tab.panes.deinit(self.allocator);
                empty_tab.tree.deinit();
                if (self.tabs.items.len == 0) self.active_tab = null else self.active_tab = @min(tab_index, self.tabs.items.len - 1);
            }
            return .{ .pane_id = pane_id, .session = removed.session, .removed_tab = final };
        };
        return null;
    }

    /// Removes exactly one eligible pane without destroying its still-live runtime.
    pub fn extractCleanlyExitedPane(self: *App) ?RemovedPane {
        for (self.tabs.items, 0..) |*tab, tab_index| for (tab.panes.items) |pane| {
            const runtime = pane.session.runtime orelse continue;
            if (runtime.exitedCleanly() and !pane.session.hold_on_exit)
                return self.extractPane(tab_index, pane.id);
        };
        return null;
    }

    pub fn destroyRemovedPane(self: *App, removed: *RemovedPane) void {
        self.deinitSession(&removed.session);
    }

    pub fn activateTab(self: *App, index: usize) void {
        if (index < self.tabs.items.len) {
            self.active_tab = index;
            self.resizeActiveSession();
        }
    }

    pub fn closeTab(self: *App, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const active = self.active_tab;
        var removed = self.tabs.orderedRemove(index);
        self.deinitTab(&removed);
        if (self.tabs.items.len == 0) self.active_tab = null else if (active) |a| self.active_tab = if (a > index) a - 1 else @min(a, self.tabs.items.len - 1);
        self.resizeActiveSession();
    }

    fn closePane(self: *App, tab_index: usize, pane_id: pane_tree.PaneId) void {
        if (tab_index >= self.tabs.items.len) return;
        var tab = &self.tabs.items[tab_index];
        for (tab.panes.items, 0..) |pane, index| if (pane.id == pane_id) {
            var removed = tab.panes.orderedRemove(index);
            self.deinitSession(&removed.session);
            _ = tab.tree.close(pane_id);
            if (tab.panes.items.len == 0) self.closeTab(tab_index) else self.resizeActiveSession();
            return;
        };
    }

    pub fn activateSessionId(self: *App, id: u32) bool {
        for (self.tabs.items, 0..) |*tab, tab_index| for (tab.panes.items) |pane| if (pane.session.id == id) {
            self.active_tab = tab_index;
            _ = tab.tree.focus(pane.id);
            self.resizeActiveSession();
            return true;
        };
        return false;
    }

    pub fn runtimeIsLive(self: *const App, runtime: *SessionRuntime) bool {
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| if (pane.session.runtime == runtime) return true;
        return false;
    }

    pub fn hasPendingNotification(self: *App) bool {
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| if (pane.session.runtime) |runtime| if (runtime.hasPendingNotification()) return true;
        return false;
    }

    pub fn resizeSessions(self: *App, columns: u16, rows: u16, cell_width: u32, cell_height: u32) void {
        self.terminal_size = .{ .columns = columns, .rows = rows, .cell_width = cell_width, .cell_height = cell_height };
        self.resizeActiveSession();
    }

    fn resizeActiveSession(self: *App) void {
        const size = self.terminal_size orelse return;
        const session = self.activeSession() orelse return;
        if (session.runtime) |runtime| runtime.resize(size.columns, size.rows, size.cell_width, size.cell_height);
    }

    pub fn applySettings(self: *App, terminal_theme: theme.Theme, randomize_tab_background: bool) void {
        self.terminal_theme = terminal_theme;
        self.randomize_tab_background = randomize_tab_background;
        for (self.tabs.items) |*tab| for (tab.panes.items) |*pane| {
            const session_theme = if (randomize_tab_background) theme.randomizedBackground(terminal_theme, std.crypto.random.int(u16)) else terminal_theme;
            pane.session.background = session_theme.background;
            if (pane.session.runtime) |runtime| runtime.setTheme(session_theme);
        };
    }

    pub fn titlesGeneration(self: *const App) u64 {
        var generation: u64 = 0;
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| if (pane.session.runtime) |runtime| {
            generation +%= runtime.titleGeneration();
        };
        return generation;
    }

    pub fn hasCleanlyExitedSession(self: *const App) bool {
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| if (pane.session.runtime) |runtime| if (runtime.exitedCleanly()) return true;
        return false;
    }

    pub fn closeCleanlyExitedSessions(self: *App) bool {
        var changed = false;
        var ti = self.tabs.items.len;
        while (ti > 0) {
            ti -= 1;
            var pi = self.tabs.items[ti].panes.items.len;
            while (pi > 0) {
                pi -= 1;
                const pane = self.tabs.items[ti].panes.items[pi];
                const runtime = pane.session.runtime orelse continue;
                if (!runtime.exitedCleanly() or pane.session.hold_on_exit) continue;
                self.closePane(ti, pane.id);
                changed = true;
            }
        }
        return changed;
    }

    pub fn syncTitles(self: *App) bool {
        var changed = false;
        for (self.tabs.items) |*tab| for (tab.panes.items) |*pane| {
            const session = &pane.session;
            const runtime = session.runtime orelse continue;
            const generation = runtime.titleGeneration();
            if (generation == session.title_generation) continue;
            const title = runtime.titleAlloc(self.allocator) catch continue;
            session.title.deinit(self.allocator);
            session.title = .fromOwnedSlice(title);
            session.title_generation = generation;
            changed = true;
        };
        return changed;
    }
};

test "tabs are added selected and titled by focused pane" {
    var app = App.init(std.testing.allocator, theme.rasmus, true);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "PowerShell", "pwsh", "one", null, theme.rasmus.background);
    _ = try app.addSessionRecord(.wsl, "Linux", "wsl", "two", null, theme.rasmus.background);
    try std.testing.expectEqual(@as(usize, 2), app.tabCount());
    try std.testing.expectEqualStrings("Linux", app.activeTab().?.displayTitle());
    try std.testing.expectEqualStrings("wsl", app.activeSession().?.command.items);
    app.activateTab(0);
    try std.testing.expectEqual(Shell.powershell, app.activeSession().?.shell);
}

test "notification identity selects its tab and pane" {
    var app = App.init(std.testing.allocator, theme.rasmus, true);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "PowerShell", "", "", null, theme.rasmus.background);
    _ = try app.addSessionRecord(.wsl, "Linux", "", "", null, theme.rasmus.background);
    const id = app.tabs.items[0].panes.items[0].session.id;
    try std.testing.expect(app.activateSessionId(id));
    try std.testing.expectEqual(@as(?usize, 0), app.activeTabIndex());
    try std.testing.expect(!app.activateSessionId(999_999));
}

test "settings traverse panes and closing tabs preserves selection" {
    var app = App.init(std.testing.allocator, theme.rasmus, true);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "PowerShell", "", "", null, theme.rasmus.background);
    _ = try app.addSessionRecord(.wsl, "WSL", "", "", null, theme.rasmus.background);
    var replacement = theme.rasmus;
    replacement.background = .{ .red = 12, .green = 12, .blue = 12 };
    app.applySettings(replacement, false);
    try std.testing.expectEqual(replacement.background, app.tabs.items[0].panes.items[0].session.background);
    try std.testing.expectEqual(replacement.background, app.tabs.items[1].panes.items[0].session.background);
    app.closeTab(0);
    try std.testing.expectEqual(Shell.wsl, app.activeSession().?.shell);
    app.closeTab(0);
    try std.testing.expect(app.activeSession() == null);
}

test "split clones launch metadata, focuses new pane, and snapshots structure" {
    var app = App.init(std.testing.allocator, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.wsl, "Linux", "wsl -d Debian", "C:\\work", null, theme.rasmus.background);
    app.activeSession().?.hold_on_exit = true;
    const original = app.activePane().?.id;
    const created = try app.splitFocusedRecord(.left_right, null, theme.rasmus.background);
    try std.testing.expect(created != original);
    try std.testing.expectEqual(created, app.activePane().?.id);
    try std.testing.expectEqual(Shell.wsl, app.activeSession().?.shell);
    try std.testing.expectEqualStrings("wsl -d Debian", app.activeSession().?.command.items);
    try std.testing.expectEqualStrings("C:\\work", app.activeSession().?.working_directory.items);
    try std.testing.expect(app.activeSession().?.hold_on_exit);
    const layout = try app.activeLayout(std.testing.allocator);
    defer std.testing.allocator.free(layout);
    try std.testing.expectEqual(@as(usize, 3), layout.len);
    try std.testing.expectEqual(pane_tree.Axis.left_right, layout[0].split.axis);
    try std.testing.expectEqual(original, layout[1].leaf.id);
    try std.testing.expectEqual(created, layout[2].leaf.id);
}

test "focus title close extraction and stale identities" {
    var app = App.init(std.testing.allocator, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "first", "", "", null, theme.rasmus.background);
    const first = app.activePane().?.id;
    const second = try app.splitFocusedRecord(.top_bottom, null, theme.rasmus.background);
    try app.activeSession().?.title.appendSlice(std.testing.allocator, "second");
    try std.testing.expectEqualStrings("second", app.activeTab().?.displayTitle());
    try std.testing.expect(app.focusDirection(.up));
    try std.testing.expectEqual(first, app.activePane().?.id);
    try std.testing.expect(!app.focusPane(999999));
    try std.testing.expect(!app.setSplitRatio(999999, 123));
    try std.testing.expect(app.focusPane(second));
    var removed = app.extractFocusedPane().?;
    try std.testing.expectEqual(second, removed.pane_id);
    try std.testing.expect(!removed.removed_tab);
    app.destroyRemovedPane(&removed);
    try std.testing.expectEqual(first, app.activePane().?.id);
    var final = app.extractFocusedPane().?;
    try std.testing.expect(final.removed_tab);
    app.destroyRemovedPane(&final);
    try std.testing.expectEqual(@as(usize, 0), app.tabCount());
}
