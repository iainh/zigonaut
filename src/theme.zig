const std = @import("std");

pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub const Theme = struct {
    foreground: Color,
    background: Color,
    cursor: Color,
    ansi: [16]Color,
};

pub const rasmus = Theme{
    .background = hex(0x1a1a19),
    .foreground = hex(0xd1d1d1),
    .cursor = hex(0xd1d1d1),
    .ansi = .{
        hex(0x333332), hex(0xff968c), hex(0x61957f), hex(0xffc591),
        hex(0x8db4d4), hex(0xde9bc8), hex(0x7bb099), hex(0xd1d1d1),
        hex(0x4c4c4b), hex(0xffafa5), hex(0x7aae98), hex(0xffdeaa),
        hex(0xa6cded), hex(0xf7b4e1), hex(0x94c9b2), hex(0xeaeaea),
    },
};

fn hex(value: u24) Color {
    return .{
        .red = @truncate(value >> 16),
        .green = @truncate(value >> 8),
        .blue = @truncate(value),
    };
}

test "Rasmus theme exposes its Alacritty palette" {
    try std.testing.expectEqual(Color{ .red = 0x1a, .green = 0x1a, .blue = 0x19 }, rasmus.background);
    try std.testing.expectEqual(Color{ .red = 0xff, .green = 0x96, .blue = 0x8c }, rasmus.ansi[1]);
    try std.testing.expectEqual(Color{ .red = 0xea, .green = 0xea, .blue = 0xea }, rasmus.ansi[15]);
}
