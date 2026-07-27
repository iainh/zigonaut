const win = @import("win32.zig").c;
const std = @import("std");

const dll_name = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut.WinUI.Bridge.dll");

pub const Command = enum(u32) {
    new_profile = win.ZIGONAUT_CHROME_NEW_PROFILE,
    close = win.ZIGONAUT_CHROME_CLOSE,
    select = win.ZIGONAUT_CHROME_SELECT,
    open_settings = win.ZIGONAUT_CHROME_OPEN_SETTINGS,
    reload_settings = win.ZIGONAUT_CHROME_RELOAD_SETTINGS,
    quit = win.ZIGONAUT_CHROME_QUIT,
    scroll = win.ZIGONAUT_CHROME_SCROLL,
    scroll_wheel = win.ZIGONAUT_CHROME_SCROLL_WHEEL,
    notification_activate = win.ZIGONAUT_CHROME_NOTIFICATION_ACTIVATE,
    new_default = win.ZIGONAUT_CHROME_NEW_DEFAULT,
    zoom_in = win.ZIGONAUT_CHROME_ZOOM_IN,
    zoom_out = win.ZIGONAUT_CHROME_ZOOM_OUT,
    zoom_reset = win.ZIGONAUT_CHROME_ZOOM_RESET,
    select_next = win.ZIGONAUT_CHROME_SELECT_NEXT,
    select_previous = win.ZIGONAUT_CHROME_SELECT_PREVIOUS,
    shutdown = win.ZIGONAUT_CHROME_SHUTDOWN,
    split_right = win.ZIGONAUT_CHROME_SPLIT_RIGHT,
    split_down = win.ZIGONAUT_CHROME_SPLIT_DOWN,
    focus_left = win.ZIGONAUT_CHROME_FOCUS_LEFT,
    focus_right = win.ZIGONAUT_CHROME_FOCUS_RIGHT,
    focus_up = win.ZIGONAUT_CHROME_FOCUS_UP,
    focus_down = win.ZIGONAUT_CHROME_FOCUS_DOWN,
    close_pane = win.ZIGONAUT_CHROME_CLOSE_PANE,
};

pub fn commandFromInt(value: u32) ?Command {
    return std.meta.intToEnum(Command, value) catch null;
}

const Callback = *const fn (?*anyopaque, u32, u32) callconv(.c) void;
pub const PaneEvent = win.zigonaut_pane_event;
pub const LayoutNode = win.zigonaut_layout_node;
pub const pane_focus: u32 = @intCast(win.ZIGONAUT_PANE_EVENT_FOCUS);
pub const pane_committed_ratio: u32 = @intCast(win.ZIGONAUT_PANE_EVENT_COMMITTED_RATIO);
pub const pane_scroll: u32 = @intCast(win.ZIGONAUT_PANE_EVENT_SCROLL);
pub const pane_scroll_wheel: u32 = @intCast(win.ZIGONAUT_PANE_EVENT_SCROLL_WHEEL);
pub const layout_leaf: u32 = @intCast(win.ZIGONAUT_LAYOUT_LEAF);
pub const layout_split: u32 = @intCast(win.ZIGONAUT_LAYOUT_SPLIT);
pub const axis_left_right: u32 = @intCast(win.ZIGONAUT_AXIS_LEFT_RIGHT);
pub const axis_top_bottom: u32 = @intCast(win.ZIGONAUT_AXIS_TOP_BOTTOM);
const PaneCallback = *const fn (?*anyopaque, *const PaneEvent) callconv(.c) void;
pub const Started = *const fn (?*anyopaque, ?*anyopaque, win.HWND) callconv(.c) win.BOOL;
const Run = *const fn (Started, Callback, PaneCallback, ?*anyopaque, [*]const u8, u32, [*]const u8, u32) callconv(.c) win.HRESULT;
const AttachPane = *const fn (?*anyopaque, u64, win.HWND, ?*anyopaque, u32, u32, u32, u32) callconv(.c) win.HRESULT;
const DetachPane = *const fn (?*anyopaque, u64) callconv(.c) win.HRESULT;
const FocusPane = *const fn (?*anyopaque, u64) callconv(.c) win.HRESULT;
const UpdateLayout = *const fn (?*anyopaque, [*]const LayoutNode, u32, u64) callconv(.c) win.HRESULT;
const Update = *const fn (?*anyopaque, [*]const [*]const u8, [*]const u32, u32, i32) callconv(.c) win.HRESULT;
const UpdateProfiles = *const fn (?*anyopaque, [*]const [*]const u8, [*]const u32, u32) callconv(.c) win.HRESULT;
const UpdateScrollbar = *const fn (?*anyopaque, u64, u32, u32, u32, win.BOOL) callconv(.c) win.HRESULT;
const UpdateTaskbarProgress = *const fn (?*anyopaque, u32, u32) callconv(.c) win.HRESULT;
const ShowNotification = *const fn (?*anyopaque, u32, [*]const u8, u32, [*]const u8, u32) callconv(.c) win.HRESULT;
const UpdateAppearance = *const fn (?*anyopaque, u32, win.BOOL, win.BOOL) callconv(.c) win.HRESULT;

/// UI-thread-owned full WinUI window. `run` owns the WinUI application pump and
/// blocks until its Window closes. The DLL deliberately stays loaded because
/// WinUI can retain delegate code until process teardown.
pub const Bridge = struct {
    module: win.HMODULE,
    instance: ?*anyopaque = null,
    run_fn: Run,
    attach_pane_fn: AttachPane,
    detach_pane_fn: DetachPane,
    focus_pane_fn: FocusPane,
    update_layout_fn: UpdateLayout,
    update_fn: Update,
    update_profiles_fn: UpdateProfiles,
    update_scrollbar_fn: UpdateScrollbar,
    update_taskbar_progress_fn: UpdateTaskbarProgress,
    show_notification_fn: ShowNotification,
    update_appearance_fn: UpdateAppearance,

    pub fn load() ?Bridge {
        var path: [win.MAX_PATH]u16 = undefined;
        const path_length = win.GetModuleFileNameW(null, &path, path.len);
        if (path_length == 0 or path_length >= path.len) return null;
        const directory_end = std.mem.lastIndexOfScalar(u16, path[0..path_length], '\\') orelse return null;
        if (directory_end + 1 + dll_name.len >= path.len) return null;
        @memcpy(path[directory_end + 1 ..][0..dll_name.len], dll_name);
        path[directory_end + 1 + dll_name.len] = 0;

        const module = win.LoadLibraryExW(
            &path,
            null,
            win.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | win.LOAD_LIBRARY_SEARCH_APPLICATION_DIR | win.LOAD_LIBRARY_SEARCH_SYSTEM32,
        ) orelse return null;
        var loaded = false;
        defer {
            if (!loaded) _ = win.FreeLibrary(module);
        }
        const run_fn = symbol(Run, module, "zigonaut_window_run") orelse return null;
        const attach_pane_fn = symbol(AttachPane, module, "zigonaut_chrome_attach_pane") orelse return null;
        const detach_pane_fn = symbol(DetachPane, module, "zigonaut_chrome_detach_pane") orelse return null;
        const focus_pane_fn = symbol(FocusPane, module, "zigonaut_chrome_focus_pane") orelse return null;
        const update_layout_fn = symbol(UpdateLayout, module, "zigonaut_chrome_update_layout") orelse return null;
        const update_fn = symbol(Update, module, "zigonaut_chrome_update") orelse return null;
        const update_profiles_fn = symbol(UpdateProfiles, module, "zigonaut_chrome_update_profiles") orelse return null;
        const update_scrollbar_fn = symbol(UpdateScrollbar, module, "zigonaut_chrome_update_pane_scrollbar") orelse return null;
        const update_taskbar_progress_fn = symbol(UpdateTaskbarProgress, module, "zigonaut_chrome_update_taskbar_progress") orelse return null;
        const show_notification_fn = symbol(ShowNotification, module, "zigonaut_chrome_show_notification") orelse return null;
        const update_appearance_fn = symbol(UpdateAppearance, module, "zigonaut_chrome_update_appearance") orelse return null;
        loaded = true;
        return .{
            .module = module,
            .run_fn = run_fn,
            .attach_pane_fn = attach_pane_fn,
            .detach_pane_fn = detach_pane_fn,
            .focus_pane_fn = focus_pane_fn,
            .update_layout_fn = update_layout_fn,
            .update_fn = update_fn,
            .update_profiles_fn = update_profiles_fn,
            .update_scrollbar_fn = update_scrollbar_fn,
            .update_taskbar_progress_fn = update_taskbar_progress_fn,
            .show_notification_fn = show_notification_fn,
            .update_appearance_fn = update_appearance_fn,
        };
    }

    pub fn run(self: *Bridge, started: Started, callback: Callback, pane_callback: PaneCallback, context: ?*anyopaque, version: []const u8, git_hash: []const u8) win.HRESULT {
        if (self.instance != null) return win.E_UNEXPECTED;
        const version_length = stringLength(version.len) orelse return win.E_INVALIDARG;
        const git_hash_length = stringLength(git_hash.len) orelse return win.E_INVALIDARG;
        const result = self.run_fn(
            started,
            callback,
            pane_callback,
            context,
            version.ptr,
            version_length,
            git_hash.ptr,
            git_hash_length,
        );
        self.instance = null;
        return result;
    }

    pub fn setInstance(self: *Bridge, instance: ?*anyopaque) bool {
        if (instance == null or self.instance != null) return false;
        self.instance = instance;
        return true;
    }

    pub fn attachPane(self: *Bridge, id: u64, terminal: win.HWND, swap_chain: ?*anyopaque, cell_width: u32, cell_height: u32, minimum_width: u32, minimum_height: u32) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.attach_pane_fn(instance, id, terminal, swap_chain, cell_width, cell_height, minimum_width, minimum_height));
    }

    pub fn detachPane(self: *Bridge, id: u64) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.detach_pane_fn(instance, id));
    }
    pub fn focusPane(self: *Bridge, id: u64) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.focus_pane_fn(instance, id));
    }
    pub fn updateLayout(self: *Bridge, nodes: []const LayoutNode, focused: u64) bool {
        const instance = self.instance orelse return false;
        const count = std.math.cast(u32, nodes.len) orelse return false;
        return succeeded(self.update_layout_fn(instance, nodes.ptr, count, focused));
    }

    pub fn update(self: *Bridge, titles: []const [*]const u8, title_lengths: []const u32, active: ?usize) bool {
        const instance = self.instance orelse return false;
        if (titles.len != title_lengths.len) return false;
        const count = std.math.cast(u32, titles.len) orelse return false;
        const active_index = if (active) |index| std.math.cast(i32, index) orelse return false else -1;
        for (title_lengths) |length| if (length > std.math.maxInt(i32)) return false;
        return succeeded(self.update_fn(instance, titles.ptr, title_lengths.ptr, count, active_index));
    }

    pub fn updateProfiles(self: *Bridge, names: []const [*]const u8, name_lengths: []const u32) bool {
        const instance = self.instance orelse return false;
        if (names.len == 0 or names.len != name_lengths.len) return false;
        const count = std.math.cast(u32, names.len) orelse return false;
        for (name_lengths) |length| if (length > std.math.maxInt(i32)) return false;
        return succeeded(self.update_profiles_fn(instance, names.ptr, name_lengths.ptr, count));
    }

    pub fn updateScrollbar(self: *Bridge, pane_id: u64, total: u32, page: u32, position: u32, show: bool) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.update_scrollbar_fn(instance, pane_id, total, page, position, @intFromBool(show)));
    }

    pub fn updateTaskbarProgress(self: *Bridge, state: u32, value: u32) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.update_taskbar_progress_fn(instance, state, value));
    }

    pub fn showNotification(self: *Bridge, session_id: u32, title: []const u8, body: []const u8) bool {
        const instance = self.instance orelse return false;
        const title_length = stringLength(title.len) orelse return false;
        const body_length = stringLength(body.len) orelse return false;
        return succeeded(self.show_notification_fn(instance, session_id, title.ptr, title_length, body.ptr, body_length));
    }

    pub fn updateAppearance(self: *Bridge, backdrop: u32, high_contrast: bool, dark_theme: bool) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.update_appearance_fn(instance, backdrop, @intFromBool(high_contrast), @intFromBool(dark_theme)));
    }

    pub fn detach(self: *Bridge) void {
        self.instance = null;
    }
};

pub fn succeeded(result: win.HRESULT) bool {
    return result >= 0;
}

fn stringLength(length: usize) ?u32 {
    if (length > std.math.maxInt(i32)) return null;
    return @intCast(length);
}

fn symbol(comptime T: type, module: win.HMODULE, name: [*:0]const u8) ?T {
    const address = win.GetProcAddress(module, name) orelse return null;
    return @ptrCast(address);
}

test "chrome commands match the shared ABI" {
    try std.testing.expectEqual(Command.open_settings, commandFromInt(win.ZIGONAUT_CHROME_OPEN_SETTINGS).?);
    try std.testing.expectEqual(Command.quit, commandFromInt(win.ZIGONAUT_CHROME_QUIT).?);
    try std.testing.expect(commandFromInt(0) == null);
    try std.testing.expectEqual(Command.scroll, commandFromInt(win.ZIGONAUT_CHROME_SCROLL).?);
    try std.testing.expectEqual(Command.scroll_wheel, commandFromInt(win.ZIGONAUT_CHROME_SCROLL_WHEEL).?);
    try std.testing.expectEqual(Command.new_profile, commandFromInt(win.ZIGONAUT_CHROME_NEW_PROFILE).?);
    try std.testing.expectEqual(Command.notification_activate, commandFromInt(win.ZIGONAUT_CHROME_NOTIFICATION_ACTIVATE).?);
    try std.testing.expectEqual(Command.new_default, commandFromInt(win.ZIGONAUT_CHROME_NEW_DEFAULT).?);
    try std.testing.expectEqual(Command.shutdown, commandFromInt(win.ZIGONAUT_CHROME_SHUTDOWN).?);
    try std.testing.expectEqual(Command.zoom_in, commandFromInt(win.ZIGONAUT_CHROME_ZOOM_IN).?);
    try std.testing.expect(commandFromInt(2) == null);
}

test "chrome string lengths fit the Win32 UTF-8 conversion API" {
    const maximum: usize = std.math.maxInt(i32);
    try std.testing.expectEqual(@as(?u32, @intCast(maximum)), stringLength(maximum));
    try std.testing.expectEqual(@as(?u32, null), stringLength(maximum + 1));
}
