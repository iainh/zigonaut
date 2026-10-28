const std = @import("std");
const c = @import("linux-images");
comptime {
    _ = @import("core.zig");
}

const Capture = struct {
    output: std.Io.Writer.Allocating = .init(std.testing.allocator),
    clipboard: std.Io.Writer.Allocating = .init(std.testing.allocator),
    title: std.Io.Writer.Allocating = .init(std.testing.allocator),
    first_row: [80]u8 = @splat(' '),
    grid: [64][80]u8 = @splat(@splat(' ')),
    wide_columns: u8 = 0,
    red_cell: bool = false,
    highlighted: usize = 0,
    active_highlighted: usize = 0,
    underlined: usize = 0,
    background: u32 = 0,
    images: usize = 0,
    last_image: c.TerminalImage = std.mem.zeroes(c.TerminalImage),
    image_pixels: [24]u8 = @splat(0),
    cache: c.ImageCache = std.mem.zeroes(c.ImageCache),
    cr: ?*c.cairo_t = null,
    drawn_cells: usize = 0,
    background_spans: usize = 0,
    background_columns: usize = 0,
    scroll_offset: f32 = 0,

    fn deinit(self: *Capture) void {
        c.zgtk_images_clear(&self.cache);
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
export fn zgtk_begin_frame(host: ?*anyopaque, background: u32, scroll_offset: f32, _: bool) void {
    capture(host).background = background;
    capture(host).drawn_cells = 0;
    capture(host).background_spans = 0;
    capture(host).background_columns = 0;
    capture(host).scroll_offset = scroll_offset;
    capture(host).first_row = @splat(' ');
    capture(host).highlighted = 0;
    capture(host).active_highlighted = 0;
    capture(host).images = 0;
    capture(host).underlined = 0;
}
export fn zgtk_draw_background(host: ?*anyopaque, _: u16, _: u16, columns: u16, _: u32) void {
    capture(host).background_spans += 1;
    capture(host).background_columns += columns;
}
export fn zgtk_shift_scene(host: ?*anyopaque, delta: i32, columns: u16, rows: u32) bool {
    const state = capture(host);
    if (columns > 80 or rows > 64) return false;
    for (0..rows) |index| {
        const row = if (delta > 0) rows - index - 1 else index;
        const source = @as(i64, @intCast(row)) - delta;
        if (source >= 0 and source < rows)
            @memcpy(state.grid[row][0..columns], state.grid[@intCast(source)][0..columns]);
    }
    return true;
}
export fn zgtk_draw_cell(host: ?*anyopaque, x: u16, y: u16, columns: u8, text: [*]const u8, length: usize, foreground: u32, _: u32, _: u32, flags: u16) void {
    const state = capture(host);
    state.drawn_cells += 1;
    if (y < 64 and x < 80) state.grid[y][x] = if (length == 1) text[0] else ' ';
    if (y == 0 and x < 80 and length == 1) state.first_row[x] = text[0];
    if (length == 3 and std.mem.eql(u8, text[0..length], "界")) state.wide_columns = columns;
    if (length == 1 and text[0] == 'R' and foreground == 0xff0000) state.red_cell = true;
    if (flags & 128 != 0) state.highlighted += columns;
    if (flags & 256 != 0) state.active_highlighted += columns;
    if (flags & 4 != 0) state.underlined += columns;
}
export fn zgtk_draw_image(host: ?*anyopaque, image: *const c.TerminalImage) void {
    const state = capture(host);
    state.images += 1;
    state.last_image = image.*;
    const length = @min(image.length, state.image_pixels.len);
    @memcpy(state.image_pixels[0..length], image.pixels[0..length]);
    if (state.cr) |cr| c.zgtk_images_draw(&state.cache, cr, image, 2, 8, 4, 10, 20);
}
export fn zgtk_draw_cursor(_: ?*anyopaque, _: u16, _: u16, _: u8, _: u8, _: u32) void {}

fn feed(core: *c.TerminalCore, bytes: []const u8) !void {
    c.zgtk_feed(core, bytes.ptr, bytes.len);
}

test "Linux mouse ABI consumes tracking modes and uses padded current pixel geometry" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_resize(core, 30, 8, 10, 20));
    try std.testing.expect(!c.zgtk_mouse(core, 0, 1, 42, 69, 320, 180, 10, 20, 7, 0, true));
    try feed(core, "\x1b[?1000h\x1b[?1006h");
    try std.testing.expect(c.zgtk_mouse(core, 0, 1, 42, 69, 320, 180, 10, 20, 7, 6, true));
    try std.testing.expect(c.zgtk_mouse(core, 2, 1, 52, 89, 320, 180, 10, 20, 7, 0, true));
    try std.testing.expect(c.zgtk_mouse(core, 1, 1, 52, 89, 320, 180, 10, 20, 7, 0, false));
    try feed(core, "\x1b[?1002h");
    try std.testing.expect(c.zgtk_mouse(core, 2, 3, 62, 109, 320, 180, 10, 20, 7, 0, true));
    try std.testing.expect(c.zgtk_mouse(core, 2, 0, 72, 129, 320, 180, 10, 20, 7, 0, false));
    try feed(core, "\x1b[?1003h");
    try std.testing.expect(c.zgtk_mouse(core, 2, 0, 82, 149, 320, 180, 10, 20, 7, 0, false));
    for (4..8) |button| try std.testing.expect(c.zgtk_mouse(core, 0, @intCast(button), 42, 69, 320, 180, 10, 20, 7, 0, false));
    try std.testing.expectEqualStrings("\x1b[<24;4;4M\x1b[<0;5;5m\x1b[<34;6;6M\x1b[<35;8;8M\x1b[<64;4;4M\x1b[<65;4;4M\x1b[<66;4;4M\x1b[<67;4;4M", state.output.written());
    state.output.clearRetainingCapacity();
    try feed(core, "\x1b[?1016h");
    try std.testing.expect(c.zgtk_mouse(core, 0, 2, 42, 69, 320, 180, 10, 20, 7, 0, true));
    try std.testing.expectEqualStrings("\x1b[<1;35;62M", state.output.written());
}

test "Linux links share OSC8 precedence and scheme policy and invalidate hover on mutation" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try feed(core, "\x1b]8;;https://target.invalid/\x07https://label.invalid\x1b]8;;\x07\r\n(https://plain.invalid/a),\r\n\x1b]8;;javascript:alert(1)\x07https://forbidden.invalid\x1b]8;;\x07");
    var length: usize = 0;
    var uri = c.zgtk_link_at(core, 2, 0, &length);
    try std.testing.expectEqualStrings("https://target.invalid/", uri[0..length]);
    try std.testing.expect(c.zgtk_render_retained(core, true));
    try std.testing.expectEqual(@as(usize, 21), state.underlined);
    // Repeated pointer motion inside the same cell retains scene pixels.
    uri = c.zgtk_link_at(core, 2, 0, &length);
    try std.testing.expectEqualStrings("https://target.invalid/", uri[0..length]);
    try std.testing.expectEqual(@as(u8, 0), uri[length]);
    try std.testing.expect(c.zgtk_render_retained(core, false));
    try std.testing.expectEqual(@as(usize, 0), state.drawn_cells);
    try feed(core, " ");
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(usize, 0), state.underlined);
    uri = c.zgtk_link_at(core, 4, 1, &length);
    try std.testing.expectEqualStrings("https://plain.invalid/a", uri[0..length]);
    try std.testing.expect(c.zgtk_link_at(core, 4, 2, &length) == null);
    try std.testing.expectEqual(@as(usize, 0), length);
    try std.testing.expect(c.zgtk_render_retained(core, false));
    try std.testing.expect(c.zgtk_link_at(core, 4, 2, &length) == null);
    try std.testing.expect(c.zgtk_render_retained(core, false));
    try std.testing.expectEqual(@as(usize, 0), state.drawn_cells);
    try std.testing.expect(c.zgtk_link_at(core, 80, 0, &length) == null);
    _ = c.zgtk_link_at(core, 2, 0, &length);
    c.zgtk_scroll(core, -1);
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(usize, 0), state.underlined);
    _ = c.zgtk_link_at(core, 2, 0, &length);
    try std.testing.expect(c.zgtk_resize(core, 60, 12, 11, 22));
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(usize, 0), state.underlined);
    try std.testing.expectEqualStrings("", state.output.written());
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
    // One ordinary span per row, including the extra fractional-scroll row;
    // wide tails must not split or overlap the head's background.
    try std.testing.expectEqual(@as(usize, 8), state.background_spans);
    try std.testing.expectEqual(@as(usize, 31 * 8), state.background_columns);
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

fn pixel(surface: *c.cairo_surface_t, x: usize, y: usize) u32 {
    c.cairo_surface_flush(surface);
    const data = c.cairo_image_surface_get_data(surface);
    const stride: usize = @intCast(c.cairo_image_surface_get_stride(surface));
    return @as(*align(1) const u32, @ptrCast(data + y * stride + x * 4)).*;
}

test "Linux Kitty PNG and RGBA render cropped alpha pixels and replace cached generations" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_resize(core, 8, 4, 10, 20));
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 90, 90).?;
    defer c.cairo_surface_destroy(surface);
    state.cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(state.cr);
    // Distinct RGB channels, opaque/half/quarter/zero alpha, and asymmetric rows.
    // Crop the bottom middle texel (200,100,30,64); neighbours must not bleed.
    try feed(core, "\x1b_Ga=T,f=100,i=7,c=2,r=1,x=1,y=1,w=1,h=1,C=1;" ++
        "iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAI0lEQVR4nGP4oBHQwHUi6r+b3B0GBhGbS/9PpMg5MDIx/wcAiqAKBBHBF4IAAAAASUVORK5CYII=\x1b\\");
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(usize, 1), state.images);
    try std.testing.expectEqualSlices(u8, &.{ 240, 40, 80, 128, 10, 200, 90, 255, 70, 30, 220, 0, 20, 60, 210, 255, 200, 100, 30, 64, 1, 2, 3, 255 }, &state.image_pixels);
    try std.testing.expectEqual(@as(u32, 1), state.last_image.source_x);
    try std.testing.expectEqual(@as(u32, 1), state.last_image.source_y);
    try std.testing.expectEqual(@as(u32, 0x40321908), pixel(surface, 2, 2));
    try std.testing.expectEqual(@as(u32, 0x40321908), pixel(surface, 21, 21));
    try std.testing.expectEqual(@as(u32, 0), pixel(surface, 22, 22));
    const generation = state.last_image.generation;
    // Same ID and dimensions, different pixels: stale cache keys fail here.
    try feed(core, "\x1b_Ga=T,f=32,s=3,v=2,i=7,c=2,r=1,x=1,y=1,w=1,h=1,C=1;" ++
        "8ChQgArIWv9GHtwAFDzS/8hkHv8BAgP/\x1b\\");
    c.cairo_set_operator(state.cr, c.CAIRO_OPERATOR_CLEAR);
    c.cairo_paint(state.cr);
    c.cairo_set_operator(state.cr, c.CAIRO_OPERATOR_OVER);
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expect(state.last_image.generation != generation);
    try std.testing.expectEqual(@as(u32, 0xffc8641e), pixel(surface, 2, 2));
    // Repeat frame, then delete: retained surfaces must never retain placements.
    try std.testing.expect(c.zgtk_render(core));
    try feed(core, "\x1b_Ga=d,d=I,i=7\x1b\\");
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(usize, 0), state.images);
    try feed(core, "\x1b_Ga=T,f=100,i=8;bm90IGEgcG5n\x1b\\");
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(usize, 0), state.images);
    // Valid PNG header, truncated pixel stream: also exercise decode cleanup
    // after the Ghostty-owned output allocation, not just header rejection.
    try feed(core, "\x1b_Ga=T,f=100,i=8;iVBORw0KGgoAAAANSUhEUgAAAAMAAAACCAYAAACddGYaAAAAI0lEQVR4nGP4oBHQ\x1b\\");
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqual(@as(usize, 0), state.images);
}

test "Linux image compositor clips negative viewport rows and padding at nondefault metrics" {
    var cache = std.mem.zeroes(c.ImageCache);
    defer c.zgtk_images_clear(&cache);
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 60, 70).?;
    defer c.cairo_surface_destroy(surface);
    const cr = c.cairo_create(surface).?;
    defer c.cairo_destroy(cr);
    const rgba = [_]u8{ 12, 90, 210, 255 };
    const image: c.TerminalImage = .{
        .image_id = 9,
        .generation = 1,
        .pixels = &rgba,
        .length = 4,
        .width = 1,
        .height = 1,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .pixel_width = 90,
        .pixel_height = 100,
        .viewport_col = -1,
        .viewport_row = -1,
        .x_offset = 3,
        .y_offset = 5,
    };
    c.zgtk_images_draw(&cache, cr, &image, 4, 3, 2, 13, 27);
    try std.testing.expectEqual(@as(u32, 0xff0c5ad2), pixel(surface, 4, 4));
    try std.testing.expectEqual(@as(u32, 0xff0c5ad2), pixel(surface, 42, 57));
    for ([_][2]usize{ .{ 3, 4 }, .{ 4, 3 }, .{ 43, 30 }, .{ 20, 58 } }) |point|
        try std.testing.expectEqual(@as(u32, 0), pixel(surface, point[0], point[1]));
    // Offscreen generations do not populate or replace native surfaces.
    c.zgtk_images_clear(&cache);
    var invisible = image;
    invisible.viewport_row = 3;
    c.zgtk_images_draw(&cache, cr, &invisible, 4, 3, 2, 13, 27);
    try std.testing.expectEqual(@as(usize, 0), cache.count);
    c.zgtk_images_draw(&cache, cr, &image, 4, 3, 2, 13, 27);
    invisible.generation = 2;
    c.zgtk_images_draw(&cache, cr, &invisible, 4, 3, 2, 13, 27);
    try std.testing.expectEqual(@as(usize, 1), cache.count);
    try std.testing.expectEqual(@as(u64, 1), cache.entries[0].generation);
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
    const boundary: [256]u8 = @splat('x');
    _ = try search(core, &boundary);
    const oversized: [257]u8 = @splat('x');
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

test "retained GTK fractional scroll presents without redrawing unchanged cells" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_resize(core, 12, 3, 8, 16));
    try feed(core, "one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\nseven");
    try std.testing.expect(c.zgtk_scroll_fractional(core, -1.5));
    try std.testing.expect(c.zgtk_render_retained(core, true));
    try std.testing.expectEqual(@as(usize, 48), state.drawn_cells);
    try std.testing.expectEqual(@as(usize, 4), state.background_spans);
    try std.testing.expectEqual(@as(f32, 0.5), state.scroll_offset);
    try std.testing.expect(c.zgtk_scroll_fractional(core, 0.125));
    try std.testing.expect(c.zgtk_render_retained(core, false));
    try std.testing.expectEqual(@as(usize, 0), state.drawn_cells);
    try std.testing.expectEqual(@as(usize, 0), state.background_spans);
    try std.testing.expectEqual(@as(f32, 0.625), state.scroll_offset);
    try std.testing.expect(c.zgtk_scroll_fractional(core, 0.5));
    try std.testing.expect(c.zgtk_render_retained(core, false));
    try std.testing.expectEqual(@as(f32, 0.125), state.scroll_offset);
    try std.testing.expect(state.drawn_cells > 0);
    try std.testing.expect(state.drawn_cells < 48);
    var shifted = state.grid;
    try std.testing.expect(c.zgtk_render_retained(core, true));
    try std.testing.expectEqualDeep(shifted, state.grid);
    // Reverse the shift as well; stale rows can look correct in one direction.
    c.zgtk_scroll(core, -1);
    try std.testing.expect(c.zgtk_render_retained(core, false));
    shifted = state.grid;
    try std.testing.expect(c.zgtk_render_retained(core, true));
    try std.testing.expectEqualDeep(shifted, state.grid);
    c.zgtk_scroll(core, 100);
    try std.testing.expect(c.zgtk_render_retained(core, false));
    try std.testing.expectEqual(@as(f32, 0), state.scroll_offset);
    // Fractional local scrolling must not manufacture application wheel input.
    try std.testing.expectEqual(@as(usize, 0), state.output.written().len);
}
