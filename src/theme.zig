const std = @import("std");
const log = std.log.scoped(.theme);

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
    if (target <= source) {
        return @intCast((@as(u64, channel) * target + source / 2) / source);
    }
    const remaining = 2_550_000 - source;
    return channel + @as(u8, @intCast((@as(u64, 255 - channel) * (target - source) + remaining / 2) / remaining));
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

    pub fn load(allocator: std.mem.Allocator, io: std.Io) Catalog {
        var result = Catalog{};
        const executable_directory = std.process.executableDirPathAlloc(io, allocator) catch return result;
        defer allocator.free(executable_directory);
        const path = std.fs.path.join(allocator, &.{ executable_directory, "themes" }) catch return result;
        defer allocator.free(path);
        var directory = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return result;
        defer directory.close(io);
        result.loadDirectory(allocator, io, directory) catch |err| log.warn("unable to load themes: {}", .{err});
        return result;
    }

    pub fn find(self: *const Catalog, name: []const u8) Theme {
        for (self.entries[0..self.count]) |*entry| {
            if (std.ascii.eqlIgnoreCase(name, entry.nameSlice())) return entry.value;
        }
        return rasmus;
    }

    fn loadDirectory(self: *Catalog, allocator: std.mem.Allocator, io: std.Io, directory: std.Io.Dir) !void {
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

test "random backgrounds support light themes" {
    var light = rasmus;
    light.background = hex(0xf3f3f3);

    const value = randomizedBackground(light, 0);

    try std.testing.expectEqual(@as(u8, 255), value.background.red);
    const target: i64 = luminance(light.background);
    try std.testing.expect(@abs(@as(i64, luminance(value.background)) - target) < 10_000);
    try std.testing.expectEqual(light.foreground, value.foreground);
    try std.testing.expectEqual(light.ansi, value.ansi);
}
