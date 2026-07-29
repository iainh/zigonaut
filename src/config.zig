const std = @import("std");
const win32 = @import("win32.zig");
const theme = @import("theme.zig");

pub const default_contents =
    \\{
    \\  "version": 1,
    \\  "appearance": {
    \\    "font": { "family": "Cascadia Mono", "size": 18 },
    \\    "themes": { "dark": "rasmus", "light": "campbell-light", "colorScheme": "system" },
    \\    "padding": { "horizontal": 8, "vertical": 8 },
    \\    "background": { "opacity": 100, "backdrop": "mica" },
    \\    "palette": {},
    \\    "randomizeTabBackground": true
    \\  },
    \\  "terminal": {
    \\    "scrollbackSize": 10000,
    \\    "initialSize": { "columns": 80, "rows": 24 }
    \\  },
    \\  "profiles": {
    \\    "default": "PowerShell",
    \\    "items": [
    \\      { "name": "PowerShell", "shell": "powershell", "command": "powershell.exe" },
    \\      { "name": "WSL", "shell": "wsl", "command": "wsl.exe" },
    \\      { "name": "Command Prompt", "shell": "windows", "command": "cmd.exe" }
    \\    ],
    \\    "workingDirectory": "",
    \\    "holdOnExit": false
    \\  },
    \\  "advanced": {
    \\    "clipboard": { "terminalWrites": false, "maximumBytes": 1048576 },
    \\    "pipeCommandOutput": ""
    \\  }
    \\}
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

const default_profiles = [3]Profile{
    .{ .name = "PowerShell", .shell = .powershell, .command = "powershell.exe" },
    .{ .name = "WSL", .shell = .wsl, .command = "wsl.exe" },
    .{ .name = "Command Prompt", .shell = .windows, .command = "cmd.exe" },
} ++ [_]Profile{.{ .name = "", .shell = .windows, .command = "" }} ** (max_profiles - 3);

pub const Backdrop = enum { none, mica, acrylic, mica_alt };
pub const ColorScheme = enum { system, light, dark };

const JsonProfile = struct {
    name: []const u8,
    shell: Shell,
    command: []const u8,
};

const JsonConfig = struct {
    version: u32,
    appearance: struct {
        font: struct {
            family: []const u8,
            size: u16,
        },
        themes: struct {
            dark: []const u8,
            light: []const u8,
            colorScheme: ColorScheme,
        },
        padding: struct {
            horizontal: u16,
            vertical: u16,
        },
        background: struct {
            opacity: u8,
            backdrop: Backdrop,
        },
        palette: struct {
            foreground: ?[]const u8 = null,
            background: ?[]const u8 = null,
            cursor: ?[]const u8 = null,
            ansi: ?[16]?[]const u8 = null,
        },
        randomizeTabBackground: bool,
    },
    terminal: struct {
        scrollbackSize: u32,
        initialSize: struct {
            columns: u16,
            rows: u16,
        },
    },
    profiles: struct {
        @"default": []const u8,
        items: []const JsonProfile,
        workingDirectory: []const u8,
        holdOnExit: bool,
    },
    advanced: struct {
        clipboard: struct {
            terminalWrites: bool,
            maximumBytes: u32,
        },
        pipeCommandOutput: []const u8,
    },
};

pub const Config = struct {
    font_family: []const u8 = "Cascadia Mono",
    font_size: u16 = 18,
    scrollback_size: u32 = 10_000,
    initial_columns: u16 = 80,
    initial_rows: u16 = 24,
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
    profile_count: usize = 3,
    working_directory: []const u8 = "",
    hold_on_exit: bool = false,
    randomize_tab_background: bool = true,
    osc52_clipboard_write: bool = false,
    osc52_clipboard_max_bytes: u32 = 1024 * 1024,
    pipe_command_output: []const u8 = "",

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

/// Owns the parsed JSON and file contents backing string fields in `value`.
/// Keep this object alive for as long as its `Config` is in use.
pub const Loaded = struct {
    allocator: std.mem.Allocator,
    contents: []u8,
    parsed: std.json.Parsed(JsonConfig),
    value: Config,

    pub fn deinit(self: *Loaded) void {
        self.parsed.deinit();
        self.allocator.free(self.contents);
    }
};

/// Returns the absolute configuration path owned by the caller.
pub fn pathAlloc(allocator: std.mem.Allocator) ![]u8 {
    const app_data = try win32.environmentVariableAlloc(allocator, "APPDATA");
    defer allocator.free(app_data);
    return std.fs.path.join(allocator, &.{ app_data, "spiralpoint", "zigonaut", "zigonaut.json" });
}

pub fn loadOrCreate(allocator: std.mem.Allocator, io: std.Io) !Loaded {
    const path = try pathAlloc(allocator);
    defer allocator.free(path);
    const directory = std.fs.path.dirname(path) orelse return error.InvalidConfigPath;

    try std.Io.Dir.cwd().createDirPath(io, directory);
    var file = std.Io.Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => create: {
            var created = try std.Io.Dir.createFileAbsolute(io, path, .{});
            try created.writeStreamingAll(io, default_contents);
            created.close(io);
            break :create try std.Io.Dir.openFileAbsolute(io, path, .{});
        },
        else => return err,
    };
    defer file.close(io);

    const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024));
    errdefer allocator.free(contents);
    var parsed = try std.json.parseFromSlice(JsonConfig, allocator, contents, .{ .ignore_unknown_fields = true });
    errdefer parsed.deinit();
    return .{
        .allocator = allocator,
        .contents = contents,
        .value = try configFromJson(parsed.value),
        .parsed = parsed,
    };
}

fn configFromJson(json: JsonConfig) !Config {
    if (json.version != 1) return error.UnsupportedConfigVersion;
    if (json.appearance.font.family.len == 0 or json.appearance.font.family.len >= 128 or
        json.appearance.font.size < 6 or json.appearance.font.size > 72 or
        json.terminal.scrollbackSize > 1_000_000 or
        json.terminal.initialSize.columns < 10 or json.terminal.initialSize.columns > 1000 or
        json.terminal.initialSize.rows < 4 or json.terminal.initialSize.rows > 1000 or
        json.appearance.themes.dark.len == 0 or json.appearance.themes.dark.len >= 64 or
        json.appearance.themes.light.len == 0 or json.appearance.themes.light.len >= 64 or
        json.appearance.padding.horizontal > 128 or json.appearance.padding.vertical > 128 or
        json.appearance.background.opacity > 100 or
        json.profiles.@"default".len == 0 or json.profiles.@"default".len >= 128 or
        json.profiles.items.len == 0 or json.profiles.items.len > max_profiles or
        json.advanced.clipboard.maximumBytes < 1 or json.advanced.clipboard.maximumBytes > 16 * 1024 * 1024 or
        json.advanced.pipeCommandOutput.len >= 4096 or
        std.mem.indexOfScalar(u8, json.advanced.pipeCommandOutput, 0) != null)
        return error.InvalidConfig;

    var result = Config{};
    result.font_family = json.appearance.font.family;
    result.font_size = json.appearance.font.size;
    result.scrollback_size = json.terminal.scrollbackSize;
    result.initial_columns = json.terminal.initialSize.columns;
    result.initial_rows = json.terminal.initialSize.rows;
    result.dark_theme = json.appearance.themes.dark;
    result.light_theme = json.appearance.themes.light;
    result.color_scheme = json.appearance.themes.colorScheme;
    result.padding_horizontal = json.appearance.padding.horizontal;
    result.padding_vertical = json.appearance.padding.vertical;
    result.background_opacity = json.appearance.background.opacity;
    result.backdrop = json.appearance.background.backdrop;
    result.randomize_tab_background = json.appearance.randomizeTabBackground;
    result.default_profile = json.profiles.@"default";
    result.profile_count = 0;
    for (json.profiles.items) |profile| {
        if (profile.name.len == 0 or profile.name.len >= 128 or profile.command.len == 0 or
            !std.unicode.utf8ValidateSlice(profile.name) or !std.unicode.utf8ValidateSlice(profile.command) or
            std.mem.indexOfScalar(u8, profile.name, '|') != null or
            std.mem.indexOfScalar(u8, profile.name, '\r') != null or
            std.mem.indexOfScalar(u8, profile.name, '\n') != null or
            std.mem.indexOfScalar(u8, profile.command, '\r') != null or
            std.mem.indexOfScalar(u8, profile.command, '\n') != null or
            std.mem.indexOfScalar(u8, profile.command, 0) != null)
            return error.InvalidProfile;
        for (result.profiles[0..result.profile_count]) |existing| {
            if (std.ascii.eqlIgnoreCase(existing.name, profile.name)) return error.DuplicateProfile;
        }
        result.profiles[result.profile_count] = .{ .name = profile.name, .shell = profile.shell, .command = profile.command };
        result.profile_count += 1;
    }
    var found_default = false;
    for (result.profileSlice()) |profile| {
        if (std.ascii.eqlIgnoreCase(profile.name, result.default_profile)) found_default = true;
    }
    if (!found_default) return error.InvalidDefaultProfile;
    result.working_directory = json.profiles.workingDirectory;
    result.hold_on_exit = json.profiles.holdOnExit;
    result.osc52_clipboard_write = json.advanced.clipboard.terminalWrites;
    result.osc52_clipboard_max_bytes = json.advanced.clipboard.maximumBytes;
    result.pipe_command_output = json.advanced.pipeCommandOutput;
    if (json.appearance.palette.foreground) |color| result.palette.foreground = theme.parseColor(color) orelse return error.InvalidColor;
    if (json.appearance.palette.background) |color| result.palette.background = theme.parseColor(color) orelse return error.InvalidColor;
    if (json.appearance.palette.cursor) |color| result.palette.cursor = theme.parseColor(color) orelse return error.InvalidColor;
    if (json.appearance.palette.ansi) |colors| {
        for (colors, 0..) |color, index| {
            if (color) |value| result.palette.ansi[index] = theme.parseColor(value) orelse return error.InvalidColor;
        }
    }
    return result;
}

test "configuration parses structured JSON" {
    var parsed = try std.json.parseFromSlice(JsonConfig, std.testing.allocator,
        \\{
        \\  "version": 1,
        \\  "appearance": {
        \\    "font": { "family": "JetBrains Mono", "size": 14 },
        \\    "themes": { "dark": "campbell", "light": "campbell-light", "colorScheme": "light" },
        \\    "padding": { "horizontal": 12, "vertical": 4 },
        \\    "background": { "opacity": 82, "backdrop": "acrylic" },
        \\    "palette": { "ansi": ["#000000", null, null, null, null, null, null, null, null, null, null, null, null, null, null, "#abcdef"] },
        \\    "randomizeTabBackground": false
        \\  },
        \\  "terminal": { "scrollbackSize": 50000, "initialSize": { "columns": 120, "rows": 40 } },
        \\  "profiles": {
        \\    "default": "Dev Shell",
        \\    "items": [
        \\      { "name": "Dev Shell", "shell": "windows", "command": "tool.exe --flag" },
        \\      { "name": "Linux", "shell": "wsl", "command": "ubuntu.exe" }
        \\    ],
        \\    "workingDirectory": "C:\\work",
        \\    "holdOnExit": true
        \\  },
        \\  "advanced": { "clipboard": { "terminalWrites": true, "maximumBytes": 65536 }, "pipeCommandOutput": "jq . > latest.json" }
        \\}
    , .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = try configFromJson(parsed.value);
    try std.testing.expectEqualStrings("JetBrains Mono", value.font_family);
    try std.testing.expectEqual(@as(u16, 14), value.font_size);
    try std.testing.expectEqual(@as(u32, 50_000), value.scrollback_size);
    try std.testing.expectEqual(@as(u16, 120), value.initial_columns);
    try std.testing.expectEqual(@as(u16, 40), value.initial_rows);
    try std.testing.expectEqual(ColorScheme.light, value.color_scheme);
    try std.testing.expectEqual(Backdrop.acrylic, value.backdrop);
    try std.testing.expectEqual(theme.Color{ .red = 0xab, .green = 0xcd, .blue = 0xef }, value.palette.ansi[15].?);
    try std.testing.expectEqualStrings("Dev Shell", value.defaultProfile().name);
    try std.testing.expectEqual(@as(usize, 2), value.profile_count);
    try std.testing.expectEqualStrings("C:\\work", value.working_directory);
    try std.testing.expect(value.hold_on_exit);
    try std.testing.expect(!value.randomize_tab_background);
    try std.testing.expect(value.osc52_clipboard_write);
    try std.testing.expectEqual(@as(u32, 65536), value.osc52_clipboard_max_bytes);
    try std.testing.expectEqualStrings("jq . > latest.json", value.pipe_command_output);
}

test "default JSON configuration parses" {
    var parsed = try std.json.parseFromSlice(JsonConfig, std.testing.allocator, default_contents, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const value = try configFromJson(parsed.value);
    try std.testing.expectEqual(@as(usize, 3), value.profile_count);
    try std.testing.expectEqualStrings("PowerShell", value.defaultProfile().name);
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
