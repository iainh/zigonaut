const win = @import("win32.zig").c;

const dll_name = "Zigonaut.WinUI.Bridge.dll";

pub const command = struct {
    pub const new_powershell = 1;
    pub const new_wsl = 2;
    pub const close = 3;
    pub const select = 4;
};

const Callback = *const fn (?*anyopaque, u32, u32) callconv(.c) void;
const Initialize = *const fn (win.HWND, Callback, ?*anyopaque) callconv(.c) ?*anyopaque;
const Update = *const fn (?*anyopaque, [*]const u8, u32, i32) callconv(.c) void;
const Move = *const fn (?*anyopaque, i32, i32, i32, i32) callconv(.c) void;
const Pretranslate = *const fn (?*anyopaque, *win.MSG) callconv(.c) win.BOOL;
const Close = *const fn (?*anyopaque) callconv(.c) void;
const Destroy = *const fn (?*anyopaque) callconv(.c) void;

pub const Bridge = struct {
    module: win.HMODULE,
    instance: ?*anyopaque,
    update_fn: Update,
    move_fn: Move,
    pretranslate_fn: Pretranslate,
    close_fn: Close,
    destroy_fn: Destroy,

    pub fn load(parent: win.HWND, callback: Callback, context: ?*anyopaque) ?Bridge {
        const module = win.LoadLibraryA(dll_name) orelse return null;
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

    pub fn update(self: *Bridge, kinds: []const u8, active: ?usize) void {
        self.update_fn(self.instance, kinds.ptr, @intCast(kinds.len), if (active) |index| @intCast(index) else -1);
    }

    pub fn move(self: *Bridge, x: i32, y: i32, width: i32, height: i32) void {
        self.move_fn(self.instance, x, y, width, height);
    }

    pub fn pretranslate(self: *Bridge, message: *win.MSG) bool {
        return self.pretranslate_fn(self.instance, message) != 0;
    }

    pub fn close(self: *Bridge) void {
        self.close_fn(self.instance);
    }

    pub fn deinit(self: *Bridge) void {
        self.destroy_fn(self.instance);
        _ = win.FreeLibrary(self.module);
    }
};

fn symbol(comptime T: type, module: win.HMODULE, name: [*:0]const u8) ?T {
    const address = win.GetProcAddress(module, name) orelse return null;
    return @ptrCast(address);
}
