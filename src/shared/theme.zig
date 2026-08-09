const std = @import("std");
const log = std.log.scoped(.theme);

pub const Color = struct {
    red: u8,
    green: u8,
    blue: u8,
};

pub const random_accent_count: u16 = 6 * 256;

pub const Theme = struct {
    foreground: Color,
    background: Color,
    cursor: Color,
    ansi: [16]Color,
};

pub const Overrides = struct {
    foreground: ?Color = null,
    background: ?Color = null,
    cursor: ?Color = null,
    ansi: [16]?Color = @splat(null),

    pub fn apply(self: Overrides, base: Theme) Theme {
        var result = base;
        if (self.foreground) |value| result.foreground = value;
        if (self.background) |value| result.background = value;
        if (self.cursor) |value| result.cursor = value;
        for (self.ansi, 0..) |value, index| if (value) |color| {
            result.ansi[index] = color;
        };
        return result;
    }
};

pub fn parseColor(text: []const u8) ?Color {
    const digits = if (text.len == 7 and text[0] == '#') text[1..] else if (text.len == 6) text else return null;
    const value = std.fmt.parseInt(u24, digits, 16) catch return null;
    return hex(value);
}

pub fn randomizedBackground(value: Theme, random: u16) Theme {
    var result = value;
    const vivid = randomAccent(random);
    result.background = .{
        .red = tintChannel(value.background.red, vivid.red),
        .green = tintChannel(value.background.green, vivid.green),
        .blue = tintChannel(value.background.blue, vivid.blue),
    };
    return result;
}

pub fn randomAccent(random: u16) Color {
    const hue: u16 = random % random_accent_count;
    const sector = hue / 256;
    const offset: u8 = @truncate(hue);
    const rising: u8 = 32 + @as(u8, @intCast((@as(u16, offset) * 223) / 255));
    const falling: u8 = 255 - @as(u8, @intCast((@as(u16, offset) * 223) / 255));
    return switch (sector) {
        0 => Color{ .red = 255, .green = rising, .blue = 32 },
        1 => Color{ .red = falling, .green = 255, .blue = 32 },
        2 => Color{ .red = 32, .green = 255, .blue = rising },
        3 => Color{ .red = 32, .green = falling, .blue = 255 },
        4 => Color{ .red = rising, .green = 32, .blue = 255 },
        else => Color{ .red = 255, .green = 32, .blue = falling },
    };
}

fn tintChannel(background: u8, tint: u8) u8 {
    return @intCast((@as(u16, background) * 7 + tint + 4) / 8);
}

const max_themes = 64;
const max_name_length = 63;

const Entry = struct {
    name: [max_name_length]u8,
    name_length: u8,
    value: Theme,

    fn nameSlice(self: *const Entry) []const u8 {
        return self.name[0..self.name_length];
    }
};

pub const Catalog = struct {
    entries: [max_themes]Entry = undefined,
    count: usize = 0,

    pub fn loadDirectory(allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) Catalog {
        var result = Catalog{};
        result.appendDirectory(allocator, io, directory) catch |err| log.warn("unable to load themes: {}", .{err});
        return result;
    }

    pub fn find(self: *const Catalog, name: []const u8) Theme {
        for (self.entries[0..self.count]) |*entry| {
            if (std.ascii.eqlIgnoreCase(name, entry.nameSlice())) return entry.value;
        }
        return rasmus;
    }

    fn appendDirectory(self: *Catalog, allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !void {
        var iterator = directory.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file or !std.ascii.endsWithIgnoreCase(entry.name, ".json")) continue;
            const name = entry.name[0 .. entry.name.len - ".json".len];
            if (name.len == 0 or name.len > max_name_length or self.count == max_themes) continue;
            const contents = directory.readFileAlloc(io, entry.name, allocator, .limited(64 * 1024)) catch |err| {
                log.warn("unable to read theme {s}: {}", .{ entry.name, err });
                continue;
            };
            defer allocator.free(contents);
            const value = parseJson(allocator, contents) catch |err| {
                log.warn("unable to parse theme {s}: {}", .{ entry.name, err });
                continue;
            };
            var destination = &self.entries[self.count];
            @memcpy(destination.name[0..name.len], name);
            destination.name_length = @intCast(name.len);
            destination.value = value;
            self.count += 1;
        }
    }
};

const JsonTheme = struct {
    foreground: []const u8,
    background: []const u8,
    cursor: []const u8,
    ansi: [16][]const u8,
};

fn parseJson(allocator: std.mem.Allocator, contents: []const u8) !Theme {
    const parsed = try std.json.parseFromSlice(JsonTheme, allocator, contents, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    var result = Theme{
        .foreground = parseColor(parsed.value.foreground) orelse return error.InvalidColor,
        .background = parseColor(parsed.value.background) orelse return error.InvalidColor,
        .cursor = parseColor(parsed.value.cursor) orelse return error.InvalidColor,
        .ansi = undefined,
    };
    for (parsed.value.ansi, 0..) |color, index| {
        result.ansi[index] = parseColor(color) orelse return error.InvalidColor;
    }
    return result;
}

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

test "colors parse and palette overrides are applied independently" {
    try std.testing.expectEqual(Color{ .red = 0x12, .green = 0xab, .blue = 0xef }, parseColor("#12abef").?);
    try std.testing.expect(parseColor("#1234") == null);
    var overrides = Overrides{};
    overrides.foreground = parseColor("ffffff");
    overrides.ansi[3] = parseColor("#010203");
    const value = overrides.apply(rasmus);
    try std.testing.expectEqual(hex(0xffffff), value.foreground);
    try std.testing.expectEqual(hex(0x010203), value.ansi[3]);
    try std.testing.expectEqual(rasmus.background, value.background);
}

test "JSON themes parse complete color palettes" {
    const value = try parseJson(std.testing.allocator,
        \\{
        \\  "foreground":"#010203", "background":"#040506", "cursor":"#070809",
        \\  "ansi":["#000000","#000001","#000002","#000003","#000004","#000005","#000006","#000007",
        \\          "#000008","#000009","#00000a","#00000b","#00000c","#00000d","#00000e","#00000f"]
        \\}
    );
    try std.testing.expectEqual(Color{ .red = 1, .green = 2, .blue = 3 }, value.foreground);
    try std.testing.expectEqual(Color{ .red = 0, .green = 0, .blue = 15 }, value.ansi[15]);
}

test "catalog parses a host-provided resource directory" {
    var directory = try std.Io.Dir.cwd().openDir(std.testing.io, "themes", .{ .iterate = true });
    defer directory.close(std.testing.io);
    const catalog = Catalog.loadDirectory(std.testing.allocator, std.testing.io, directory);
    try std.testing.expect(catalog.count >= 5);
    try std.testing.expectEqual(hex(0xffffff), catalog.find("fluent-light").background);
}

test "Fluent themes meet WCAG AA contrast against their backgrounds" {
    inline for (.{
        "themes/fluent-light.json",
        "themes/fluent-dark.json",
    }) |path| {
        const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(64 * 1024));
        defer std.testing.allocator.free(contents);
        const value = try parseJson(std.testing.allocator, contents);
        try expectAaContrast(value.foreground, value.background);
        try expectAaContrast(value.cursor, value.background);
        for (value.ansi) |color| try expectAaContrast(color, value.background);
    }
}

fn expectAaContrast(foreground: Color, background: Color) !void {
    const lighter = @max(relativeLuminance(foreground), relativeLuminance(background));
    const darker = @min(relativeLuminance(foreground), relativeLuminance(background));
    try std.testing.expect((lighter + 0.05) / (darker + 0.05) >= 4.5);
}

fn relativeLuminance(color: Color) f64 {
    return 0.2126 * linearChannel(color.red) +
        0.7152 * linearChannel(color.green) +
        0.0722 * linearChannel(color.blue);
}

fn linearChannel(channel: u8) f64 {
    const value: f64 = @as(f64, @floatFromInt(channel)) / 255.0;
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}

test "random accents are vivid primary hues" {
    try std.testing.expectEqual(hex(0xff2020), randomAccent(0));
    try std.testing.expectEqual(hex(0x20ff20), randomAccent(512));
    try std.testing.expectEqual(hex(0x2020ff), randomAccent(1024));
}

test "random backgrounds remain close to the theme background" {
    const first = randomizedBackground(rasmus, 0);
    const second = randomizedBackground(rasmus, 900);

    try std.testing.expect(!std.meta.eql(first.background, second.background));
    inline for (.{ "red", "green", "blue" }) |field| {
        const original: i16 = @field(rasmus.background, field);
        try std.testing.expect(@abs(@as(i16, @field(first.background, field)) - original) <= 32);
        try std.testing.expect(@abs(@as(i16, @field(second.background, field)) - original) <= 32);
    }
    try std.testing.expectEqual(rasmus.foreground, first.foreground);
    try std.testing.expectEqual(rasmus.cursor, first.cursor);
    try std.testing.expectEqual(rasmus.ansi, first.ansi);
}

test "random backgrounds tint white and black" {
    var value = rasmus;
    value.background = hex(0xffffff);
    try std.testing.expectEqual(hex(0xffe3e3), randomizedBackground(value, 0).background);
    try std.testing.expectEqual(hex(0xe3ffe3), randomizedBackground(value, 512).background);
    try std.testing.expectEqual(hex(0xe3e3ff), randomizedBackground(value, 1024).background);

    value.background = hex(0x000000);
    try std.testing.expectEqual(hex(0x200404), randomizedBackground(value, 0).background);
    try std.testing.expectEqual(hex(0x042004), randomizedBackground(value, 512).background);
    try std.testing.expectEqual(hex(0x040420), randomizedBackground(value, 1024).background);
}

test "random backgrounds gently tint existing colors" {
    var value = rasmus;
    value.background = hex(0x336699);

    try std.testing.expectEqual(hex(0x4d5d8a), randomizedBackground(value, 0).background);
}
