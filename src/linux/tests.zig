const std = @import("std");
const c = @cImport(@cInclude("core.h"));
comptime {
    _ = @import("core.zig");
}

const Capture = struct {
    output: std.Io.Writer.Allocating = .init(std.testing.allocator),
    clipboard: std.Io.Writer.Allocating = .init(std.testing.allocator),
    title: std.Io.Writer.Allocating = .init(std.testing.allocator),
    first_row: [80]u8 = @splat(' '),
    wide_columns: u8 = 0,
    red_cell: bool = false,
    highlighted: usize = 0,
    active_highlighted: usize = 0,
    background: u32 = 0,

    fn deinit(self: *Capture) void {
        self.output.deinit();
        self.clipboard.deinit();
        self.title.deinit();
    }
};

fn capture(host: ?*anyopaque) *Capture {
    return @ptrCast(@alignCast(host.?));
}

export fn zgtk_write(host: ?*anyopaque, bytes: [*]const u8, length: usize) void {
    capture(host).output.writer.writeAll(bytes[0..length]) catch unreachable;
}
export fn zgtk_title(host: ?*anyopaque, bytes: [*]const u8, length: usize) void {
    capture(host).title.writer.writeAll(bytes[0..length]) catch unreachable;
}
export fn zgtk_clipboard(host: ?*anyopaque, bytes: [*]const u8, length: usize) void {
    capture(host).clipboard.writer.writeAll(bytes[0..length]) catch unreachable;
}
export fn zgtk_begin_frame(host: ?*anyopaque, background: u32) void {
    capture(host).background = background;
    capture(host).first_row = @splat(' ');
    capture(host).highlighted = 0;
    capture(host).active_highlighted = 0;
}
export fn zgtk_draw_cell(host: ?*anyopaque, x: u16, y: u16, columns: u8, text: [*]const u8, length: usize, foreground: u32, _: u32, _: u32, flags: u16) void {
    const state = capture(host);
    if (y == 0 and x < 80 and length == 1) state.first_row[x] = text[0];
    if (length == 3 and std.mem.eql(u8, text[0..length], "界")) state.wide_columns = columns;
    if (length == 1 and text[0] == 'R' and foreground == 0xff0000) state.red_cell = true;
    if (flags & 128 != 0) state.highlighted += columns;
    if (flags & 256 != 0) state.active_highlighted += columns;
}
export fn zgtk_draw_cursor(_: ?*anyopaque, _: u16, _: u16, _: u8, _: u8, _: u32) void {}

fn feed(core: *c.TerminalCore, bytes: []const u8) !void {
    c.zgtk_feed(core, bytes.ptr, bytes.len);
}

test "Linux input respects terminal modes, modifiers, UTF-8 and paste framing" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_key(core, "c", 2, 0, "c", 1, false));
    try std.testing.expect(c.zgtk_key(core, "Up", 0, 0, "", 0, false));
    try feed(core, "\x1b[?1h");
    try std.testing.expect(c.zgtk_key(core, "Up", 0, 0, "", 0, false));
    try std.testing.expect(c.zgtk_key(core, "plus", 1, 1, "+", 1, false));
    try std.testing.expect(c.zgtk_key(core, "EuroSign", 6, 6, "€", 3, false));
    try std.testing.expect(c.zgtk_key(core, "a", 0, 0, "", 0, true));
    try std.testing.expect(c.zgtk_paste(core, "one\ntwo", 7));
    try feed(core, "\x1b[?2004h");
    try std.testing.expect(c.zgtk_paste(core, "three\nfour", 10));
    try std.testing.expectEqualStrings("\x03\x1b[A\x1bOA+€one\rtwo\x1b[200~three\nfour\x1b[201~", state.output.written());
}

test "Linux rendering, selection and titles preserve terminal data across resize" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_resize(core, 31, 7, 10, 19));
    try feed(core, "Alpha \x1b[38;2;255;0;0mR\x1b[0m 界\r\nBeta\x1b]2;Linux shell\x07");
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expect(state.red_cell);
    try std.testing.expectEqual(@as(u8, 2), state.wide_columns);
    try std.testing.expectEqualStrings("Alpha R ", state.first_row[0..8]);
    try std.testing.expectEqualStrings("Linux shell", state.title.written());
    try std.testing.expect(c.zgtk_select(core, 4, 0, true, false));
    try std.testing.expect(c.zgtk_select(core, 1, 0, false, false));
    c.zgtk_copy(core);
    try std.testing.expectEqualStrings("lpha", state.clipboard.written());
    try std.testing.expect(c.zgtk_resize(core, 47, 12, 10, 19));
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqualStrings("Alpha R ", state.first_row[0..8]);
}

fn search(core: *c.TerminalCore, query: []const u8) !c.SearchStatus {
    try std.testing.expect(c.zgtk_search_set(core, query.ptr, query.len));
    for (0..1000) |_| {
        const status = c.zgtk_search_tick(core);
        try std.testing.expect(!status.failed);
        if (!status.scanning) return status;
    }
    return error.SearchDidNotFinish;
}

test "Linux search uses smart case, highlights UTF-8 cells, and restores the viewport" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_resize(core, 12, 3, 10, 19));
    try feed(core, "Alpha alpha\r\n界 café\r\nALPHA\r\nlast\r\nmore\r\nend");
    try std.testing.expect(c.zgtk_render(core));
    const original_row = state.first_row;
    try std.testing.expectEqual(@as(u32, 3), (try search(core, "alpha")).matches);
    try std.testing.expectEqual(@as(i32, 0), c.zgtk_search_navigate(core, true).active);
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqualStrings("Alpha alpha", state.first_row[0..11]);
    try std.testing.expectEqual(@as(usize, 5), state.active_highlighted);
    try std.testing.expectEqual(@as(usize, 10), state.highlighted);
    try std.testing.expectEqual(@as(i32, 2), c.zgtk_search_navigate(core, false).active);
    try std.testing.expectEqual(@as(i32, 0), c.zgtk_search_navigate(core, true).active);
    try std.testing.expectEqual(@as(u32, 1), (try search(core, "Alpha")).matches);
    try std.testing.expectEqual(@as(u32, 1), (try search(core, "界 café")).matches);
    _ = c.zgtk_search_navigate(core, true);
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(usize, 7), state.active_highlighted);
    c.zgtk_search_clear(core);
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqualStrings(&original_row, &state.first_row);
    try std.testing.expectEqual(@as(usize, 0), state.active_highlighted + state.highlighted);

    try std.testing.expectEqual(@as(u32, 0), (try search(core, "absent")).matches);
    const boundary = [_]u8{'x'} ** 256;
    _ = try search(core, &boundary);
    const oversized = [_]u8{'x'} ** 257;
    try std.testing.expect(!c.zgtk_search_set(core, &oversized, oversized.len));
    try std.testing.expect(c.zgtk_search_tick(core).failed);
    try std.testing.expect(!c.zgtk_search_set(core, "\xff", 1));
    try std.testing.expectEqual(@as(u32, 0), (try search(core, "")).matches);
}

test "Linux live search is incremental and invalidates results on output and resize" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_resize(core, 20, 3, 10, 19));
    for (0..90) |_| try feed(core, "needle\r\n");
    try std.testing.expect(c.zgtk_search_set(core, "needle", 6));
    const partial = c.zgtk_search_tick(core);
    try std.testing.expect(partial.scanning and partial.matches > 0 and partial.matches < 90);
    try feed(core, "needle");
    var status = c.zgtk_search_tick(core);
    while (status.scanning) status = c.zgtk_search_tick(core);
    try std.testing.expectEqual(@as(u32, 91), status.matches);
    try std.testing.expect(c.zgtk_resize(core, 11, 4, 10, 19));
    status = c.zgtk_search_tick(core);
    while (status.scanning) status = c.zgtk_search_tick(core);
    try std.testing.expectEqual(@as(u32, 91), status.matches);
    // Replacing text must invalidate cached matches, not append duplicates.
    try feed(core, "\r\x1b[2Kgone");
    status = c.zgtk_search_tick(core);
    while (status.scanning) status = c.zgtk_search_tick(core);
    try std.testing.expectEqual(@as(u32, 90), status.matches);
}

test "Linux prompt navigation follows OSC 133 boundaries without typing into the shell" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_resize(core, 12, 2, 10, 19));
    try feed(core, "\x1b]133;A\x07PS> \x1b]133;B\x07one\x1b]133;C\x07\r\nfirst\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> \x1b]133;B\x07two\x1b]133;C\x07\r\nsecond\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> ");
    try std.testing.expect(c.zgtk_navigate_prompt(core, false));
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqualStrings("PS> two", state.first_row[0..7]);
    try std.testing.expect(c.zgtk_navigate_prompt(core, false));
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqualStrings("PS> one", state.first_row[0..7]);
    try std.testing.expect(!c.zgtk_navigate_prompt(core, false));
    try std.testing.expect(c.zgtk_navigate_prompt(core, true));
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqualStrings("PS> two", state.first_row[0..7]);
    try std.testing.expectEqualStrings("", state.output.written());
}

test "Linux pane ABI preserves nested layout, focus, ratios and zoom across collapse" {
    const layout = c.zgtk_layout_create() orelse return error.InitFailed;
    defer c.zgtk_layout_destroy(layout);
    var nodes: [127]c.PaneNode = undefined;
    const right = c.zgtk_layout_split(layout, false);
    const bottom = c.zgtk_layout_split(layout, true);
    try std.testing.expect(right != 0 and bottom != 0 and right != bottom);
    try std.testing.expectEqual(@as(usize, 5), c.zgtk_layout_nodes(layout, &nodes, nodes.len));
    try std.testing.expect(nodes[0].split and !nodes[0].vertical and nodes[0].subtree_size == 5);
    const outer = nodes[0].id;
    const inner = nodes[2].id;
    try std.testing.expect(nodes[2].split and nodes[2].vertical and nodes[2].subtree_size == 3);
    try std.testing.expectEqual(bottom, c.zgtk_layout_focused(layout));
    try std.testing.expect(c.zgtk_layout_action(layout, c.PANE_UP));
    try std.testing.expectEqual(right, c.zgtk_layout_focused(layout));
    try std.testing.expect(c.zgtk_layout_action(layout, c.PANE_LEFT));
    try std.testing.expectEqual(@as(u64, 1), c.zgtk_layout_focused(layout));
    try std.testing.expect(c.zgtk_layout_action(layout, c.PANE_PREVIOUS));
    try std.testing.expectEqual(bottom, c.zgtk_layout_focused(layout));
    try std.testing.expect(c.zgtk_layout_ratio(layout, outer, 22000));
    try std.testing.expect(c.zgtk_layout_ratio(layout, inner, 41000));
    try std.testing.expect(c.zgtk_layout_action(layout, c.PANE_RESIZE_UP));
    _ = c.zgtk_layout_nodes(layout, &nodes, nodes.len);
    try std.testing.expectEqual(@as(u16, 22000), nodes[0].ratio);
    try std.testing.expectEqual(@as(u16, 37723), nodes[2].ratio);
    try std.testing.expect(c.zgtk_layout_action(layout, c.PANE_ZOOM));
    try std.testing.expectEqual(@as(usize, 1), c.zgtk_layout_nodes(layout, &nodes, nodes.len));
    try std.testing.expectEqual(bottom, nodes[0].id);
    try std.testing.expect(c.zgtk_layout_action(layout, c.PANE_NEXT));
    _ = c.zgtk_layout_nodes(layout, &nodes, nodes.len);
    try std.testing.expectEqual(@as(u64, 1), nodes[0].id);
    try std.testing.expect(c.zgtk_layout_action(layout, c.PANE_ZOOM));
    try std.testing.expectEqual(@as(usize, 5), c.zgtk_layout_nodes(layout, &nodes, nodes.len));
    try std.testing.expectEqual(@as(u16, 37723), nodes[2].ratio);
    try std.testing.expect(c.zgtk_layout_close(layout, right));
    try std.testing.expectEqual(@as(usize, 3), c.zgtk_layout_nodes(layout, &nodes, nodes.len));
    try std.testing.expectEqual(bottom, nodes[2].id);
    try std.testing.expect(c.zgtk_layout_action(layout, c.PANE_EQUALIZE));
    _ = c.zgtk_layout_nodes(layout, &nodes, nodes.len);
    try std.testing.expectEqual(@as(u16, 32767), nodes[0].ratio);
    try std.testing.expect(c.zgtk_layout_close(layout, 1));
    try std.testing.expectEqual(bottom, c.zgtk_layout_focused(layout));
    try std.testing.expect(!c.zgtk_layout_action(layout, c.PANE_ZOOM));
    try std.testing.expect(c.zgtk_layout_close(layout, bottom));
    try std.testing.expectEqual(@as(u64, 0), c.zgtk_layout_focused(layout));
    try std.testing.expectEqual(@as(usize, 0), c.zgtk_layout_nodes(layout, &nodes, nodes.len));
}

test "Linux settings update live themes and enforce opt-in bounded clipboard writes" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try feed(core, "retained\x1b]52;c;b25l\x07");
    try std.testing.expectEqualStrings("", state.clipboard.written());
    try std.testing.expect(c.zgtk_configure(core, 1, 100, 1, true, 3));
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(u32, 0xffffff), state.background);
    try std.testing.expectEqualStrings("retained", state.first_row[0..8]);
    try feed(core, "\x1b]52;c;b25l\x07\x1b]52;c;Zm91cg==\x07");
    try std.testing.expectEqualStrings("one", state.clipboard.written());
    try std.testing.expect(c.zgtk_configure(core, 0, 0, 2, false, 3));
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(u32, 0x1a1a19), state.background);
    try feed(core, "\x1b]52;c;dHdv\x07");
    try std.testing.expectEqualStrings("one", state.clipboard.written());
}

test "Linux command output copy is explicit, pane-local and never reuses an empty command" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try feed(core, "startup banner\r\n");
    try std.testing.expect(!c.zgtk_copy_last_command(core));
    try feed(core, "\x1b]133;A\x07$ \x1b]133;B\x07example\x1b]133;C\x07\r\n\x1b[31mcafé 界\x1b[0m\r\nsecond\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ");
    // Explicit user copies work with OSC clipboard writes disabled by default.
    try std.testing.expect(c.zgtk_copy_last_command(core));
    try std.testing.expectEqualStrings("café 界\nsecond", state.clipboard.written());
    var other = Capture{};
    defer other.deinit();
    const other_core = c.zgtk_create(&other) orelse return error.InitFailed;
    defer c.zgtk_destroy(other_core);
    try feed(other_core, "ordinary output");
    try std.testing.expect(!c.zgtk_copy_last_command(other_core));
    try std.testing.expectEqualStrings("", other.clipboard.written());
    try feed(core, "\x1b]133;B\x07true\x1b]133;C\x07\r\n\x1b]133;D;0\x07\x1b]133;A\x07$ ");
    try std.testing.expect(!c.zgtk_copy_last_command(core));
    try std.testing.expectEqualStrings("café 界\nsecond", state.clipboard.written());
}
