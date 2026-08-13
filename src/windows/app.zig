const std = @import("std");
const config = @import("config.zig");
const directwrite_renderer = @import("directwrite_renderer.zig");
const shared = @import("shared");
const pane_tree = shared.pane_tree;
const SessionRuntime = @import("session.zig").SessionRuntime;

pub const max_tabs = 256;
const theme = shared.theme;

test {
    _ = directwrite_renderer;
    _ = @import("win32.zig");
}

pub const Shell = config.Shell;

fn appendWindowsArgument(allocator: std.mem.Allocator, output: *std.ArrayList(u8), argument: []const u8) !void {
    try output.append(allocator, '"');
    var backslashes: usize = 0;
    for (argument) |byte| {
        if (byte == '\\') {
            backslashes += 1;
            continue;
        }
        const count = if (byte == '"') backslashes * 2 + 1 else backslashes;
        for (0..count) |_| try output.append(allocator, '\\');
        backslashes = 0;
        try output.append(allocator, byte);
    }
    for (0..backslashes * 2) |_| try output.append(allocator, '\\');
    try output.append(allocator, '"');
}

fn wslLaunchCommandAlloc(allocator: std.mem.Allocator, shell: Shell, command: []const u8, working_directory: []const u8) !?[]u8 {
    if (shell != .wsl or !(std.mem.eql(u8, working_directory, "~") or
        std.mem.startsWith(u8, working_directory, "~/") or
        std.mem.startsWith(u8, working_directory, "/"))) return null;

    // Give Linux paths to WSL with --cd. Win32 cannot use these paths as the
    // current directory for CreateProcessW.
    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try result.appendSlice(allocator, command);
    try result.appendSlice(allocator, " --cd ");
    try appendWindowsArgument(allocator, &result, working_directory);
    return try result.toOwnedSlice(allocator);
}

const LaunchMetadata = struct {
    allocator: std.mem.Allocator,
    references: usize = 1,
    payload: []u8,
    profile_title_len: usize,
    command_len: usize,

    fn create(allocator: std.mem.Allocator, profile_title: []const u8, command: []const u8, working_directory: []const u8) !*LaunchMetadata {
        const self = try allocator.create(LaunchMetadata);
        errdefer allocator.destroy(self);
        const payload = try allocator.alloc(u8, profile_title.len + command.len + working_directory.len);
        @memcpy(payload[0..profile_title.len], profile_title);
        @memcpy(payload[profile_title.len..][0..command.len], command);
        @memcpy(payload[profile_title.len + command.len ..], working_directory);
        self.* = .{
            .allocator = allocator,
            .payload = payload,
            .profile_title_len = profile_title.len,
            .command_len = command.len,
        };
        return self;
    }

    fn retain(self: *LaunchMetadata) *LaunchMetadata {
        self.references += 1;
        return self;
    }

    fn release(self: *LaunchMetadata) void {
        self.references -= 1;
        if (self.references != 0) return;
        self.allocator.free(self.payload);
        self.allocator.destroy(self);
    }

    fn profileTitle(self: *const LaunchMetadata) []const u8 {
        return self.payload[0..self.profile_title_len];
    }

    fn commandSlice(self: *const LaunchMetadata) []const u8 {
        return self.payload[self.profile_title_len..][0..self.command_len];
    }

    fn workingDirectory(self: *const LaunchMetadata) []const u8 {
        return self.payload[self.profile_title_len + self.command_len ..];
    }
};

pub const Session = struct {
    id: u32,
    shell: Shell,
    runtime: ?*SessionRuntime,
    background: theme.Color,
    background_seed: u16,
    metadata: *LaunchMetadata,
    title: std.ArrayList(u8) = .empty,
    title_generation: u64 = 0,
    observed_output_generation: u64 = 0,
    hold_on_exit: bool = false,

    pub fn displayTitle(self: *const Session) []const u8 {
        return if (self.title.items.len > 0 and std.unicode.utf8ValidateSlice(self.title.items)) self.title.items else self.metadata.profileTitle();
    }

    pub fn command(self: *const Session) []const u8 {
        return self.metadata.commandSlice();
    }

    pub fn profileTitle(self: *const Session) []const u8 {
        return self.metadata.profileTitle();
    }

    pub fn workingDirectory(self: *const Session) []const u8 {
        return self.metadata.workingDirectory();
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
    has_unread_output: bool = false,

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
    io: std.Io,
    terminal_theme: theme.Theme,
    randomize_tab_background: bool,
    clipboard_write_enabled: bool = false,
    clipboard_write_max_bytes: u32 = 1024 * 1024,
    scrollback_size: u32 = 10_000,
    tabs: std.ArrayList(Tab) = .empty,
    active_tab: ?usize = null,
    next_object_id: u64 = 1,
    next_session_id: u32 = 1,
    refresh: SessionRuntime.Refresh = .{},
    terminal_size: ?TerminalSize = null,

    const TerminalSize = struct { columns: u16, rows: u16, cell_width: u32, cell_height: u32 };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, terminal_theme: theme.Theme, randomize_tab_background: bool) App {
        return .{ .allocator = allocator, .io = io, .terminal_theme = terminal_theme, .randomize_tab_background = randomize_tab_background };
    }

    pub fn deinit(self: *App) void {
        for (self.tabs.items) |*tab| self.deinitTab(tab);
        self.tabs.deinit(self.allocator);
    }

    fn deinitSession(self: *App, session: *Session) void {
        if (session.runtime) |runtime| {
            session.runtime = null;
            runtime.retire();
        }
        session.metadata.release();
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

    fn takeBackgroundSeed(self: *App) u16 {
        const random_source: std.Random.IoSource = .{ .io = self.io };
        const random = random_source.interface();
        const accent_count: usize = theme.random_accent_count;
        var used: [accent_count]bool = @splat(false);
        var used_count: usize = 0;
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| {
            const hue = pane.session.background_seed % theme.random_accent_count;
            if (!used[hue]) {
                used[hue] = true;
                used_count += 1;
            }
        };
        if (used_count == 0 or used_count == accent_count) {
            return random.uintLessThan(u16, theme.random_accent_count);
        }

        var largest_gap: u16 = 0;
        var largest_gap_count: u16 = 0;
        for (used, 0..) |occupied, start| {
            if (!occupied) continue;
            var gap: u16 = 1;
            while (gap < theme.random_accent_count and !used[(start + gap) % accent_count]) gap += 1;
            if (gap > largest_gap) {
                largest_gap = gap;
                largest_gap_count = 1;
            } else if (gap == largest_gap) {
                largest_gap_count += 1;
            }
        }

        var selected_gap = random.uintLessThan(u16, largest_gap_count);
        var gap_start: usize = 0;
        for (used, 0..) |occupied, start| {
            if (!occupied) continue;
            var gap: u16 = 1;
            while (gap < theme.random_accent_count and !used[(start + gap) % accent_count]) gap += 1;
            if (gap != largest_gap) continue;
            if (selected_gap == 0) {
                gap_start = start;
                break;
            }
            selected_gap -= 1;
        }

        const minimum_offset: u16 = @max(1, (largest_gap + 2) / 3);
        const maximum_offset: u16 = @min(largest_gap - 1, (largest_gap * 2) / 3);
        const offset = random.intRangeAtMost(u16, minimum_offset, maximum_offset);
        return @intCast((gap_start + offset) % accent_count);
    }

    pub fn addSession(self: *App, shell: Shell, profile_title: []const u8, command: []const u8, working_directory: []const u8, hold_on_exit: bool, columns: u16, rows: u16) !usize {
        if (self.tabs.items.len >= max_tabs) return error.TabLimitReached;
        const background_seed = self.takeBackgroundSeed();
        const terminal_theme = if (self.randomize_tab_background) theme.randomizedBackground(self.terminal_theme, background_seed) else self.terminal_theme;
        const wsl_command = try wslLaunchCommandAlloc(self.allocator, shell, command, working_directory);
        defer if (wsl_command) |value| self.allocator.free(value);
        const runtime = try SessionRuntime.create(self.allocator, wsl_command orelse command, if (wsl_command != null) "" else working_directory, terminal_theme, columns, rows, self.refresh, self.clipboard_write_enabled, self.clipboard_write_max_bytes, self.scrollback_size);
        const index = try self.addSessionRecord(shell, profile_title, command, working_directory, runtime, terminal_theme.background, background_seed);
        self.activeSession().?.hold_on_exit = hold_on_exit;
        self.resizeActiveSession();
        return index;
    }

    fn addSessionRecord(self: *App, shell: Shell, profile_title: []const u8, command: []const u8, working_directory: []const u8, runtime: ?*SessionRuntime, background: theme.Color, background_seed: u16) !usize {
        if (self.tabs.items.len >= max_tabs) return error.TabLimitReached;
        var unowned_runtime = runtime;
        errdefer if (unowned_runtime) |value| value.retire();
        const metadata = try LaunchMetadata.create(self.allocator, profile_title, command, working_directory);
        var session = Session{ .id = self.next_session_id, .shell = shell, .runtime = unowned_runtime, .background = background, .background_seed = background_seed, .metadata = metadata };
        unowned_runtime = null;
        errdefer self.deinitSession(&session);
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
        self.setActiveTab(self.tabs.items.len - 1);
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

    pub fn tabIndexById(self: *const App, id: u64) ?usize {
        for (self.tabs.items, 0..) |tab, index| if (tab.id == id) return index;
        return null;
    }

    pub fn runtimeForPane(self: *App, id: pane_tree.PaneId) ?*SessionRuntime {
        return (self.paneById(id) orelse return null).session.runtime;
    }

    pub fn focusPane(self: *App, id: pane_tree.PaneId) bool {
        for (self.tabs.items, 0..) |*tab, index| if (tab.tree.focus(id)) {
            self.setActiveTab(index);
            return true;
        };
        return false;
    }

    pub fn focusDirection(self: *App, direction: pane_tree.Direction) bool {
        return (self.activeTab() orelse return false).tree.focusDirection(direction);
    }

    pub fn focusCycle(self: *App, forward: bool) bool {
        return (self.activeTab() orelse return false).tree.focusCycle(forward);
    }

    pub fn resizeFocused(self: *App, direction: pane_tree.Direction) bool {
        return (self.activeTab() orelse return false).tree.resizeFocused(direction, 3277);
    }

    pub fn equalizePanes(self: *App) bool {
        return (self.activeTab() orelse return false).tree.equalize();
    }

    pub fn togglePaneZoom(self: *App) bool {
        return (self.activeTab() orelse return false).tree.toggleZoom();
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
        if (tab.panes.items.len >= pane_tree.max_panes) return error.PaneLimitReached;
        const source = tab.focusedPane() orelse return error.NoFocusedPane;
        const size = self.terminal_size orelse TerminalSize{ .columns = 80, .rows = 24, .cell_width = 9, .cell_height = 18 };
        const background_seed = self.takeBackgroundSeed();
        const session_theme = if (self.randomize_tab_background) theme.randomizedBackground(self.terminal_theme, background_seed) else self.terminal_theme;
        const reported_directory = if (source.session.runtime) |runtime| runtime.currentDirectoryAlloc(self.allocator) catch null else null;
        defer if (reported_directory) |directory| self.allocator.free(directory);
        const working_directory = reported_directory orelse source.session.workingDirectory();
        const wsl_command = try wslLaunchCommandAlloc(self.allocator, source.session.shell, source.session.command(), working_directory);
        defer if (wsl_command) |value| self.allocator.free(value);
        const runtime = try SessionRuntime.create(self.allocator, wsl_command orelse source.session.command(), if (wsl_command != null) "" else working_directory, session_theme, size.columns, size.rows, self.refresh, self.clipboard_write_enabled, self.clipboard_write_max_bytes, self.scrollback_size);
        return self.splitFocusedRecord(axis, runtime, session_theme.background, background_seed, reported_directory);
    }

    pub fn splitFocusedSession(self: *App, axis: pane_tree.Axis, shell: Shell, profile_title: []const u8, command: []const u8, working_directory: []const u8, hold_on_exit: bool) !pane_tree.PaneId {
        const tab = self.activeTab() orelse return error.NoFocusedPane;
        if (tab.panes.items.len >= pane_tree.max_panes) return error.PaneLimitReached;
        if (tab.focusedPane() == null) return error.NoFocusedPane;
        const size = self.terminal_size orelse TerminalSize{ .columns = 80, .rows = 24, .cell_width = 9, .cell_height = 18 };
        const background_seed = self.takeBackgroundSeed();
        const session_theme = if (self.randomize_tab_background) theme.randomizedBackground(self.terminal_theme, background_seed) else self.terminal_theme;
        const wsl_command = try wslLaunchCommandAlloc(self.allocator, shell, command, working_directory);
        defer if (wsl_command) |value| self.allocator.free(value);
        const runtime = try SessionRuntime.create(self.allocator, wsl_command orelse command, if (wsl_command != null) "" else working_directory, session_theme, size.columns, size.rows, self.refresh, self.clipboard_write_enabled, self.clipboard_write_max_bytes, self.scrollback_size);
        return self.insertFocusedSessionRecord(axis, shell, profile_title, command, working_directory, hold_on_exit, runtime, session_theme.background, background_seed);
    }

    fn splitFocusedRecord(self: *App, axis: pane_tree.Axis, runtime: ?*SessionRuntime, background: theme.Color, background_seed: u16, working_directory: ?[]const u8) !pane_tree.PaneId {
        const tab = self.activeTab() orelse return error.NoFocusedPane;
        const source = tab.focusedPane() orelse return error.NoFocusedPane;
        return self.insertFocusedSessionRecord(
            axis,
            source.session.shell,
            source.session.metadata.profileTitle(),
            source.session.command(),
            working_directory orelse source.session.workingDirectory(),
            source.session.hold_on_exit,
            runtime,
            background,
            background_seed,
        );
    }

    fn insertFocusedSessionRecord(self: *App, axis: pane_tree.Axis, shell: Shell, profile_title: []const u8, command: []const u8, working_directory: []const u8, hold_on_exit: bool, runtime: ?*SessionRuntime, background: theme.Color, background_seed: u16) !pane_tree.PaneId {
        var unowned_runtime = runtime;
        errdefer if (unowned_runtime) |value| value.retire();
        const tab = self.activeTab() orelse return error.NoFocusedPane;
        if (tab.panes.items.len >= pane_tree.max_panes) return error.PaneLimitReached;
        const source = tab.focusedPane() orelse return error.NoFocusedPane;
        const metadata = try LaunchMetadata.create(self.allocator, profile_title, command, working_directory);
        var session = Session{ .id = self.next_session_id, .shell = shell, .runtime = unowned_runtime, .background = background, .background_seed = background_seed, .metadata = metadata, .hold_on_exit = hold_on_exit };
        unowned_runtime = null;
        errdefer self.deinitSession(&session);
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
                if (self.tabs.items.len == 0) self.active_tab = null else self.setActiveTab(@min(tab_index, self.tabs.items.len - 1));
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
            self.setActiveTab(index);
            self.resizeActiveSession();
        }
    }

    pub fn moveTab(self: *App, from: usize, to: usize) !void {
        if (from >= self.tabs.items.len or to >= self.tabs.items.len or from == to) return;
        const active_id = if (self.active_tab) |index| self.tabs.items[index].id else null;
        const moved = self.tabs.orderedRemove(from);
        self.tabs.insertAssumeCapacity(to, moved);
        if (active_id) |id| for (self.tabs.items, 0..) |tab, index| if (tab.id == id) {
            self.active_tab = index;
            break;
        };
    }

    /// Moves `source_tab_id` immediately before `before_tab_id`. A zero anchor
    /// means the end of the strip. Stable anchors keep queued drag events valid
    /// when unrelated tabs are inserted or removed before the drop is handled.
    pub fn moveTabBefore(self: *App, source_tab_id: u64, before_tab_id: u64) !void {
        const source = self.tabIndexById(source_tab_id) orelse return error.TabNotFound;
        const destination = if (before_tab_id == 0)
            self.tabs.items.len - 1
        else blk: {
            const before = self.tabIndexById(before_tab_id) orelse return error.TabNotFound;
            if (source == before) return;
            break :blk before - @intFromBool(source < before);
        };
        try self.moveTab(source, destination);
    }

    /// Transfers a complete source tab into the target tab. The joining split
    /// and all ArrayList capacity are allocated before either tab is changed.
    pub fn mergeTabOntoPane(self: *App, source_tab_index: usize, target_pane_id: pane_tree.PaneId, direction: pane_tree.Direction) !void {
        if (source_tab_index >= self.tabs.items.len) return error.TabNotFound;
        var target_tab_index: ?usize = null;
        for (self.tabs.items, 0..) |*tab, index| if (tab.pane(target_pane_id) != null) {
            target_tab_index = index;
            break;
        };
        const target_index = target_tab_index orelse return error.PaneNotFound;
        if (target_index == source_tab_index) return error.SameTab;
        const source_count = self.tabs.items[source_tab_index].panes.items.len;
        if (self.tabs.items[target_index].panes.items.len + source_count > pane_tree.max_panes)
            return error.PaneLimitReached;

        try self.tabs.items[target_index].panes.ensureUnusedCapacity(self.allocator, source_count);
        const split_id = self.next_object_id;
        try self.tabs.items[target_index].tree.graft(
            target_pane_id,
            &self.tabs.items[source_tab_index].tree,
            split_id,
            direction,
        );
        self.next_object_id += 1;
        for (self.tabs.items[source_tab_index].panes.items) |pane|
            self.tabs.items[target_index].panes.appendAssumeCapacity(pane);
        self.tabs.items[source_tab_index].panes.clearRetainingCapacity();
        self.tabs.items[target_index].has_unread_output = self.tabs.items[target_index].has_unread_output or
            self.tabs.items[source_tab_index].has_unread_output;

        var source = self.tabs.orderedRemove(source_tab_index);
        source.panes.deinit(self.allocator);
        source.tree.deinit();
        const final_target = if (source_tab_index < target_index) target_index - 1 else target_index;
        self.setActiveTab(final_target);
        self.resizeActiveSession();
    }

    /// Repositions one live pane beside another pane in the same tab.
    pub fn movePaneOntoPane(self: *App, source_pane_id: pane_tree.PaneId, target_pane_id: pane_tree.PaneId, direction: pane_tree.Direction) !void {
        if (source_pane_id == target_pane_id) return error.SamePane;
        var source_tab_index: ?usize = null;
        var target_tab_index: ?usize = null;
        for (self.tabs.items, 0..) |*tab, index| {
            if (tab.pane(source_pane_id) != null) source_tab_index = index;
            if (tab.pane(target_pane_id) != null) target_tab_index = index;
        }
        const tab_index = source_tab_index orelse return error.PaneNotFound;
        const target_index = target_tab_index orelse return error.PaneNotFound;
        if (target_index != tab_index) return error.DifferentTab;
        if (self.tabs.items[tab_index].panes.items.len < 2) return error.SamePane;

        try self.tabs.items[tab_index].tree.movePane(
            source_pane_id,
            target_pane_id,
            self.next_object_id,
            direction,
        );
        self.next_object_id += 1;
        self.setActiveTab(tab_index);
        self.resizeActiveSession();
    }

    /// Moves a live pane into a newly inserted tab. If the pane already owns
    /// its tab, this is only a tab reorder and performs no tree/session rebuild.
    pub fn movePaneToNewTabBefore(self: *App, pane_id: pane_tree.PaneId, before_tab_id: u64) !void {
        const insertion_index = if (before_tab_id == 0)
            self.tabs.items.len
        else
            self.tabIndexById(before_tab_id) orelse return error.TabNotFound;
        try self.movePaneToNewTab(pane_id, insertion_index);
    }

    pub fn movePaneToNewTab(self: *App, pane_id: pane_tree.PaneId, insertion_index: usize) !void {
        if (insertion_index > self.tabs.items.len) return error.InvalidTabIndex;
        var source_tab_index: ?usize = null;
        var source_pane_index: ?usize = null;
        for (self.tabs.items, 0..) |tab, ti| for (tab.panes.items, 0..) |pane, pi| if (pane.id == pane_id) {
            source_tab_index = ti;
            source_pane_index = pi;
        };
        const source_index = source_tab_index orelse return error.PaneNotFound;
        if (self.tabs.items[source_index].panes.items.len == 1) {
            // `insertion_index` names the gap in the current strip. Removing a
            // tab before that gap shifts the final item index left by one.
            const destination = @min(
                insertion_index - @intFromBool(source_index < insertion_index),
                self.tabs.items.len - 1,
            );
            try self.moveTab(source_index, destination);
            self.setActiveTab(destination);
            self.resizeActiveSession();
            return;
        }
        if (self.tabs.items.len >= max_tabs) return error.TabLimitReached;

        // Build the detached destination completely before touching the source.
        try self.tabs.ensureUnusedCapacity(self.allocator, 1);
        var tree = try pane_tree.Tree.init(self.allocator, pane_id);
        errdefer tree.deinit();
        var panes: std.ArrayList(Pane) = .empty;
        errdefer panes.deinit(self.allocator);
        try panes.ensureUnusedCapacity(self.allocator, 1);

        const pane = self.tabs.items[source_index].panes.orderedRemove(source_pane_index.?);
        std.debug.assert(self.tabs.items[source_index].tree.close(pane_id));
        panes.appendAssumeCapacity(pane);
        const tab_id = self.next_object_id;
        self.next_object_id += 1;
        self.tabs.insertAssumeCapacity(insertion_index, .{ .id = tab_id, .tree = tree, .panes = panes });
        self.setActiveTab(insertion_index);
        self.resizeActiveSession();
    }

    fn observeTabOutput(tab: *Tab) void {
        for (tab.panes.items) |*pane| if (pane.session.runtime) |runtime| {
            pane.session.observed_output_generation = runtime.outputGeneration();
        };
    }

    fn setActiveTab(self: *App, index: usize) void {
        if (self.active_tab) |active| if (active < self.tabs.items.len) observeTabOutput(&self.tabs.items[active]);
        self.active_tab = index;
        const tab = &self.tabs.items[index];
        observeTabOutput(tab);
        tab.has_unread_output = false;
    }

    /// Consume runtime output generations on the UI thread and update sticky
    /// activity state for tabs that are not currently visible.
    pub fn refreshTabActivity(self: *App) bool {
        var changed = false;
        for (self.tabs.items, 0..) |*tab, tab_index| {
            var has_new_output = false;
            for (tab.panes.items) |*pane| if (pane.session.runtime) |runtime| {
                const generation = runtime.outputGeneration();
                if (generation != pane.session.observed_output_generation) {
                    pane.session.observed_output_generation = generation;
                    has_new_output = true;
                }
            };
            if (self.active_tab == tab_index) {
                if (tab.has_unread_output) {
                    tab.has_unread_output = false;
                    changed = true;
                }
            } else if (has_new_output and !tab.has_unread_output) {
                tab.has_unread_output = true;
                changed = true;
            }
        }
        return changed;
    }

    pub fn closeTab(self: *App, index: usize) void {
        if (index >= self.tabs.items.len) return;
        const active = self.active_tab;
        var removed = self.tabs.orderedRemove(index);
        self.deinitTab(&removed);
        if (self.tabs.items.len == 0) {
            self.active_tab = null;
        } else if (active) |a| {
            self.setActiveTab(if (a > index) a - 1 else @min(a, self.tabs.items.len - 1));
        }
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
            self.setActiveTab(tab_index);
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
            const session_theme = if (randomize_tab_background) theme.randomizedBackground(terminal_theme, pane.session.background_seed) else terminal_theme;
            pane.session.background = session_theme.background;
            if (pane.session.runtime) |runtime| runtime.setTheme(session_theme);
        };
    }

    pub fn applyClipboardWriteSettings(self: *App, enabled: bool, max_bytes: u32) void {
        self.clipboard_write_enabled = enabled;
        self.clipboard_write_max_bytes = max_bytes;
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| if (pane.session.runtime) |runtime| {
            runtime.setClipboardWriteSettings(enabled, max_bytes);
        };
    }

    pub fn setDefaultScrollbackSize(self: *App, size: u32) void {
        self.scrollback_size = size;
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

    pub fn hasSessionWaitingForProcessExit(self: *const App) bool {
        for (self.tabs.items) |tab| for (tab.panes.items) |pane| if (pane.session.runtime) |runtime| if (runtime.waitingForProcessExit()) return true;
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
            session.title_generation = runtime.copyTitle(self.allocator, &session.title) catch continue;
            changed = true;
        };
        return changed;
    }
};

test "tabs are added selected and titled by focused pane" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, true);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "PowerShell", "pwsh", "one", null, theme.rasmus.background, 1);
    _ = try app.addSessionRecord(.wsl, "Linux", "wsl", "two", null, theme.rasmus.background, 2);
    try std.testing.expectEqual(@as(usize, 2), app.tabCount());
    try std.testing.expectEqualStrings("Linux", app.activeTab().?.displayTitle());
    try std.testing.expectEqualStrings("wsl", app.activeSession().?.command());
    app.tabs.items[0].has_unread_output = true;
    app.activateTab(0);
    try std.testing.expect(!app.tabs.items[0].has_unread_output);
    try std.testing.expectEqual(Shell.powershell, app.activeSession().?.shell);
}

test "moving tabs preserves the active tab identity" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "One", "", "", null, theme.rasmus.background, 1);
    _ = try app.addSessionRecord(.windows, "Two", "", "", null, theme.rasmus.background, 2);
    _ = try app.addSessionRecord(.wsl, "Three", "", "", null, theme.rasmus.background, 3);
    app.activateTab(1);

    try app.moveTab(0, 2);
    try std.testing.expectEqualStrings("Two", app.activeTab().?.displayTitle());
    try std.testing.expectEqualStrings("Three", app.tabs.items[1].displayTitle());
    try std.testing.expectEqualStrings("One", app.tabs.items[2].displayTitle());
}

test "stable tab drop anchors survive intervening tab removal" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "One", "", "", null, theme.rasmus.background, 1);
    _ = try app.addSessionRecord(.powershell, "Two", "", "", null, theme.rasmus.background, 2);
    _ = try app.addSessionRecord(.powershell, "Three", "", "", null, theme.rasmus.background, 3);
    _ = try app.addSessionRecord(.powershell, "Four", "", "", null, theme.rasmus.background, 4);
    const two = app.tabs.items[1].id;
    const three = app.tabs.items[2].id;
    const four = app.tabs.items[3].id;

    app.closeTab(0);
    try app.moveTabBefore(four, three);
    try std.testing.expectEqualStrings("Two", app.tabs.items[0].displayTitle());
    try std.testing.expectEqualStrings("Four", app.tabs.items[1].displayTitle());
    try std.testing.expectEqualStrings("Three", app.tabs.items[2].displayTitle());
    try std.testing.expectEqual(four, app.activeTab().?.id);

    try std.testing.expectError(error.TabNotFound, app.moveTabBefore(two, 999_999));
    try std.testing.expectEqual(two, app.tabs.items[0].id);
    try std.testing.expectEqual(four, app.tabs.items[1].id);
    try std.testing.expectEqual(three, app.tabs.items[2].id);
}

test "notification identity selects its tab and pane" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, true);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "PowerShell", "", "", null, theme.rasmus.background, 1);
    _ = try app.addSessionRecord(.wsl, "Linux", "", "", null, theme.rasmus.background, 2);
    const id = app.tabs.items[0].panes.items[0].session.id;
    try std.testing.expect(app.activateSessionId(id));
    try std.testing.expectEqual(@as(?usize, 0), app.activeTabIndex());
    try std.testing.expect(!app.activateSessionId(999_999));
}

test "settings traverse panes and closing tabs preserves selection" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, true);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "PowerShell", "", "", null, theme.rasmus.background, 1);
    _ = try app.addSessionRecord(.wsl, "WSL", "", "", null, theme.rasmus.background, 2);
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

test "theme reload preserves each session background seed" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, true);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "PowerShell", "", "", null, theme.rasmus.background, 1234);
    _ = try app.addSessionRecord(.wsl, "WSL", "", "", null, theme.rasmus.background, 4321);

    app.applySettings(theme.rasmus, true);
    const first = app.tabs.items[0].panes.items[0].session.background;
    const second = app.tabs.items[1].panes.items[0].session.background;
    try std.testing.expect(!std.meta.eql(first, second));

    app.applySettings(theme.rasmus, true);
    try std.testing.expectEqual(first, app.tabs.items[0].panes.items[0].session.background);
    try std.testing.expectEqual(second, app.tabs.items[1].panes.items[0].session.background);
}

test "new background seeds use the middle of the largest hue gap" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, true);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "first", "", "", null, theme.rasmus.background, 0);
    _ = try app.addSessionRecord(.powershell, "second", "", "", null, theme.rasmus.background, theme.random_accent_count / 2);

    const seed = app.takeBackgroundSeed();
    const first_distance = @min(seed, theme.random_accent_count - seed);
    const second_hue = theme.random_accent_count / 2;
    const direct_second_distance = if (seed > second_hue) seed - second_hue else second_hue - seed;
    const second_distance = @min(direct_second_distance, theme.random_accent_count - direct_second_distance);
    try std.testing.expect(first_distance >= theme.random_accent_count / 6);
    try std.testing.expect(second_distance >= theme.random_accent_count / 6);
}

test "split clones launch metadata, focuses new pane, and snapshots structure" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.wsl, "Linux", "wsl -d Debian", "C:\\work", null, theme.rasmus.background, 1);
    app.activeSession().?.hold_on_exit = true;
    const original = app.activePane().?.id;
    const metadata = app.activeSession().?.metadata;
    const created = try app.splitFocusedRecord(.left_right, null, theme.rasmus.background, 2, "D:\\reported");
    try std.testing.expect(created != original);
    try std.testing.expectEqual(created, app.activePane().?.id);
    try std.testing.expect(metadata != app.activeSession().?.metadata);
    try std.testing.expectEqual(@as(usize, 1), metadata.references);
    try std.testing.expectEqual(Shell.wsl, app.activeSession().?.shell);
    try std.testing.expectEqualStrings("wsl -d Debian", app.activeSession().?.command());
    try std.testing.expectEqualStrings("D:\\reported", app.activeSession().?.workingDirectory());
    try std.testing.expect(app.activeSession().?.hold_on_exit);
    const layout = try app.activeLayout(std.testing.allocator);
    defer std.testing.allocator.free(layout);
    try std.testing.expectEqual(@as(usize, 3), layout.len);
    try std.testing.expectEqual(pane_tree.Axis.left_right, layout[0].split.axis);
    try std.testing.expectEqual(original, layout[1].leaf.id);
    try std.testing.expectEqual(created, layout[2].leaf.id);
}

test "WSL launch directories become --cd arguments" {
    const home = (try wslLaunchCommandAlloc(std.testing.allocator, .wsl, "wsl.exe", "~")).?;
    defer std.testing.allocator.free(home);
    try std.testing.expectEqualStrings("wsl.exe --cd \"~\"", home);

    const path = (try wslLaunchCommandAlloc(std.testing.allocator, .wsl, "wsl.exe -d Debian", "/home/Iain's work")).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("wsl.exe -d Debian --cd \"/home/Iain's work\"", path);

    try std.testing.expect((try wslLaunchCommandAlloc(std.testing.allocator, .wsl, "wsl.exe", "C:\\work")) == null);
    try std.testing.expect((try wslLaunchCommandAlloc(std.testing.allocator, .powershell, "pwsh.exe", "~")) == null);
}

test "focus title close extraction and stale identities" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "first", "", "", null, theme.rasmus.background, 1);
    const first = app.activePane().?.id;
    const second = try app.splitFocusedRecord(.top_bottom, null, theme.rasmus.background, 2, null);
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

test "tab and pane limits reject work before model mutation" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    for (0..max_tabs) |index| {
        _ = try app.addSessionRecord(.powershell, "test", "", "", null, theme.rasmus.background, @intCast(index));
    }
    try std.testing.expectError(
        error.TabLimitReached,
        app.addSessionRecord(.powershell, "overflow", "", "", null, theme.rasmus.background, 0),
    );
    try std.testing.expectEqual(@as(usize, max_tabs), app.tabCount());

    app.activateTab(0);
    for (1..pane_tree.max_panes) |index| {
        _ = try app.splitFocusedRecord(.left_right, null, theme.rasmus.background, @intCast(index), null);
    }
    try std.testing.expectError(
        error.PaneLimitReached,
        app.splitFocusedRecord(.left_right, null, theme.rasmus.background, 0, null),
    );
    try std.testing.expectEqual(@as(usize, pane_tree.max_panes), app.activeTab().?.panes.items.len);
}

test "merge tab grafts nested tree and keeps incoming focus" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "target", "", "", null, theme.rasmus.background, 1);
    const target = app.activePane().?.id;
    _ = try app.addSessionRecord(.wsl, "source", "", "", null, theme.rasmus.background, 2);
    const source_first = app.activePane().?.id;
    const source_focused = try app.splitFocusedRecord(.top_bottom, null, theme.rasmus.background, 3, null);
    const focused_session_id = app.activeSession().?.id;

    try app.mergeTabOntoPane(1, target, .left);
    try std.testing.expectEqual(@as(usize, 1), app.tabCount());
    try std.testing.expectEqual(source_focused, app.activePane().?.id);
    try std.testing.expectEqual(focused_session_id, app.activeSession().?.id);
    const layout = try app.activeLayout(std.testing.allocator);
    defer std.testing.allocator.free(layout);
    try std.testing.expectEqual(pane_tree.Axis.left_right, layout[0].split.axis);
    try std.testing.expectEqual(pane_tree.Axis.top_bottom, layout[1].split.axis);
    try std.testing.expectEqual(source_first, layout[2].leaf.id);
    try std.testing.expectEqual(source_focused, layout[3].leaf.id);
    try std.testing.expectEqual(target, layout[4].leaf.id);
}

test "moving pane creates inserted tab without replacing session ownership" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "first", "", "", null, theme.rasmus.background, 1);
    const moved = try app.splitFocusedRecord(.left_right, null, theme.rasmus.background, 2, null);
    const metadata = app.activeSession().?.metadata;
    const session_id = app.activeSession().?.id;

    try app.movePaneToNewTab(moved, 0);
    try std.testing.expectEqual(@as(usize, 2), app.tabCount());
    try std.testing.expectEqual(@as(?usize, 0), app.activeTabIndex());
    try std.testing.expectEqual(moved, app.activePane().?.id);
    try std.testing.expectEqual(session_id, app.activeSession().?.id);
    try std.testing.expect(metadata == app.activeSession().?.metadata);
    try std.testing.expectEqual(@as(usize, 1), app.tabs.items[1].panes.items.len);
}

test "stable pane-to-tab anchor survives intervening tab removal" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "first", "", "", null, theme.rasmus.background, 1);
    _ = try app.addSessionRecord(.powershell, "source", "", "", null, theme.rasmus.background, 2);
    const moved = try app.splitFocusedRecord(.left_right, null, theme.rasmus.background, 3, null);
    const moved_session = app.activeSession().?.id;
    _ = try app.addSessionRecord(.powershell, "anchor", "", "", null, theme.rasmus.background, 4);
    const anchor = app.activeTab().?.id;

    app.closeTab(0);
    try app.movePaneToNewTabBefore(moved, anchor);
    try std.testing.expectEqual(@as(usize, 3), app.tabCount());
    try std.testing.expectEqualStrings("source", app.tabs.items[0].displayTitle());
    try std.testing.expectEqual(moved, app.tabs.items[1].tree.focused.?);
    try std.testing.expectEqual(anchor, app.tabs.items[2].id);
    try std.testing.expectEqual(moved_session, app.activeSession().?.id);

    try std.testing.expectError(error.TabNotFound, app.movePaneToNewTabBefore(moved, 999_999));
    try std.testing.expectEqual(@as(usize, 3), app.tabCount());
}

test "moving pane onto pane rearranges the split without replacing sessions" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "first", "", "", null, theme.rasmus.background, 1);
    const first = app.activePane().?.id;
    const second = try app.splitFocusedRecord(.left_right, null, theme.rasmus.background, 2, null);
    const third = try app.splitFocusedRecord(.top_bottom, null, theme.rasmus.background, 3, null);
    const first_session = app.tabs.items[0].pane(first).?.session.id;

    try app.movePaneOntoPane(first, third, .down);
    try std.testing.expectEqual(@as(usize, 1), app.tabCount());
    try std.testing.expectEqual(first, app.activePane().?.id);
    try std.testing.expectEqual(first_session, app.activeSession().?.id);
    try std.testing.expectEqual(@as(usize, 3), app.activeTab().?.panes.items.len);
    const layout = try app.activeLayout(std.testing.allocator);
    defer std.testing.allocator.free(layout);
    try std.testing.expectEqual(second, layout[1].leaf.id);
    try std.testing.expectEqual(pane_tree.Axis.top_bottom, layout[2].split.axis);
    try std.testing.expectEqual(third, layout[3].leaf.id);
    try std.testing.expectEqual(first, layout[4].leaf.id);
}

test "moving a sole pane only reorders its tab and activates it" {
    var app = App.init(std.testing.allocator, std.testing.io, theme.rasmus, false);
    defer app.deinit();
    _ = try app.addSessionRecord(.powershell, "one", "", "", null, theme.rasmus.background, 1);
    const pane = app.activePane().?.id;
    const tab_id = app.activeTab().?.id;
    const metadata = app.activeSession().?.metadata;
    _ = try app.addSessionRecord(.wsl, "two", "", "", null, theme.rasmus.background, 2);
    _ = try app.addSessionRecord(.windows, "three", "", "", null, theme.rasmus.background, 3);

    try app.movePaneToNewTab(pane, 3);
    try std.testing.expectEqual(@as(usize, 3), app.tabCount());
    try std.testing.expectEqualStrings("two", app.tabs.items[0].displayTitle());
    try std.testing.expectEqual(@as(?usize, 2), app.activeTabIndex());
    try std.testing.expectEqual(tab_id, app.activeTab().?.id);
    try std.testing.expect(metadata == app.activeSession().?.metadata);
}
