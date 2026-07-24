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

pub fn randomizedBackground(value: Theme, random: u16) Theme {
    var result = value;
    const hue: u16 = random % (6 * 256);
    const sector = hue / 256;
    const offset: u8 = @truncate(hue);
    const rising: u8 = 32 + @as(u8, @intCast((@as(u16, offset) * 223) / 255));
    const falling: u8 = 255 - @as(u8, @intCast((@as(u16, offset) * 223) / 255));
    const vivid = switch (sector) {
        0 => Color{ .red = 255, .green = rising, .blue = 32 },
        1 => Color{ .red = falling, .green = 255, .blue = 32 },
        2 => Color{ .red = 32, .green = 255, .blue = rising },
        3 => Color{ .red = 32, .green = falling, .blue = 255 },
        4 => Color{ .red = rising, .green = 32, .blue = 255 },
        else => Color{ .red = 255, .green = 32, .blue = falling },
    };
    const target = luminance(value.background);
    const source = luminance(vivid);
    result.background = .{
        .red = scaledChannel(vivid.red, target, source),
        .green = scaledChannel(vivid.green, target, source),
        .blue = scaledChannel(vivid.blue, target, source),
    };
    return result;
}

fn luminance(color: Color) u32 {
    return 2126 * @as(u32, color.red) + 7152 * @as(u32, color.green) + 722 * @as(u32, color.blue);
}

fn scaledChannel(channel: u8, target: u32, source: u32) u8 {
    return @intCast((@as(u64, channel) * target + source / 2) / source);
}

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

test "random backgrounds retain the theme background darkness" {
    const first = randomizedBackground(rasmus, 0);
    const second = randomizedBackground(rasmus, 900);

    try std.testing.expect(!std.meta.eql(first.background, second.background));
    const target: i64 = luminance(rasmus.background);
    try std.testing.expect(@abs(@as(i64, luminance(first.background)) - target) < 10_000);
    try std.testing.expect(@abs(@as(i64, luminance(second.background)) - target) < 10_000);
    try std.testing.expectEqual(rasmus.foreground, first.foreground);
    try std.testing.expectEqual(rasmus.ansi, first.ansi);
}
