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
};

pub fn commandFromInt(value: u32) ?Command {
    return std.meta.intToEnum(Command, value) catch null;
}

const Callback = *const fn (?*anyopaque, u32, u32) callconv(.c) void;
pub const Started = *const fn (?*anyopaque, ?*anyopaque, win.HWND) callconv(.c) win.BOOL;
const Run = *const fn (Started, Callback, ?*anyopaque, [*]const u8, u32, [*]const u8, u32) callconv(.c) win.HRESULT;
const AttachTerminal = *const fn (?*anyopaque, win.HWND, ?*anyopaque) callconv(.c) win.HRESULT;
const FocusTerminal = *const fn (?*anyopaque) callconv(.c) win.HRESULT;
const Update = *const fn (?*anyopaque, [*]const [*]const u8, [*]const u32, u32, i32) callconv(.c) win.HRESULT;
const UpdateProfiles = *const fn (?*anyopaque, [*]const [*]const u8, [*]const u32, u32) callconv(.c) win.HRESULT;
const UpdateScrollbar = *const fn (?*anyopaque, u32, u32, u32, win.BOOL) callconv(.c) win.HRESULT;
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
    attach_terminal_fn: AttachTerminal,
    focus_terminal_fn: FocusTerminal,
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
        const attach_terminal_fn = symbol(AttachTerminal, module, "zigonaut_chrome_attach_terminal") orelse return null;
        const focus_terminal_fn = symbol(FocusTerminal, module, "zigonaut_chrome_focus_terminal") orelse return null;
        const update_fn = symbol(Update, module, "zigonaut_chrome_update") orelse return null;
        const update_profiles_fn = symbol(UpdateProfiles, module, "zigonaut_chrome_update_profiles") orelse return null;
        const update_scrollbar_fn = symbol(UpdateScrollbar, module, "zigonaut_chrome_update_scrollbar") orelse return null;
        const update_taskbar_progress_fn = symbol(UpdateTaskbarProgress, module, "zigonaut_chrome_update_taskbar_progress") orelse return null;
        const show_notification_fn = symbol(ShowNotification, module, "zigonaut_chrome_show_notification") orelse return null;
        const update_appearance_fn = symbol(UpdateAppearance, module, "zigonaut_chrome_update_appearance") orelse return null;
        loaded = true;
        return .{
            .module = module,
            .run_fn = run_fn,
            .attach_terminal_fn = attach_terminal_fn,
            .focus_terminal_fn = focus_terminal_fn,
            .update_fn = update_fn,
            .update_profiles_fn = update_profiles_fn,
            .update_scrollbar_fn = update_scrollbar_fn,
            .update_taskbar_progress_fn = update_taskbar_progress_fn,
            .show_notification_fn = show_notification_fn,
            .update_appearance_fn = update_appearance_fn,
        };
    }

    pub fn run(self: *Bridge, started: Started, callback: Callback, context: ?*anyopaque, version: []const u8, git_hash: []const u8) win.HRESULT {
        if (self.instance != null) return @bitCast(@as(u32, 0x8000ffff));
        const result = self.run_fn(
            started,
            callback,
            context,
            version.ptr,
            @intCast(version.len),
            git_hash.ptr,
            @intCast(git_hash.len),
        );
        self.instance = null;
        return result;
    }

    pub fn setInstance(self: *Bridge, instance: ?*anyopaque) bool {
        if (instance == null or self.instance != null) return false;
        self.instance = instance;
        return true;
    }

    pub fn attachTerminal(self: *Bridge, terminal: win.HWND, swap_chain: ?*anyopaque) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.attach_terminal_fn(instance, terminal, swap_chain));
    }

    pub fn focusTerminal(self: *Bridge) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.focus_terminal_fn(instance));
    }

    pub fn update(self: *Bridge, titles: []const [*]const u8, title_lengths: []const u32, active: ?usize) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.update_fn(instance, titles.ptr, title_lengths.ptr, @intCast(titles.len), if (active) |index| @intCast(index) else -1));
    }

    pub fn updateProfiles(self: *Bridge, names: []const [*]const u8, name_lengths: []const u32) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.update_profiles_fn(instance, names.ptr, name_lengths.ptr, @intCast(names.len)));
    }

    pub fn updateScrollbar(self: *Bridge, total: u32, page: u32, position: u32, show: bool) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.update_scrollbar_fn(instance, total, page, position, @intFromBool(show)));
    }

    pub fn updateTaskbarProgress(self: *Bridge, state: u32, value: u32) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.update_taskbar_progress_fn(instance, state, value));
    }

    pub fn showNotification(self: *Bridge, session_id: u32, title: []const u8, body: []const u8) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.show_notification_fn(instance, session_id, title.ptr, @intCast(title.len), body.ptr, @intCast(body.len)));
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
