//! Allocation-free image kernels. Native renderers own pixels and resources.
const std = @import("std");

pub const PixelFormat = enum(u32) { rgba = 0, native_argb = 1 };

pub fn premultiply(rgba: [*]const u8, output: [*]u8, width: usize, height: usize, stride: usize, format: PixelFormat) void {
    for (0..height) |y| {
        for (0..width) |x| {
            const input = rgba + (y * width + x) * 4;
            const destination = output + y * stride + x * 4;
            const a: u32 = input[3];
            const r = (@as(u32, input[0]) * a + 127) / 255;
            const g = (@as(u32, input[1]) * a + 127) / 255;
            const b = (@as(u32, input[2]) * a + 127) / 255;
            switch (format) {
                .rgba => destination[0..4].* = .{ @intCast(r), @intCast(g), @intCast(b), @intCast(a) },
                .native_argb => @as(*align(1) u32, @ptrCast(destination)).* = a << 24 | r << 16 | g << 8 | b,
            }
        }
    }
}

export fn zigonaut_image_premultiply(rgba: [*]const u8, output: [*]u8, width: usize, height: usize, stride: usize, format: u32) void {
    premultiply(rgba, output, width, height, stride, @enumFromInt(format));
}

pub fn Rect(comptime T: type) type {
    return extern struct { x: T, y: T, width: T, height: T };
}

pub fn Clip(comptime T: type) type {
    return extern struct { left: T, top: T, right: T, bottom: T };
}

pub fn Quad(comptime T: type) type {
    return extern struct { destination: Rect(T), source: Rect(T) };
}

pub const Visibility = enum(u32) { invalid = 0, invisible = 1, visible = 2 };

fn validRect(rect: anytype) bool {
    return std.math.isFinite(rect.x) and std.math.isFinite(rect.y) and
        std.math.isFinite(rect.width) and std.math.isFinite(rect.height) and
        rect.width > 0 and rect.height > 0 and
        std.math.isFinite(rect.x + rect.width) and std.math.isFinite(rect.y + rect.height);
}

pub fn clippedQuad(comptime T: type, destination: Rect(T), source: Rect(T), clip: Clip(T), output: *Quad(T)) Visibility {
    if (!validRect(destination) or !validRect(source) or source.x < 0 or source.y < 0 or
        !std.math.isFinite(clip.left) or !std.math.isFinite(clip.top) or
        !std.math.isFinite(clip.right) or !std.math.isFinite(clip.bottom) or
        clip.left >= clip.right or clip.top >= clip.bottom) return .invalid;
    const left = @max(destination.x, clip.left);
    const top = @max(destination.y, clip.top);
    const right = @min(destination.x + destination.width, clip.right);
    const bottom = @min(destination.y + destination.height, clip.bottom);
    if (left >= right or top >= bottom) return .invisible;
    const visible: Rect(T) = .{ .x = left, .y = top, .width = right - left, .height = bottom - top };
    const x_scale = source.width / destination.width;
    const y_scale = source.height / destination.height;
    const mapped: Rect(T) = .{
        .x = source.x + (left - destination.x) * x_scale,
        .y = source.y + (top - destination.y) * y_scale,
        .width = visible.width * x_scale,
        .height = visible.height * y_scale,
    };
    if (!validRect(visible) or !validRect(mapped)) return .invalid;
    output.* = .{ .destination = visible, .source = mapped };
    return .visible;
}

export fn zigonaut_image_clip_quad(destination: Rect(f64), source: Rect(f64), clip: Clip(f64), output: *Quad(f64)) u32 {
    return @intFromEnum(clippedQuad(f64, destination, source, clip, output));
}

export fn zigonaut_image_clip_quad_f32(destination: Rect(f32), source: Rect(f32), clip: Clip(f32), output: *Quad(f32)) u32 {
    return @intFromEnum(clippedQuad(f32, destination, source, clip, output));
}

test "premultiplication preserves channel order, rounding, row stride and padding" {
    const rgba = [_]u8{ 240, 40, 80, 128, 200, 100, 30, 64, 12, 90, 210, 255, 70, 30, 220, 0 };
    var output = [_]u8{0xaa} ** 24;
    zigonaut_image_premultiply(&rgba, &output, 2, 2, 12, 0);
    try std.testing.expectEqualSlices(u8, &.{ 120, 20, 40, 128, 50, 25, 8, 64, 0xaa, 0xaa, 0xaa, 0xaa, 12, 90, 210, 255, 0, 0, 0, 0, 0xaa, 0xaa, 0xaa, 0xaa }, &output);
    zigonaut_image_premultiply(&rgba, &output, 2, 2, 12, 1);
    for ([_]u32{ 0x80781428, 0x40321908, 0xff0c5ad2, 0 }, 0..) |word, i| {
        const offset = (i / 2) * 12 + (i % 2) * 4;
        try std.testing.expectEqual(word, @as(*align(1) const u32, @ptrCast(&output[offset])).*);
    }
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 4), output[8..12]);
    try std.testing.expectEqualSlices(u8, &([_]u8{0xaa} ** 4), output[20..24]);
}

test "image clipping preserves fractional placement and coupled crop mapping at native precision" {
    inline for (.{ f32, f64 }) |T| {
        var quad: Quad(T) = undefined;
        const destination: Rect(T) = .{ .x = -10.25, .y = 20.125, .width = 100, .height = 50 };
        const source: Rect(T) = .{ .x = 20, .y = 40, .width = 200, .height = 100 };
        const clip: Clip(T) = .{ .left = 0.25, .top = 22.625, .right = 80.25, .bottom = 60.125 };
        const status = if (T == f32) zigonaut_image_clip_quad_f32(destination, source, clip, &quad) else zigonaut_image_clip_quad(destination, source, clip, &quad);
        try std.testing.expectEqual(@as(u32, 2), status);
        try std.testing.expectEqualDeep(Rect(T){ .x = 0.25, .y = 22.625, .width = 80, .height = 37.5 }, quad.destination);
        try std.testing.expectEqualDeep(Rect(T){ .x = 41, .y = 45, .width = 160, .height = 75 }, quad.source);
        // An interior placement keeps its entire source crop, not bitmap origin.
        const inside: Rect(T) = .{ .x = 1.25, .y = 23.125, .width = 10, .height = 20 };
        try std.testing.expectEqual(Visibility.visible, clippedQuad(T, inside, source, clip, &quad));
        try std.testing.expectEqualDeep(inside, quad.destination);
        try std.testing.expectEqualDeep(source, quad.source);
        // Touching edges are invisible on all four sides, not invalid.
        for ([_]Rect(T){
            .{ .x = -9.75, .y = 30, .width = 10, .height = 10 },
            .{ .x = 80.25, .y = 30, .width = 10, .height = 10 },
            .{ .x = 20, .y = 12.625, .width = 10, .height = 10 },
            .{ .x = 20, .y = 60.125, .width = 10, .height = 10 },
        }) |outside| try std.testing.expectEqual(Visibility.invisible, clippedQuad(T, outside, source, clip, &quad));
        // At 2^24, f32 loses a one-pixel width; double must not lose it.
        const narrow: Rect(T) = .{ .x = 16777216, .y = 0, .width = 1, .height = 10 };
        const wide_clip: Clip(T) = .{ .left = 16777216, .top = 0, .right = 16777218, .bottom = 20 };
        try std.testing.expectEqual(if (T == f32) Visibility.invisible else Visibility.visible, clippedQuad(T, narrow, source, wide_clip, &quad));
    }
}

test "image geometry rejects nonfinite, overflowing and empty inputs before exposing output" {
    inline for (.{ f32, f64 }) |T| {
        const rect: Rect(T) = .{ .x = 0, .y = 0, .width = 10, .height = 20 };
        const clip: Clip(T) = .{ .left = 0, .top = 0, .right = 10, .bottom = 20 };
        const initial: Quad(T) = .{ .destination = rect, .source = rect };
        var quad = initial;
        inline for (std.meta.fields(Rect(T))) |field| {
            for ([_]T{ std.math.nan(T), std.math.inf(T), -std.math.inf(T) }) |value| {
                var invalid = rect;
                @field(invalid, field.name) = value;
                try std.testing.expectEqual(Visibility.invalid, clippedQuad(T, invalid, rect, clip, &quad));
                try std.testing.expectEqual(Visibility.invalid, clippedQuad(T, rect, invalid, clip, &quad));
            }
        }
        inline for (std.meta.fields(Clip(T))) |field| {
            var invalid = clip;
            @field(invalid, field.name) = std.math.nan(T);
            try std.testing.expectEqual(Visibility.invalid, clippedQuad(T, rect, rect, invalid, &quad));
        }
        for ([_]Rect(T){
            .{ .x = 0, .y = 0, .width = 0, .height = 20 },
            .{ .x = 0, .y = 0, .width = 10, .height = -1 },
            .{ .x = std.math.floatMax(T), .y = 0, .width = std.math.floatMax(T), .height = 20 },
        }) |invalid| try std.testing.expectEqual(Visibility.invalid, clippedQuad(T, invalid, rect, clip, &quad));
        try std.testing.expectEqual(Visibility.invalid, clippedQuad(T, rect, .{ .x = -1, .y = 0, .width = 10, .height = 20 }, clip, &quad));
        try std.testing.expectEqual(Visibility.invalid, clippedQuad(T, rect, rect, .{ .left = 10, .top = 0, .right = 0, .bottom = 20 }, &quad));
        // Finite input can still overflow the source/destination scale.
        try std.testing.expectEqual(Visibility.invalid, clippedQuad(T, .{ .x = 0, .y = 0, .width = std.math.floatMin(T), .height = 20 }, .{ .x = 0, .y = 0, .width = std.math.floatMax(T), .height = 20 }, clip, &quad));
        try std.testing.expectEqualDeep(initial, quad);
    }
}
