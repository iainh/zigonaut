const std = @import("std");
const theme = @import("theme.zig");

pub const default_contents =
    \\# Zigonaut configuration
    \\# Changes are applied when Zigonaut starts or reloads settings.
    \\#
    \\# Terminal font family. Default: Cascadia Mono.
    \\font_family=Cascadia Mono
    \\# Terminal font size in points (6-72). Default: 18.
    \\font_size=18
    \\# Theme used in dark application mode. Default: rasmus.
    \\dark_theme=rasmus
    \\# Theme used in light application mode. Default: campbell-light.
    \\light_theme=campbell-light
    \\# Application color scheme: system, light, or dark. Default: system.
    \\color_scheme=system
    \\# Horizontal terminal padding in pixels (0-128). Default: 8.
    \\padding_horizontal=8
    \\# Vertical terminal padding in pixels (0-128). Default: 8.
    \\padding_vertical=8
    \\# Terminal background opacity percentage (0-100). Default: 100.
    \\background_opacity=100
    \\# Window backdrop: none, mica, or acrylic. Default: mica.
    \\backdrop=mica
    \\#
    \\# Palette overrides use #RRGGBB. Their defaults come from the selected
    \\# dark_theme or light_theme, so they are commented out unless overridden.
    \\# Terminal foreground color. Default: selected theme foreground.
    \\#foreground=#RRGGBB
    \\# Terminal background color. Default: selected theme background.
    \\#background=#RRGGBB
    \\# Terminal cursor color. Default: selected theme cursor.
    \\#cursor=#RRGGBB
    \\# ANSI black. Default: selected theme ANSI 0.
    \\#ansi0=#RRGGBB
    \\# ANSI red. Default: selected theme ANSI 1.
    \\#ansi1=#RRGGBB
    \\# ANSI green. Default: selected theme ANSI 2.
    \\#ansi2=#RRGGBB
    \\# ANSI yellow. Default: selected theme ANSI 3.
    \\#ansi3=#RRGGBB
    \\# ANSI blue. Default: selected theme ANSI 4.
    \\#ansi4=#RRGGBB
    \\# ANSI magenta. Default: selected theme ANSI 5.
    \\#ansi5=#RRGGBB
    \\# ANSI cyan. Default: selected theme ANSI 6.
    \\#ansi6=#RRGGBB
    \\# ANSI white. Default: selected theme ANSI 7.
    \\#ansi7=#RRGGBB
    \\# ANSI bright black. Default: selected theme ANSI 8.
    \\#ansi8=#RRGGBB
    \\# ANSI bright red. Default: selected theme ANSI 9.
    \\#ansi9=#RRGGBB
    \\# ANSI bright green. Default: selected theme ANSI 10.
    \\#ansi10=#RRGGBB
    \\# ANSI bright yellow. Default: selected theme ANSI 11.
    \\#ansi11=#RRGGBB
    \\# ANSI bright blue. Default: selected theme ANSI 12.
    \\#ansi12=#RRGGBB
    \\# ANSI bright magenta. Default: selected theme ANSI 13.
    \\#ansi13=#RRGGBB
    \\# ANSI bright cyan. Default: selected theme ANSI 14.
    \\#ansi14=#RRGGBB
    \\# ANSI bright white. Default: selected theme ANSI 15.
    \\#ansi15=#RRGGBB
    \\#
    \\# Profile opened initially and by Ctrl+Shift+T. Default: PowerShell.
    \\default_profile=PowerShell
    \\# Launch profiles use profile.<name>=<shell type>|<command line>.
    \\# Shell types are powershell, windows, and wsl. These four profiles are
    \\# the defaults; declaring any profile.* key replaces the default set.
    \\profile.PowerShell=powershell|powershell.exe
    \\profile.PowerShell 7=powershell|pwsh.exe
    \\profile.Command Prompt=windows|cmd.exe
    \\profile.WSL=wsl|wsl.exe
    \\# Working directory for new processes. Default: the user's home directory.
    \\working_directory=
    \\# Keep a new tab open after its process exits cleanly. Default: false.
    \\hold_on_exit=false
    \\# Give each new tab a randomized background hue. Default: true.
    \\randomize_tab_background=true
    \\# Allow OSC 52 and OSC 1337 Copy writes to the Windows clipboard. Default: false.
    \\osc52_clipboard_write=false
    \\# Maximum decoded terminal clipboard payload in bytes (1-16777216). Default: 1048576.
    \\osc52_clipboard_max_bytes=1048576
    \\#
    \\# Legacy alias: theme sets dark_theme. Default: not set.
    \\#theme=rasmus
    \\
;

pub const Shell = enum {
    powershell,
    windows,
    wsl,
};

pub const max_profiles = 32;

pub const Profile = struct {
    name: []const u8,
    shell: Shell,
    command: []const u8,
};

const default_profiles = [4]Profile{
    .{ .name = "PowerShell", .shell = .powershell, .command = "powershell.exe" },
    .{ .name = "PowerShell 7", .shell = .powershell, .command = "pwsh.exe" },
    .{ .name = "Command Prompt", .shell = .windows, .command = "cmd.exe" },
    .{ .name = "WSL", .shell = .wsl, .command = "wsl.exe" },
} ++ [_]Profile{.{ .name = "", .shell = .windows, .command = "" }} ** (max_profiles - 4);

pub const Backdrop = enum { none, mica, acrylic };
pub const ColorScheme = enum { system, light, dark };

pub const Config = struct {
    font_family: []const u8 = "Cascadia Mono",
    font_size: u16 = 18,
    dark_theme: []const u8 = "rasmus",
    light_theme: []const u8 = "campbell-light",
    color_scheme: ColorScheme = .system,
    padding_horizontal: u16 = 8,
    padding_vertical: u16 = 8,
    background_opacity: u8 = 100,
    backdrop: Backdrop = .mica,
    palette: theme.Overrides = .{},
    default_profile: []const u8 = "PowerShell",
    profiles: [max_profiles]Profile = default_profiles,
    profile_count: usize = 4,
    working_directory: []const u8 = "",
    hold_on_exit: bool = false,
    randomize_tab_background: bool = true,
    osc52_clipboard_write: bool = false,
    osc52_clipboard_max_bytes: u32 = 1024 * 1024,

    pub fn profileSlice(self: *const Config) []const Profile {
        return self.profiles[0..self.profile_count];
    }

    pub fn defaultProfile(self: *const Config) Profile {
        for (self.profileSlice()) |profile| {
            if (std.ascii.eqlIgnoreCase(profile.name, self.default_profile)) return profile;
        }
        return self.profiles[0];
    }
};

pub const Changes = struct {
    font: bool,
    theme: bool,
};

pub fn changes(previous: Config, next: Config) Changes {
    return .{
        .font = previous.font_size != next.font_size or
            !std.mem.eql(u8, previous.font_family, next.font_family),
        .theme = !std.mem.eql(u8, previous.dark_theme, next.dark_theme) or
            !std.mem.eql(u8, previous.light_theme, next.light_theme) or
            previous.color_scheme != next.color_scheme or
            !std.meta.eql(previous.palette, next.palette) or
            previous.randomize_tab_background != next.randomize_tab_background,
    };
}

pub fn terminalTheme(settings: Config, themes: *const theme.Catalog, dark: bool) theme.Theme {
    return settings.palette.apply(themes.find(if (dark) settings.dark_theme else settings.light_theme));
}

pub fn useDarkTheme(settings: Config, os_dark: bool) bool {
    return switch (settings.color_scheme) {
        .system => os_dark,
        .light => false,
        .dark => true,
    };
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
    var declared_profiles = false;
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
            if (value.len > 0 and value.len < 64) result.dark_theme = value;
        } else if (std.ascii.eqlIgnoreCase(key, "light_theme")) {
            if (value.len > 0 and value.len < 64) result.light_theme = value;
        } else if (std.ascii.eqlIgnoreCase(key, "color_scheme")) {
            if (std.ascii.eqlIgnoreCase(value, "system")) result.color_scheme = .system else if (std.ascii.eqlIgnoreCase(value, "light")) result.color_scheme = .light else if (std.ascii.eqlIgnoreCase(value, "dark")) result.color_scheme = .dark;
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
        } else if (std.ascii.eqlIgnoreCase(key, "default_profile")) {
            if (value.len > 0 and value.len < 128) result.default_profile = value;
        } else if (key.len > "profile.".len and std.ascii.eqlIgnoreCase(key[0.."profile.".len], "profile.")) {
            const name = std.mem.trim(u8, key["profile.".len..], " \t");
            const kind_end = std.mem.indexOfScalar(u8, value, '|') orelse continue;
            const kind = std.mem.trim(u8, value[0..kind_end], " \t");
            const command = std.mem.trim(u8, value[kind_end + 1 ..], " \t");
            const shell: Shell = if (std.ascii.eqlIgnoreCase(kind, "powershell"))
                .powershell
            else if (std.ascii.eqlIgnoreCase(kind, "windows"))
                .windows
            else if (std.ascii.eqlIgnoreCase(kind, "wsl"))
                .wsl
            else
                continue;
            if (name.len == 0 or name.len >= 128 or !std.unicode.utf8ValidateSlice(name) or command.len == 0) continue;
            if (!declared_profiles) {
                result.profile_count = 0;
                declared_profiles = true;
            }
            if (result.profile_count < max_profiles) {
                result.profiles[result.profile_count] = .{ .name = name, .shell = shell, .command = command };
                result.profile_count += 1;
            }
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
        } else if (std.ascii.eqlIgnoreCase(key, "osc52_clipboard_write")) {
            if (std.ascii.eqlIgnoreCase(value, "true")) result.osc52_clipboard_write = true else if (std.ascii.eqlIgnoreCase(value, "false")) result.osc52_clipboard_write = false;
        } else if (std.ascii.eqlIgnoreCase(key, "osc52_clipboard_max_bytes")) {
            const limit = std.fmt.parseInt(u32, value, 10) catch continue;
            if (limit >= 1 and limit <= 16 * 1024 * 1024) result.osc52_clipboard_max_bytes = limit;
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
        \\color_scheme=light
        \\padding_horizontal=12
        \\padding_vertical=4
        \\background_opacity=82
        \\backdrop=acrylic
        \\ansi15=#abcdef
        \\default_profile=WSL
        \\randomize_tab_background=false
        \\osc52_clipboard_write=true
        \\osc52_clipboard_max_bytes=65536
    );
    try std.testing.expectEqualStrings("JetBrains Mono", parsed.font_family);
    try std.testing.expectEqual(@as(u16, 14), parsed.font_size);
    try std.testing.expectEqualStrings("campbell", parsed.dark_theme);
    try std.testing.expectEqualStrings("campbell-light", parsed.light_theme);
    try std.testing.expectEqual(ColorScheme.light, parsed.color_scheme);
    try std.testing.expectEqual(@as(u16, 12), parsed.padding_horizontal);
    try std.testing.expectEqual(@as(u16, 4), parsed.padding_vertical);
    try std.testing.expectEqual(@as(u8, 82), parsed.background_opacity);
    try std.testing.expectEqual(Backdrop.acrylic, parsed.backdrop);
    try std.testing.expectEqual(theme.Color{ .red = 0xab, .green = 0xcd, .blue = 0xef }, parsed.palette.ansi[15].?);
    try std.testing.expectEqualStrings("WSL", parsed.defaultProfile().name);
    try std.testing.expect(!parsed.randomize_tab_background);
    try std.testing.expect(parsed.osc52_clipboard_write);
    try std.testing.expectEqual(@as(u32, 65536), parsed.osc52_clipboard_max_bytes);

    const invalid = parse("font_size=500\ntheme=unknown\ndefault_profile=missing\nrandomize_tab_background=perhaps\nosc52_clipboard_write=perhaps\nosc52_clipboard_max_bytes=999999999\n");
    try std.testing.expectEqual(@as(u16, 18), invalid.font_size);
    try std.testing.expectEqualStrings("unknown", invalid.dark_theme);
    try std.testing.expectEqualStrings("PowerShell", invalid.defaultProfile().name);
    try std.testing.expect(invalid.randomize_tab_background);
    try std.testing.expect(!invalid.osc52_clipboard_write);
    try std.testing.expectEqual(@as(u32, 1024 * 1024), invalid.osc52_clipboard_max_bytes);
}

test "configuration parses launch profiles" {
    const parsed = parse("default_profile=Dev Shell\nprofile.Dev Shell=windows|tool.exe --flag\nprofile.Linux=wsl|ubuntu.exe\nworking_directory=C:\\work\nhold_on_exit=true\n");
    try std.testing.expectEqual(@as(usize, 2), parsed.profile_count);
    try std.testing.expectEqualStrings("Dev Shell", parsed.defaultProfile().name);
    try std.testing.expectEqual(Shell.windows, parsed.defaultProfile().shell);
    try std.testing.expectEqualStrings("tool.exe --flag", parsed.defaultProfile().command);
    try std.testing.expectEqualStrings("Linux", parsed.profiles[1].name);
    try std.testing.expectEqual(Shell.wsl, parsed.profiles[1].shell);
    try std.testing.expectEqualStrings("C:\\work", parsed.working_directory);
    try std.testing.expect(parsed.hold_on_exit);
}

test "configuration changes are classified by subsystem" {
    const original = Config{};
    try std.testing.expectEqual(Changes{ .font = false, .theme = false }, changes(original, original));

    var modified = original;
    modified.font_size = 20;
    try std.testing.expect(changes(original, modified).font);

    modified = original;
    modified.dark_theme = "campbell";
    try std.testing.expect(changes(original, modified).theme);

    modified = original;
    modified.color_scheme = .dark;
    try std.testing.expect(changes(original, modified).theme);
}

test "terminal theme selection follows app mode and applies overrides" {
    const themes = theme.Catalog{};
    var value = Config{};
    value.palette.cursor = theme.parseColor("#123456");
    try std.testing.expectEqual(theme.rasmus.background, terminalTheme(value, &themes, true).background);
    try std.testing.expectEqual(theme.rasmus.background, terminalTheme(value, &themes, false).background);
    try std.testing.expectEqual(theme.Color{ .red = 0x12, .green = 0x34, .blue = 0x56 }, terminalTheme(value, &themes, false).cursor);
}

test "color scheme can follow or override the OS" {
    var value = Config{};
    try std.testing.expect(useDarkTheme(value, true));
    try std.testing.expect(!useDarkTheme(value, false));

    value.color_scheme = .light;
    try std.testing.expect(!useDarkTheme(value, true));
    value.color_scheme = .dark;
    try std.testing.expect(useDarkTheme(value, false));
}

test "zoom clamps to supported font bounds" {
    try std.testing.expectEqual(@as(u16, 6), clampZoom(6, -1));
    try std.testing.expectEqual(@as(u16, 72), clampZoom(72, 1));
    try std.testing.expectEqual(@as(u16, 19), clampZoom(18, 1));
}
