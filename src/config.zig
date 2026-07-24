const std = @import("std");
const theme = @import("theme.zig");

pub const default_contents =
    \\# Zigonaut configuration
    \\# Changes are applied when Zigonaut starts or reloads settings.
    \\font_family=Cascadia Mono
    \\font_size=18
    \\theme=rasmus
    \\default_shell=powershell
    \\randomize_tab_background=true
    \\
;

pub const Shell = enum {
    powershell,
    wsl,
};

pub const Config = struct {
    font_family: []const u8 = "Cascadia Mono",
    font_size: u16 = 18,
    theme: theme.Name = .rasmus,
    default_shell: Shell = .powershell,
    randomize_tab_background: bool = true,
};

pub const Changes = struct {
    font: bool,
    theme: bool,
    default_shell: bool,
};

pub fn changes(previous: Config, next: Config) Changes {
    return .{
        .font = previous.font_size != next.font_size or
            !std.mem.eql(u8, previous.font_family, next.font_family),
        .theme = previous.theme != next.theme or
            previous.randomize_tab_background != next.randomize_tab_background,
        .default_shell = previous.default_shell != next.default_shell,
    };
}

/// Owns the file contents backing borrowed string fields in `value`.
/// Keep this object alive for as long as its `Config` is in use.
pub const Loaded = struct {
    allocator: std.mem.Allocator,
    contents: []u8,
    value: Config,

    pub fn deinit(self: *Loaded) void {
        self.allocator.free(self.contents);
    }
};

/// Returns the absolute configuration path owned by the caller.
pub fn pathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const app_data = try std.process.getEnvVarOwned(allocator, "APPDATA");
    defer allocator.free(app_data);
    return std.fs.path.join(allocator, &.{ app_data, "spiralpoint", "zigonaut", "zigonaut.conf" });
}

pub fn loadOrCreate(allocator: std.mem.Allocator) !Loaded {
    const path = try pathAlloc(allocator);
    defer allocator.free(path);
    const directory = std.fs.path.dirname(path) orelse return error.InvalidConfigPath;

    try std.fs.cwd().makePath(directory);
    var file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => create: {
            var created = try std.fs.createFileAbsolute(path, .{});
            try created.writeAll(default_contents);
            created.close();
            break :create try std.fs.openFileAbsolute(path, .{});
        },
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 64 * 1024);
    return .{
        .allocator = allocator,
        .contents = contents,
        .value = parse(contents),
    };
}

pub fn parse(contents: []const u8) Config {
    var result = Config{};
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        const separator = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..separator], " \t");
        const value = std.mem.trim(u8, line[separator + 1 ..], " \t");

        if (std.ascii.eqlIgnoreCase(key, "font_family")) {
            if (value.len > 0 and value.len < 128) result.font_family = value;
        } else if (std.ascii.eqlIgnoreCase(key, "font_size")) {
            const size = std.fmt.parseInt(u16, value, 10) catch continue;
            if (size >= 6 and size <= 72) result.font_size = size;
        } else if (std.ascii.eqlIgnoreCase(key, "theme")) {
            result.theme = theme.Name.parse(value) orelse result.theme;
        } else if (std.ascii.eqlIgnoreCase(key, "default_shell")) {
            if (std.ascii.eqlIgnoreCase(value, "powershell")) {
                result.default_shell = .powershell;
            } else if (std.ascii.eqlIgnoreCase(value, "wsl")) {
                result.default_shell = .wsl;
            }
        } else if (std.ascii.eqlIgnoreCase(key, "randomize_tab_background")) {
            if (std.ascii.eqlIgnoreCase(value, "true")) {
                result.randomize_tab_background = true;
            } else if (std.ascii.eqlIgnoreCase(value, "false")) {
                result.randomize_tab_background = false;
            }
        }
    }
    return result;
}

test "configuration parses supported values and ignores invalid ones" {
    const parsed = parse(
        \\font_family = JetBrains Mono
        \\font_size=14
        \\theme=campbell
        \\default_shell=WSL
        \\randomize_tab_background=false
    );
    try std.testing.expectEqualStrings("JetBrains Mono", parsed.font_family);
    try std.testing.expectEqual(@as(u16, 14), parsed.font_size);
    try std.testing.expectEqual(theme.Name.campbell, parsed.theme);
    try std.testing.expectEqual(Shell.wsl, parsed.default_shell);
    try std.testing.expect(!parsed.randomize_tab_background);

    const invalid = parse("font_size=500\ntheme=unknown\ndefault_shell=cmd\nrandomize_tab_background=perhaps\n");
    try std.testing.expectEqual(@as(u16, 18), invalid.font_size);
    try std.testing.expectEqual(theme.Name.rasmus, invalid.theme);
    try std.testing.expectEqual(Shell.powershell, invalid.default_shell);
    try std.testing.expect(invalid.randomize_tab_background);
}

test "configuration changes are classified by subsystem" {
    const original = Config{};
    try std.testing.expectEqual(Changes{ .font = false, .theme = false, .default_shell = false }, changes(original, original));

    var modified = original;
    modified.font_size = 20;
    try std.testing.expect(changes(original, modified).font);

    modified = original;
    modified.theme = .campbell;
    try std.testing.expect(changes(original, modified).theme);

    modified = original;
    modified.default_shell = .wsl;
    try std.testing.expect(changes(original, modified).default_shell);
}
