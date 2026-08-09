const std = @import("std");
const win32 = @import("win32.zig");
const native = win32.c;
const vt = @cImport({
    @cDefine("GHOSTTY_STATIC", "1");
    @cInclude("ghostty/vt.h");
});

const kitty_image_limit: usize = 32 * 1024 * 1024;
var decode_png_mutex: win32.Mutex = .{};
var decode_png_installed = false;

pub fn installPngDecoder() !void {
    decode_png_mutex.lock();
    defer decode_png_mutex.unlock();
    if (decode_png_installed) return;
    if (vt.ghostty_sys_set(vt.GHOSTTY_SYS_OPT_DECODE_PNG, @as(vt.GhosttySysDecodePngFn, decodePng)) != vt.GHOSTTY_SUCCESS) {
        return error.LibGhosttyFailure;
    }
    decode_png_installed = true;
}

fn decodePng(_: ?*anyopaque, allocator: [*c]const vt.GhosttyAllocator, data: [*c]const u8, data_len: usize, out: [*c]vt.GhosttySysImage) callconv(.c) bool {
    if (allocator == null or data == null or out == null or data_len == 0 or data_len > kitty_image_limit) return false;
    var decoded: native.ZigonautDecodedImage = undefined;
    if (native.zigonaut_decode_png(data, data_len, &decoded) < 0) return false;
    defer native.zigonaut_free_decoded_image(decoded.pixels);
    if (decoded.pixels == null or decoded.length == 0 or decoded.length > kitty_image_limit) return false;
    const owned = vt.ghostty_alloc(allocator, decoded.length);
    if (owned == null) return false;
    @memcpy(owned[0..decoded.length], decoded.pixels[0..decoded.length]);
    out.* = .{ .width = decoded.width, .height = decoded.height, .data = owned, .data_len = decoded.length };
    return true;
}

pub const CacheBenchmark = struct {
    layout_creations: u64,
    hot_reuse_creations: u64,
    cache_entries: u32,
};

export fn zigonaut_fit_cluster_advances(
    advances: ?[*]f32,
    glyph_count: u32,
    expected_width: f32,
) callconv(.c) void {
    if (advances == null or glyph_count == 0) return;
    const values = advances.?[0..glyph_count];
    var natural_width: f32 = 0;
    for (values) |value| natural_width += value;
    values[values.len - 1] += expected_width - natural_width;
}

pub fn benchmarkLayoutCache(repetitions: u32) !CacheBenchmark {
    var result: native.ZigonautLayoutCacheBenchmark = undefined;
    if (native.zigonaut_benchmark_layout_cache(repetitions, &result) < 0) {
        return error.DirectWriteBenchmarkFailed;
    }
    return .{
        .layout_creations = result.layout_creations,
        .hot_reuse_creations = result.hot_reuse_creations,
        .cache_entries = result.cache_entries,
    };
}

pub fn benchmarkPipeline() !native.ZigonautDirectWriteBenchmark {
    var result: native.ZigonautDirectWriteBenchmark = undefined;
    if (native.zigonaut_benchmark_directwrite_pipeline(&result) < 0) {
        return error.DirectWritePipelineBenchmarkFailed;
    }
    return result;
}

pub const Engine = struct {
    handle: *native.ZigonautTextEngine,

    pub const Metrics = struct {
        width: u32,
        height: u32,
        baseline: u32,
    };

    pub fn init(font_family: []const u8, font_size: u32, font_weight: u16, intense_font_weight: u16, dpi: u32, antialiasing: u32) !Engine {
        if (antialiasing > 1) return error.InvalidTextAntialiasing;
        var wide_name = [_]u16{0} ** 128;
        _ = @import("std").unicode.utf8ToUtf16Le(
            wide_name[0 .. wide_name.len - 1],
            font_family,
        ) catch return error.InvalidFontFamily;
        var handle: ?*native.ZigonautTextEngine = null;
        const result = native.zigonaut_text_engine_create(
            &wide_name,
            font_size,
            font_weight,
            intense_font_weight,
            dpi,
            @intCast(antialiasing),
            &handle,
        );
        if (result < 0 or handle == null) return error.DirectWriteInitializationFailed;
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: *Engine) void {
        native.zigonaut_text_engine_destroy(self.handle);
    }

    pub fn setDpi(self: *Engine, dpi: u32) !void {
        if (native.zigonaut_text_engine_set_dpi(self.handle, dpi) < 0) {
            return error.DirectWriteDpiUpdateFailed;
        }
    }

    pub fn refreshRenderingParams(self: *Engine) !void {
        if (native.zigonaut_text_engine_refresh_rendering_params(self.handle) < 0) {
            return error.DirectWriteRenderingParamsUpdateFailed;
        }
    }

    pub fn metrics(self: *const Engine) Metrics {
        const value = native.zigonaut_text_engine_get_cell_metrics(self.handle);
        return .{
            .width = value.width,
            .height = value.height,
            .baseline = value.baseline,
        };
    }

    pub fn setWindow(self: *Engine, hwnd: ?*anyopaque) !void {
        if (native.zigonaut_text_engine_set_window(
            self.handle,
            @intFromPtr(hwnd),
        ) < 0) {
            return error.DirectWriteWindowFailed;
        }
    }

    pub fn swapChain(self: *const Engine) ?*anyopaque {
        return native.zigonaut_text_engine_get_swap_chain(self.handle);
    }

    pub fn frameLatencyWaitableObject(self: *const Engine) native.HANDLE {
        return native.zigonaut_text_engine_get_frame_latency_waitable_object(self.handle);
    }

    pub fn beginFrame(self: *Engine, width: u32, height: u32, background: u32, full_rebuild: bool) !bool {
        var required: native.BOOL = 0;
        if (native.zigonaut_text_engine_begin_frame(
            self.handle,
            width,
            height,
            background,
            @intFromBool(full_rebuild),
            &required,
        ) < 0) return error.Direct2DBeginFrameFailed;
        return required != 0;
    }

    pub fn shiftScene(self: *Engine, row_delta: i32, left: u32, top: u32, width: u32, row_height: u32, row_count: u32) !void {
        if (native.zigonaut_text_engine_shift_scene(self.handle, row_delta, left, top, width, row_height, row_count) < 0)
            return error.Direct2DSceneShiftFailed;
    }

    pub fn clearRect(self: *Engine, left: f32, top: f32, right: f32, bottom: f32, color: u32) void {
        native.zigonaut_text_engine_clear_rect(self.handle, left, top, right, bottom, color);
    }

    pub fn abortFrame(self: *Engine) void {
        native.zigonaut_text_engine_abort_frame(self.handle);
    }

    pub fn drawCell(
        self: *Engine,
        text: []const u16,
        left: f32,
        top: f32,
        width: f32,
        height: f32,
        foreground: u32,
        background: u32,
        underline_color: u32,
        bold: bool,
        italic: bool,
        faint: bool,
        strikethrough: bool,
        overline: bool,
        underline: u8,
        occupancy: u8,
    ) !void {
        if (native.zigonaut_text_engine_draw_cell(
            self.handle,
            if (text.len == 0) null else text.ptr,
            @intCast(text.len),
            left,
            top,
            width,
            height,
            foreground,
            background,
            underline_color,
            @intFromBool(bold),
            @intFromBool(italic),
            @intFromBool(faint),
            @intFromBool(strikethrough),
            @intFromBool(overline),
            underline,
            @intCast(occupancy),
        ) < 0) return error.Direct2DDrawCellFailed;
    }

    pub fn beginRow(
        self: *Engine,
        row: u16,
        origin_x: f32,
        top: f32,
        cell_width: f32,
        cell_height: f32,
    ) void {
        native.zigonaut_text_engine_begin_row(
            self.handle,
            row,
            origin_x,
            top,
            cell_width,
            cell_height,
        );
    }

    pub fn endRow(self: *Engine) !void {
        if (native.zigonaut_text_engine_end_row(self.handle) < 0) {
            return error.Direct2DEndRowFailed;
        }
    }

    pub fn drawImage(self: *Engine, image: @import("terminal.zig").Terminal.Image, left: f32, top: f32, width: f32, height: f32, clip: [4]f32) !void {
        if (native.zigonaut_text_engine_draw_image(self.handle, image.image_id, image.generation, image.pixels.ptr, image.pixels.len, image.width, image.height, left, top, width, height, @floatFromInt(image.source_x), @floatFromInt(image.source_y), @floatFromInt(image.source_width), @floatFromInt(image.source_height), clip[0], clip[1], clip[2], clip[3]) < 0)
            return error.Direct2DDrawImageFailed;
    }

    pub fn drawCursor(
        self: *Engine,
        left: f32,
        top: f32,
        width: f32,
        height: f32,
        color: u32,
        style: u8,
    ) void {
        native.zigonaut_text_engine_draw_cursor(
            self.handle,
            left,
            top,
            width,
            height,
            color,
            style,
        );
    }

    pub fn drawPreedit(self: *Engine, text: []const u16, caret: u32, left: f32, top: f32, max_width: f32, height: f32, foreground: u32, background: u32) ?f32 {
        if (text.len == 0) return null;
        var caret_x: f32 = left;
        if (native.zigonaut_text_engine_draw_preedit(self.handle, text.ptr, @intCast(text.len), caret, left, top, max_width, height, foreground, background, &caret_x) < 0) return null;
        return caret_x;
    }

    pub const PresentResult = enum { presented, retry };

    pub fn endFrame(self: *Engine) !PresentResult {
        const result = native.zigonaut_text_engine_end_frame(self.handle);
        if (result < 0) {
            return error.Direct2DEndFrameFailed;
        }
        return if (result == 0) .presented else .retry;
    }

    pub fn retryPresent(self: *Engine) !PresentResult {
        const result = native.zigonaut_text_engine_retry_present(self.handle);
        if (result < 0) return error.Direct2DPresentFailed;
        return if (result == 0) .presented else .retry;
    }

    pub fn abandonPendingPresent(self: *Engine) void {
        native.zigonaut_text_engine_abandon_pending_present(self.handle);
    }
};

test "Windows PNG decoder produces owned Kitty image snapshots" {
    const Terminal = @import("terminal.zig").Terminal;
    const theme = @import("theme.zig");
    try installPngDecoder();
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    try terminal.resize(4, 2, 8, 16);
    terminal.feed("\x1b_Gf=100,a=T,i=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    try std.testing.expectEqual(@as(usize, 1), snapshot.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.placements.items.len);
    const owned = snapshot.images.items[0];
    const placement = snapshot.placements.items[0];
    const image = Terminal.Image{
        .image_id = owned.image_id,
        .generation = owned.generation,
        .pixels = owned.pixels,
        .width = owned.width,
        .height = owned.height,
        .source_x = placement.source_x,
        .source_y = placement.source_y,
        .source_width = placement.source_width,
        .source_height = placement.source_height,
        .pixel_width = placement.pixel_width,
        .pixel_height = placement.pixel_height,
        .viewport_col = placement.viewport_col,
        .viewport_row = placement.viewport_row,
        .x_offset = placement.x_offset,
        .y_offset = placement.y_offset,
        .z = placement.z,
    };
    try std.testing.expectEqual(@as(u32, 1), image.image_id);
    try std.testing.expect(image.generation != 0);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels);

    const saved_pixels = try std.testing.allocator.dupe(u8, image.pixels);
    defer std.testing.allocator.free(saved_pixels);
    const saved_generation = image.generation;
    terminal.feed("\x1b_Gf=100,a=T,i=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");
    try snapshot.capture(std.testing.allocator, &terminal);
    try std.testing.expect(snapshot.images.items[0].generation != saved_generation);
    try std.testing.expectEqualSlices(u8, saved_pixels, snapshot.images.items[0].pixels);
    terminal.feed("\x1b_Ga=d,d=I,i=1\x1b\\");
    try std.testing.expectEqualSlices(u8, saved_pixels, snapshot.images.items[0].pixels);
    try snapshot.capture(std.testing.allocator, &terminal);
    try std.testing.expectEqual(@as(usize, 0), snapshot.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.placements.items.len);
}

test "Windows PNG decoder shares image storage between placements" {
    const Terminal = @import("terminal.zig").Terminal;
    const theme = @import("theme.zig");
    try installPngDecoder();
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    try terminal.resize(4, 2, 8, 16);
    terminal.feed("\x1b_Gf=100,a=T,i=7;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");
    terminal.feed("\x1b_Ga=p,i=7,p=2\x1b\\");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    try std.testing.expectEqual(@as(usize, 1), snapshot.images.items.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.placements.items.len);
    try std.testing.expectEqual(snapshot.placements.items[0].image_index, snapshot.placements.items[1].image_index);
}

test "cluster advances fit exact terminal spans" {
    var ligature = [_]f32{ 3.0, 4.0, 2.0 };
    zigonaut_fit_cluster_advances(&ligature, ligature.len, 20.0);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), sum(&ligature), 0.001);

    var combining = [_]f32{ 9.0, 0.0 };
    zigonaut_fit_cluster_advances(&combining, combining.len, 10.0);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), sum(&combining), 0.001);
}

test "fixed glyph atlas allocator is deterministic and transactional" {
    try std.testing.expectEqual(@as(native.HRESULT, 0), native.zigonaut_test_glyph_atlas_allocator());
}

test "glyph atlas draws pixels, skips empty sprites, and survives frame reset" {
    var result: native.ZigonautGlyphAtlasPixelsTest = undefined;
    try std.testing.expectEqual(@as(native.HRESULT, 0), native.zigonaut_test_glyph_atlas_pixels(&result));
    try std.testing.expectEqual(@as(u64, 1), result.first_sprite_batches);
    try std.testing.expect(result.first_sprites >= 8);
    try std.testing.expect(result.first_changed_pixels > 0);
    try std.testing.expect(result.first_red_dominant_pixels > 0);
    try std.testing.expect(result.first_green_dominant_pixels > 0);
    try std.testing.expectEqual(@as(u64, 0), result.empty_sprite_batches);
    try std.testing.expectEqual(@as(u64, 0), result.empty_sprites);
    try std.testing.expectEqual(@as(u64, 0), result.empty_changed_pixels);
    try std.testing.expectEqual(@as(u64, 1), result.second_sprite_batches);
    try std.testing.expectEqual(result.first_sprites, result.second_sprites);
    try std.testing.expectEqual(result.second_sprites, result.second_placement_hits);
    try std.testing.expect(result.second_changed_pixels > 0);
}

test "atlas AA policy, lifecycle, and deterministic fault fallbacks" {
    try std.testing.expectEqual(@as(native.HRESULT, 0), native.zigonaut_test_atlas_policy_and_faults());
}

test "damage-aware transfer stays coherent across rotating buffers" {
    var result: native.ZigonautDamageTransferTest = undefined;
    try std.testing.expectEqual(@as(native.HRESULT, 0), native.zigonaut_test_damage_aware_transfer(&result));
    try std.testing.expectEqual(@as(u32, 10), result.compared_frames);
    try std.testing.expectEqual(@as(u32, 4), result.full_copies);
    try std.testing.expectEqual(@as(u32, 8), result.region_copies);
    try std.testing.expect(result.region_copy_bytes > 0);
}

test "invalid numeric antialias policy is rejected before enum conversion" {
    try std.testing.expectError(error.InvalidTextAntialiasing, Engine.init("Consolas", 18, 400, 700, 96, 2));
    try std.testing.expectError(error.InvalidTextAntialiasing, Engine.init("Consolas", 18, 400, 700, 96, std.math.maxInt(u32)));
}

test "layout cache retains hot entries when crossing capacity" {
    const result = try benchmarkLayoutCache(1);
    try std.testing.expectEqual(@as(u64, 2348), result.layout_creations);
    try std.testing.expectEqual(@as(u64, 0), result.hot_reuse_creations);
    try std.testing.expectEqual(@as(u32, 2048), result.cache_entries);
}

test "resolved draw plan is reused by the warm-row benchmark" {
    const result = try benchmarkPipeline();
    try std.testing.expect(result.resolved_plan_hits >= result.warm_row_iterations);
    try std.testing.expectEqual(result.resolved_plan_misses, result.layout_draws);
    try std.testing.expectEqual(@as(u64, 0), result.resolved_plan_bypasses);
}

test "fragmented rows reuse plans across absolute columns" {
    const result = try benchmarkPipeline();
    const expected = @as(u64, result.fragmented_row_iterations) * 120;
    try std.testing.expectEqual(expected, result.fragmented_plan_hits);
    try std.testing.expectEqual(@as(u64, 0), result.fragmented_plan_misses);
    try std.testing.expectEqual(@as(u64, result.fragmented_row_iterations), result.atlas_batched_rows);
    try std.testing.expect(result.atlas_sprites >= expected);
    try std.testing.expectEqual(@as(u64, 0), result.fragmented_native_glyph_submissions);
    try std.testing.expect(result.atlas_placement_hits >= expected);
    // Dirty rows are coalesced into one D3D11 DrawInstanced submission.
    try std.testing.expect(result.atlas_sprite_batches >= 1);
    try std.testing.expect(result.uniform_native_glyph_submissions >= result.uniform_row_iterations);
    try std.testing.expect(result.glyph_slot_uses > 3);
    try std.testing.expect(result.glyph_slot_wraps > 0);
    try std.testing.expect(result.glyph_buffer_creations <= 3);
    try std.testing.expectEqual(result.glyph_buffer_creations, result.glyph_capacity_growths);
}

fn sum(values: []const f32) f32 {
    var total: f32 = 0;
    for (values) |value| total += value;
    return total;
}
