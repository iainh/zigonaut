const std = @import("std");

const abi = @cImport({
    @cInclude("zigonaut_core.h");
});

const symbols = [_][:0]const u8{
    "zigonaut_panes_create",
    "zigonaut_panes_destroy",
    "zigonaut_panes_split",
    "zigonaut_panes_move",
    "zigonaut_panes_close",
    "zigonaut_panes_focus",
    "zigonaut_panes_focused",
    "zigonaut_panes_zoomed",
    "zigonaut_panes_action",
    "zigonaut_panes_can_resize",
    "zigonaut_panes_ratio",
    "zigonaut_panes_nodes",
    "zigonaut_panes_destination",
    "zigonaut_panes_drop_edge",
    "zigonaut_core_create",
    "zigonaut_core_resize",
    "zigonaut_core_request_stop",
    "zigonaut_core_write",
    "zigonaut_core_key",
    "zigonaut_core_paste",
    "zigonaut_core_scroll",
    "zigonaut_core_scroll_fractional",
    "zigonaut_core_compress",
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
    "zigonaut_core_accessibility_snapshot",
    "zigonaut_accessibility_build",
    "zigonaut_accessibility_release",
    "zigonaut_accessibility_get_view",
    "zigonaut_accessibility_line",
    "zigonaut_accessibility_grid_rect",
    "zigonaut_core_render_images",
    "zigonaut_core_set_theme",
    "zigonaut_core_set_scrollback",
    "zigonaut_core_set_intense_text_style",
    "zigonaut_core_progress",
    "zigonaut_core_program_status",
    "zigonaut_core_has_foreground_job",
    "zigonaut_core_title",
    "zigonaut_core_link_at",
    "zigonaut_hint_key",
    "zigonaut_hint_suffix",
    "zigonaut_core_link_cached",
    "zigonaut_core_take_notification",
    "zigonaut_core_set_command_notifications",
    "zigonaut_core_set_clipboard_write",
    "zigonaut_core_take_clipboard_write",
    "zigonaut_core_mouse_tracking",
    "zigonaut_core_mouse",
    "zigonaut_core_destroy",
    "zigonaut_pseudographics_covers",
    "zigonaut_pseudographics_render",
    "zigonaut_selection_path",
    "zigonaut_selection_row_path",
};

test "public header compiles and dylib exports its contract" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(abi.zigonaut_pane_node));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(abi.zigonaut_pane_frame));
    try std.testing.expect(@sizeOf(abi.zigonaut_render_frame_v1) > 0);
    try std.testing.expect(@sizeOf(abi.zigonaut_pseudographics_result_v1) > 0);
    var library = try std.DynLib.open("zig-out/lib/libzigonaut-core.dylib");
    defer library.close();
    inline for (symbols) |symbol| {
        try std.testing.expect(library.lookup(*const anyopaque, symbol) != null);
    }
}

test "hint C ABI preserves interaction state and suffix offsets" {
    try std.testing.expectEqual(@as(usize, 9), @sizeOf(abi.zigonaut_hint_label_v1));
    try std.testing.expectEqual(@as(usize, 9), @sizeOf(abi.zigonaut_hint_interaction_v1));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(abi.zigonaut_hint_suffix_v1));
    var library = try std.DynLib.open("zig-out/lib/libzigonaut-core.dylib");
    defer library.close();
    const key = library.lookup(*const fn ([*c]abi.zigonaut_hint_interaction_v1, [*c]const abi.zigonaut_hint_label_v1, u32, u8) callconv(.c) i32, "zigonaut_hint_key").?;
    const suffix = library.lookup(*const fn ([*c]const abi.zigonaut_hint_interaction_v1, [*c]const abi.zigonaut_hint_label_v1, [*c]abi.zigonaut_hint_suffix_v1) callconv(.c) bool, "zigonaut_hint_suffix").?;
    const labels = [_]abi.zigonaut_hint_label_v1{
        .{ .bytes = .{ 's', 'd', 0, 0, 0, 0, 0, 0 }, .length = 2 },
        .{ .bytes = .{ 'a', 0, 0, 0, 0, 0, 0, 0 }, .length = 1 },
    };
    var state = std.mem.zeroes(abi.zigonaut_hint_interaction_v1);
    var visible: abi.zigonaut_hint_suffix_v1 = undefined;
    try std.testing.expectEqual(@as(i32, -2), key(&state, &labels, labels.len, 's'));
    try std.testing.expect(suffix(&state, &labels[0], &visible));
    try std.testing.expectEqual(@as(u8, 1), visible.offset);
    try std.testing.expectEqual(@as(u8, 1), visible.length);
    try std.testing.expect(!suffix(&state, &labels[1], &visible));
    try std.testing.expectEqual(@as(i32, 0), key(&state, &labels, labels.len, 'd'));
    try std.testing.expectEqual(@as(i32, -3), key(&state, &labels, labels.len, 27));
}
