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
