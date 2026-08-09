const std = @import("std");

const abi = @cImport({
    @cInclude("zigonaut_core.h");
});

const symbols = [_][:0]const u8{
    "zigonaut_core_create",
    "zigonaut_core_resize",
    "zigonaut_core_request_stop",
    "zigonaut_core_write",
    "zigonaut_core_key",
    "zigonaut_core_paste",
    "zigonaut_core_scroll",
    "zigonaut_core_search_set",
    "zigonaut_core_search_status",
    "zigonaut_core_search_navigate",
    "zigonaut_core_search_clear",
    "zigonaut_core_navigate_prompt",
    "zigonaut_core_last_command_output",
    "zigonaut_core_working_directory",
    "zigonaut_core_selection_begin",
    "zigonaut_core_selection_update",
    "zigonaut_core_selection_end",
    "zigonaut_core_selection_clear",
    "zigonaut_core_has_selection",
    "zigonaut_core_copy_selection",
    "zigonaut_core_snapshot",
    "zigonaut_core_render_snapshot",
    "zigonaut_core_render_images",
    "zigonaut_core_set_theme",
    "zigonaut_core_set_scrollback",
    "zigonaut_core_progress",
    "zigonaut_core_has_foreground_job",
    "zigonaut_core_title",
    "zigonaut_core_link_at",
    "zigonaut_core_take_notification",
    "zigonaut_core_set_clipboard_write",
    "zigonaut_core_take_clipboard_write",
    "zigonaut_core_mouse_tracking",
    "zigonaut_core_mouse",
    "zigonaut_core_destroy",
};

test "public header compiles and dylib exports its contract" {
    try std.testing.expect(@sizeOf(abi.zigonaut_render_frame_v1) > 0);
    var library = try std.DynLib.open("zig-out/lib/libzigonaut-core.dylib");
    defer library.close();
    inline for (symbols) |symbol| {
        try std.testing.expect(library.lookup(*const anyopaque, symbol) != null);
    }
}
