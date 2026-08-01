pub const c = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cDefine("_WIN32_WINNT", "0x0A00");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("windows.h");
    @cInclude("tlhelp32.h");
    @cInclude("commctrl.h");
    @cInclude("dwmapi.h");
    @cInclude("shellapi.h");
    @cInclude("bridge.h");
    @cInclude("directwrite_renderer.h");
});

const std = @import("std");

pub fn environmentVariableAlloc(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const wide_name = try std.unicode.utf8ToUtf16LeAllocZ(allocator, name);
    defer allocator.free(wide_name);
    const required = c.GetEnvironmentVariableW(wide_name.ptr, null, 0);
    if (required == 0) return error.EnvironmentVariableNotFound;
    const wide_value = try allocator.alloc(u16, required);
    defer allocator.free(wide_value);
    const length = c.GetEnvironmentVariableW(wide_name.ptr, wide_value.ptr, required);
    if (length == 0 or length >= required) return error.EnvironmentVariableUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide_value[0..length]);
}

pub fn applicationFilePathAlloc(allocator: std.mem.Allocator, relative_path: []const u16) ![:0]u16 {
    // Use the Windows extended-path limit. MAX_PATH would reject valid
    // installation paths before GetModuleFileNameW can return them.
    const buffer = try allocator.alloc(u16, 32_768);
    defer allocator.free(buffer);
    const path_length = c.GetModuleFileNameW(null, buffer.ptr, @intCast(buffer.len));
    if (path_length == 0 or path_length >= buffer.len) return error.ApplicationPathUnavailable;
    const directory_end = std.mem.lastIndexOfScalar(u16, buffer[0..path_length], '\\') orelse
        return error.ApplicationPathUnavailable;
    const result_length = directory_end + 1 + relative_path.len;
    if (result_length >= buffer.len) return error.ApplicationPathTooLong;
    const result = try allocator.allocSentinel(u16, result_length, 0);
    @memcpy(result[0 .. directory_end + 1], buffer[0 .. directory_end + 1]);
    @memcpy(result[directory_end + 1 ..], relative_path);
    return result;
}

pub const Mutex = struct {
    state: c.SRWLOCK = std.mem.zeroes(c.SRWLOCK),

    pub fn lock(self: *Mutex) void {
        c.AcquireSRWLockExclusive(&self.state);
    }

    pub fn unlock(self: *Mutex) void {
        c.ReleaseSRWLockExclusive(&self.state);
    }
};

pub fn monotonicNanoseconds() ?u64 {
    var frequency: c.LARGE_INTEGER = undefined;
    var counter: c.LARGE_INTEGER = undefined;
    if (c.QueryPerformanceFrequency(&frequency) == 0 or c.QueryPerformanceCounter(&counter) == 0) return null;
    if (frequency.QuadPart <= 0 or counter.QuadPart < 0) return null;
    const nanoseconds = @as(u128, @intCast(counter.QuadPart)) * std.time.ns_per_s /
        @as(u128, @intCast(frequency.QuadPart));
    return @intCast(nanoseconds);
}

/// Windows handles are opaque integer values despite being declared as typed
/// pointers. Their low bits are not required to satisfy Zig's pointer alignment.
pub fn handleFromInt(comptime T: type, value: usize) T {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

test "opaque Win32 handles preserve unaligned values" {
    const handle: c.HDC = handleFromInt(c.HDC, 3);
    try std.testing.expectEqual(@as(usize, 3), @intFromPtr(handle));
}
