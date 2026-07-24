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

pub const Name = enum {
    rasmus,
    campbell,
    solarized_dark,

    pub fn parse(name: []const u8) ?Name {
        if (std.ascii.eqlIgnoreCase(name, "rasmus")) return .rasmus;
        if (std.ascii.eqlIgnoreCase(name, "campbell")) return .campbell;
        if (std.ascii.eqlIgnoreCase(name, "solarized-dark")) return .solarized_dark;
        return null;
    }

    pub fn value(self: Name) Theme {
        return switch (self) {
            .rasmus => rasmus,
            .campbell => campbell,
            .solarized_dark => solarized_dark,
        };
    }
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

pub const campbell = Theme{
    .background = hex(0x0c0c0c),
    .foreground = hex(0xcccccc),
    .cursor = hex(0xffffff),
    .ansi = .{
        hex(0x0c0c0c), hex(0xc50f1f), hex(0x13a10e), hex(0xc19c00),
        hex(0x0037da), hex(0x881798), hex(0x3a96dd), hex(0xcccccc),
        hex(0x767676), hex(0xe74856), hex(0x16c60c), hex(0xf9f1a5),
        hex(0x3b78ff), hex(0xb4009e), hex(0x61d6d6), hex(0xf2f2f2),
    },
};

pub const solarized_dark = Theme{
    .background = hex(0x002b36),
    .foreground = hex(0x839496),
    .cursor = hex(0x93a1a1),
    .ansi = .{
        hex(0x073642), hex(0xdc322f), hex(0x859900), hex(0xb58900),
        hex(0x268bd2), hex(0xd33682), hex(0x2aa198), hex(0xeee8d5),
        hex(0x002b36), hex(0xcb4b16), hex(0x586e75), hex(0x657b83),
        hex(0x839496), hex(0x6c71c4), hex(0x93a1a1), hex(0xfdf6e3),
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
