pub const c = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("dwmapi.h");
    @cInclude("shellapi.h");
    @cInclude("bridge.h");
    @cInclude("directwrite_renderer.h");
});

/// Windows handles are opaque integer values despite being declared as typed
/// pointers. Their low bits are not required to satisfy Zig's pointer alignment.
pub fn handleFromInt(comptime T: type, value: usize) T {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

test "opaque Win32 handles preserve unaligned values" {
    const std = @import("std");
    const handle: c.HDC = handleFromInt(c.HDC, 3);
    try std.testing.expectEqual(@as(usize, 3), @intFromPtr(handle));
}
