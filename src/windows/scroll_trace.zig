const win32 = @import("win32.zig");
const win = win32.c;

pub const Event = enum(c_uint) {
    input = 1,
    invalidated,
    frame_wait_armed,
    frame_wait_completed,
    capture_started,
    capture_lock_acquired,
    capture_completed,
    paint_started,
    render_path,
    paint_completed,
    paint_failed,
    present_retry,
    present_succeeded,
};

comptime {
    if (@intFromEnum(Event.input) != win.ZIGONAUT_SCROLL_TRACE_INPUT or
        @intFromEnum(Event.present_succeeded) != win.ZIGONAUT_SCROLL_TRACE_PRESENT_SUCCEEDED)
        @compileError("scroll trace event IDs disagree with scroll_trace.h");
}

pub fn register() void {
    win.zigonaut_scroll_trace_register();
}

pub fn unregister() void {
    win.zigonaut_scroll_trace_unregister();
}

pub fn enabled() bool {
    return win.zigonaut_scroll_trace_enabled() != 0;
}

pub fn write(event: Event, pane_id: u64, request_id: u64, value1: i64, value2: i64) void {
    win.zigonaut_scroll_trace_write(@intFromEnum(event), pane_id, request_id, value1, value2);
}
