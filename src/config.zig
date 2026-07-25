const std = @import("std");
const theme = @import("theme.zig");

pub const default_contents =
    \\# Zigonaut configuration
    \\# Changes are applied when Zigonaut starts or reloads settings.
    \\font_family=Cascadia Mono
    \\font_size=18
    \\dark_theme=rasmus
    \\light_theme=campbell-light
    \\padding_horizontal=8
    \\padding_vertical=8
    \\background_opacity=100
    \\backdrop=mica
    \\default_shell=powershell
    \\custom_profile_name=Custom
    \\custom_command=
    \\working_directory=
    \\hold_on_exit=false
    \\randomize_tab_background=true
    \\
;

pub const Shell = enum {
    powershell,
    pwsh,
    cmd,
    wsl,
    custom,
};

pub const Backdrop = enum { none, mica, acrylic };

pub const Config = struct {
    font_family: []const u8 = "Cascadia Mono",
    font_size: u16 = 18,
    dark_theme: theme.Name = .rasmus,
    light_theme: theme.Name = .campbell_light,
    padding_horizontal: u16 = 8,
    padding_vertical: u16 = 8,
    background_opacity: u8 = 100,
    backdrop: Backdrop = .mica,
    palette: theme.Overrides = .{},
    default_shell: Shell = .powershell,
    custom_profile_name: []const u8 = "Custom",
    custom_command: []const u8 = "",
    working_directory: []const u8 = "",
    hold_on_exit: bool = false,
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
        .theme = previous.dark_theme != next.dark_theme or previous.light_theme != next.light_theme or
            !std.meta.eql(previous.palette, next.palette) or
            previous.randomize_tab_background != next.randomize_tab_background,
        .default_shell = previous.default_shell != next.default_shell,
    };
}

pub fn terminalTheme(settings: Config, dark: bool) theme.Theme {
    return settings.palette.apply((if (dark) settings.dark_theme else settings.light_theme).value());
}

pub fn clampZoom(current: u16, delta: i8) u16 {
    const changed: i32 = @as(i32, current) + delta;
    return @intCast(std.math.clamp(changed, 6, 72));
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
        } else if (std.ascii.eqlIgnoreCase(key, "theme") or std.ascii.eqlIgnoreCase(key, "dark_theme")) {
            result.dark_theme = theme.Name.parse(value) orelse result.dark_theme;
        } else if (std.ascii.eqlIgnoreCase(key, "light_theme")) {
            result.light_theme = theme.Name.parse(value) orelse result.light_theme;
        } else if (std.ascii.eqlIgnoreCase(key, "padding_horizontal")) {
            const padding = std.fmt.parseInt(u16, value, 10) catch continue;
            if (padding <= 128) result.padding_horizontal = padding;
        } else if (std.ascii.eqlIgnoreCase(key, "padding_vertical")) {
            const padding = std.fmt.parseInt(u16, value, 10) catch continue;
            if (padding <= 128) result.padding_vertical = padding;
        } else if (std.ascii.eqlIgnoreCase(key, "background_opacity")) {
            const opacity = std.fmt.parseInt(u8, value, 10) catch continue;
            if (opacity <= 100) result.background_opacity = opacity;
        } else if (std.ascii.eqlIgnoreCase(key, "backdrop")) {
            if (std.ascii.eqlIgnoreCase(value, "none")) result.backdrop = .none else if (std.ascii.eqlIgnoreCase(value, "mica")) result.backdrop = .mica else if (std.ascii.eqlIgnoreCase(value, "acrylic")) result.backdrop = .acrylic;
        } else if (std.ascii.eqlIgnoreCase(key, "foreground")) {
            result.palette.foreground = theme.parseColor(value) orelse result.palette.foreground;
        } else if (std.ascii.eqlIgnoreCase(key, "background")) {
            result.palette.background = theme.parseColor(value) orelse result.palette.background;
        } else if (std.ascii.eqlIgnoreCase(key, "cursor")) {
            result.palette.cursor = theme.parseColor(value) orelse result.palette.cursor;
        } else if (key.len > 4 and std.ascii.eqlIgnoreCase(key[0..4], "ansi")) {
            const index = std.fmt.parseInt(u8, key[4..], 10) catch continue;
            if (index < 16) result.palette.ansi[index] = theme.parseColor(value) orelse result.palette.ansi[index];
        } else if (std.ascii.eqlIgnoreCase(key, "default_shell")) {
            if (std.ascii.eqlIgnoreCase(value, "powershell")) {
                result.default_shell = .powershell;
            } else if (std.ascii.eqlIgnoreCase(value, "wsl")) {
                result.default_shell = .wsl;
            } else if (std.ascii.eqlIgnoreCase(value, "pwsh")) {
                result.default_shell = .pwsh;
            } else if (std.ascii.eqlIgnoreCase(value, "cmd")) {
                result.default_shell = .cmd;
            } else if (std.ascii.eqlIgnoreCase(value, "custom")) {
                result.default_shell = .custom;
            }
        } else if (std.ascii.eqlIgnoreCase(key, "custom_profile_name")) {
            if (value.len > 0 and value.len < 128) result.custom_profile_name = value;
        } else if (std.ascii.eqlIgnoreCase(key, "custom_command")) {
            result.custom_command = value;
        } else if (std.ascii.eqlIgnoreCase(key, "working_directory")) {
            result.working_directory = value;
        } else if (std.ascii.eqlIgnoreCase(key, "hold_on_exit")) {
            if (std.ascii.eqlIgnoreCase(value, "true")) result.hold_on_exit = true else if (std.ascii.eqlIgnoreCase(value, "false")) result.hold_on_exit = false;
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
        \\dark_theme=campbell
        \\light_theme=campbell-light
        \\padding_horizontal=12
        \\padding_vertical=4
        \\background_opacity=82
        \\backdrop=acrylic
        \\ansi15=#abcdef
        \\default_shell=WSL
        \\randomize_tab_background=false
    );
    try std.testing.expectEqualStrings("JetBrains Mono", parsed.font_family);
    try std.testing.expectEqual(@as(u16, 14), parsed.font_size);
    try std.testing.expectEqual(theme.Name.campbell, parsed.dark_theme);
    try std.testing.expectEqual(theme.Name.campbell_light, parsed.light_theme);
    try std.testing.expectEqual(@as(u16, 12), parsed.padding_horizontal);
    try std.testing.expectEqual(@as(u16, 4), parsed.padding_vertical);
    try std.testing.expectEqual(@as(u8, 82), parsed.background_opacity);
    try std.testing.expectEqual(Backdrop.acrylic, parsed.backdrop);
    try std.testing.expectEqual(theme.Color{ .red = 0xab, .green = 0xcd, .blue = 0xef }, parsed.palette.ansi[15].?);
    try std.testing.expectEqual(Shell.wsl, parsed.default_shell);
    try std.testing.expect(!parsed.randomize_tab_background);

    const invalid = parse("font_size=500\ntheme=unknown\ndefault_shell=fish\nrandomize_tab_background=perhaps\n");
    try std.testing.expectEqual(@as(u16, 18), invalid.font_size);
    try std.testing.expectEqual(theme.Name.rasmus, invalid.dark_theme);
    try std.testing.expectEqual(Shell.powershell, invalid.default_shell);
    try std.testing.expect(invalid.randomize_tab_background);
}

test "configuration parses launch profile settings" {
    const parsed = parse("default_shell=custom\ncustom_profile_name=Dev Shell\ncustom_command=tool.exe --flag\nworking_directory=C:\\work\nhold_on_exit=true\n");
    try std.testing.expectEqual(Shell.custom, parsed.default_shell);
    try std.testing.expectEqualStrings("Dev Shell", parsed.custom_profile_name);
    try std.testing.expectEqualStrings("tool.exe --flag", parsed.custom_command);
    try std.testing.expectEqualStrings("C:\\work", parsed.working_directory);
    try std.testing.expect(parsed.hold_on_exit);
}

test "configuration changes are classified by subsystem" {
    const original = Config{};
    try std.testing.expectEqual(Changes{ .font = false, .theme = false, .default_shell = false }, changes(original, original));

    var modified = original;
    modified.font_size = 20;
    try std.testing.expect(changes(original, modified).font);

    modified = original;
    modified.dark_theme = .campbell;
    try std.testing.expect(changes(original, modified).theme);

    modified = original;
    modified.default_shell = .wsl;
    try std.testing.expect(changes(original, modified).default_shell);
}

test "terminal theme selection follows app mode and applies overrides" {
    var value = Config{};
    value.palette.cursor = theme.parseColor("#123456");
    try std.testing.expectEqual(theme.rasmus.background, terminalTheme(value, true).background);
    try std.testing.expectEqual(theme.campbell_light.background, terminalTheme(value, false).background);
    try std.testing.expectEqual(theme.Color{ .red = 0x12, .green = 0x34, .blue = 0x56 }, terminalTheme(value, false).cursor);
}

test "zoom clamps to supported font bounds" {
    try std.testing.expectEqual(@as(u16, 6), clampZoom(6, -1));
    try std.testing.expectEqual(@as(u16, 72), clampZoom(72, 1));
    try std.testing.expectEqual(@as(u16, 19), clampZoom(18, 1));
}
