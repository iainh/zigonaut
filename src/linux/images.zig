const std = @import("std");
const shared_image = @import("shared").image;
pub const c = @import("linux-images");

const image_limit = 32 * 1024 * 1024;

fn decodePng(_: ?*anyopaque, allocator: [*c]const c.GhosttyAllocator, data: [*c]const u8, length: usize, out: [*c]c.GhosttySysImage) callconv(.c) bool {
    if (data == null or out == null or length == 0 or length > image_limit) return false;
    var png = std.mem.zeroes(c.png_image);
    png.version = c.PNG_IMAGE_VERSION;
    defer c.png_image_free(&png);
    if (c.png_image_begin_read_from_memory(&png, data, length) == 0) return false;
    // Validate before multiplying or allocating, including on 32-bit targets.
    if (png.width == 0 or png.height == 0 or png.width > image_limit / 4 / png.height) return false;
    png.format = c.PNG_FORMAT_RGBA;
    const bytes = @as(usize, png.width) * png.height * 4;
    const pixels = c.ghostty_alloc(allocator, bytes);
    if (pixels == null) return false;
    if (c.png_image_finish_read(&png, null, pixels, 0, null) == 0) {
        c.ghostty_free(allocator, pixels, bytes);
        return false;
    }
    out.* = .{ .width = png.width, .height = png.height, .data = pixels, .data_len = bytes };
    return true;
}

var installed = false;

export fn zgtk_install_png_decoder() bool {
    // The host creates terminals on the GTK thread, before feeding PTYs.
    if (!installed) installed = c.ghostty_sys_set(c.GHOSTTY_SYS_OPT_DECODE_PNG, @ptrCast(&decodePng)) == c.GHOSTTY_SUCCESS;
    return installed;
}

fn removeSurface(cache: *c.ImageCache, index: usize) void {
    cache.bytes -= cache.entries[index].bytes;
    c.cairo_surface_destroy(cache.entries[index].surface);
    cache.count -= 1;
    std.mem.copyForwards(c.ImageSurface, cache.entries[index..cache.count], cache.entries[index + 1 .. cache.count + 1]);
}

export fn zgtk_images_clear(cache: *c.ImageCache) void {
    while (cache.count != 0) removeSurface(cache, cache.count - 1);
}

fn imageSurface(cache: *c.ImageCache, image: *const c.TerminalImage) ?*c.cairo_surface_t {
    for (0..cache.count) |i| {
        const entry = cache.entries[i];
        if (entry.image_id != image.image_id) continue;
        if (entry.generation == image.generation and entry.width == image.width and entry.height == image.height) {
            std.mem.copyBackwards(c.ImageSurface, cache.entries[1 .. i + 1], cache.entries[0..i]);
            cache.entries[0] = entry;
            return entry.surface;
        }
        removeSurface(cache, i);
        break;
    }
    const stride = c.cairo_format_stride_for_width(c.CAIRO_FORMAT_ARGB32, @intCast(image.width));
    if (stride < 0 or @as(usize, @intCast(stride)) > image_limit / image.height) return null;
    const bytes = @as(usize, @intCast(stride)) * image.height;
    while (cache.count != 0 and (cache.count == 8 or cache.bytes > image_limit - bytes))
        removeSurface(cache, cache.count - 1);
    const surface = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, @intCast(image.width), @intCast(image.height));
    if (c.cairo_surface_status(surface) != c.CAIRO_STATUS_SUCCESS) {
        c.cairo_surface_destroy(surface);
        return null;
    }
    const destination = c.cairo_image_surface_get_data(surface);
    shared_image.premultiply(image.pixels, destination, image.width, image.height, @intCast(stride), .native_argb);
    c.cairo_surface_mark_dirty(surface);
    std.mem.copyBackwards(c.ImageSurface, cache.entries[1 .. cache.count + 1], cache.entries[0..cache.count]);
    cache.entries[0] = .{ .surface = surface, .generation = image.generation, .image_id = image.image_id, .width = image.width, .height = image.height, .bytes = bytes };
    cache.count += 1;
    cache.bytes += bytes;
    return surface;
}

export fn zgtk_images_draw(cache: *c.ImageCache, cr: *c.cairo_t, image: *const c.TerminalImage, padding: c_int, columns: c_int, rows: c_int, cell_width: c_int, cell_height: c_int) void {
    if (image.pixels == null or image.width == 0 or image.height == 0 or
        image.width > image_limit / 4 / image.height or
        image.length != @as(usize, image.width) * image.height * 4 or
        image.width > std.math.maxInt(c_int) or image.height > std.math.maxInt(c_int) or
        image.source_x > image.width or image.source_width > image.width - image.source_x or
        image.source_y > image.height or image.source_height > image.height - image.source_y) return;
    const left = @as(f64, @floatFromInt(padding)) + @as(f64, @floatFromInt(image.viewport_col)) * @as(f64, @floatFromInt(cell_width)) + @as(f64, @floatFromInt(image.x_offset));
    const top = @as(f64, @floatFromInt(padding)) + @as(f64, @floatFromInt(image.viewport_row)) * @as(f64, @floatFromInt(cell_height)) + @as(f64, @floatFromInt(image.y_offset));
    var quad: shared_image.Quad(f64) = undefined;
    if (shared_image.clippedQuad(f64, .{ .x = left, .y = top, .width = @floatFromInt(image.pixel_width), .height = @floatFromInt(image.pixel_height) }, .{ .x = @floatFromInt(image.source_x), .y = @floatFromInt(image.source_y), .width = @floatFromInt(image.source_width), .height = @floatFromInt(image.source_height) }, .{
        .left = @floatFromInt(padding),
        .top = @floatFromInt(padding),
        .right = @as(f64, @floatFromInt(padding)) + @as(f64, @floatFromInt(columns)) * @as(f64, @floatFromInt(cell_width)),
        .bottom = @as(f64, @floatFromInt(padding)) + @as(f64, @floatFromInt(rows)) * @as(f64, @floatFromInt(cell_height)),
    }, &quad) != .visible) return;
    const surface = imageSurface(cache, image) orelse return;
    c.cairo_save(cr);
    c.cairo_rectangle(cr, quad.destination.x, quad.destination.y, quad.destination.width, quad.destination.height);
    c.cairo_clip(cr);
    c.cairo_translate(cr, left, top);
    c.cairo_scale(cr, @as(f64, @floatFromInt(image.pixel_width)) / @as(f64, @floatFromInt(image.source_width)), @as(f64, @floatFromInt(image.pixel_height)) / @as(f64, @floatFromInt(image.source_height)));
    // A subsurface clamps filtering to the source crop, not its neighbours.
    const crop = c.cairo_surface_create_for_rectangle(surface, @floatFromInt(image.source_x), @floatFromInt(image.source_y), @floatFromInt(image.source_width), @floatFromInt(image.source_height));
    c.cairo_set_source_surface(cr, crop, 0, 0);
    c.cairo_pattern_set_extend(c.cairo_get_source(cr), c.CAIRO_EXTEND_PAD);
    c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_BILINEAR);
    c.cairo_paint(cr);
    c.cairo_restore(cr);
    c.cairo_surface_destroy(crop);
}
