const win = @import("win32.zig").c;
const std = @import("std");

const dll_name = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut.WinUI.Bridge.dll");

pub const command = struct {
    pub const new_powershell = 1;
    pub const new_wsl = 2;
    pub const close = 3;
    pub const select = 4;
    pub const open_settings = 5;
    pub const reload_settings = 6;
    pub const quit = 7;
};

const Callback = *const fn (?*anyopaque, u32, u32) callconv(.c) void;
const Initialize = *const fn (win.HWND, Callback, ?*anyopaque) callconv(.c) ?*anyopaque;
const Update = *const fn (?*anyopaque, [*]const [*]const u8, [*]const u32, u32, i32) callconv(.c) win.HRESULT;
const Move = *const fn (?*anyopaque, i32, i32, i32, i32) callconv(.c) win.HRESULT;
const Pretranslate = *const fn (?*anyopaque, *win.MSG) callconv(.c) win.BOOL;
const Close = *const fn (?*anyopaque) callconv(.c) win.HRESULT;
const Destroy = *const fn (?*anyopaque) callconv(.c) win.HRESULT;

pub const Bridge = struct {
    module: win.HMODULE,
    instance: ?*anyopaque,
    update_fn: Update,
    move_fn: Move,
    pretranslate_fn: Pretranslate,
    close_fn: Close,
    destroy_fn: Destroy,

    pub fn load(parent: win.HWND, callback: Callback, context: ?*anyopaque) ?Bridge {
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
        const initialize: Initialize = symbol(Initialize, module, "zigonaut_chrome_initialize") orelse return null;
        const update_fn = symbol(Update, module, "zigonaut_chrome_update") orelse return null;
        const move_fn = symbol(Move, module, "zigonaut_chrome_move") orelse return null;
        const pretranslate_fn = symbol(Pretranslate, module, "zigonaut_chrome_pretranslate") orelse return null;
        const close_fn = symbol(Close, module, "zigonaut_chrome_close") orelse return null;
        const destroy_fn = symbol(Destroy, module, "zigonaut_chrome_destroy") orelse return null;
        const instance = initialize(parent, callback, context) orelse return null;
        loaded = true;
        return .{ .module = module, .instance = instance, .update_fn = update_fn, .move_fn = move_fn, .pretranslate_fn = pretranslate_fn, .close_fn = close_fn, .destroy_fn = destroy_fn };
    }

    pub fn update(self: *Bridge, titles: []const [*]const u8, title_lengths: []const u32, active: ?usize) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.update_fn(instance, titles.ptr, title_lengths.ptr, @intCast(titles.len), if (active) |index| @intCast(index) else -1));
    }

    pub fn move(self: *Bridge, x: i32, y: i32, width: i32, height: i32) bool {
        const instance = self.instance orelse return false;
        return succeeded(self.move_fn(instance, x, y, width, height));
    }

    pub fn pretranslate(self: *Bridge, message: *win.MSG) bool {
        const instance = self.instance orelse return false;
        return self.pretranslate_fn(instance, message) != 0;
    }

    pub fn close(self: *Bridge) void {
        const instance = self.instance orelse return;
        _ = self.close_fn(instance);
    }

    pub fn deinit(self: *Bridge) bool {
        const instance = self.instance orelse return true;
        if (!succeeded(self.destroy_fn(instance))) return false;
        self.instance = null;
        // WinUI can retain delegate code until process teardown, so the bridge DLL must remain loaded.
        return true;
    }
};

fn succeeded(result: win.HRESULT) bool {
    return result >= 0;
}

fn symbol(comptime T: type, module: win.HMODULE, name: [*:0]const u8) ?T {
    const address = win.GetProcAddress(module, name) orelse return null;
    return @ptrCast(address);
}
