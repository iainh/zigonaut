const std = @import("std");

pub fn appendWindowsArgument(allocator: std.mem.Allocator, output: *std.ArrayList(u8), argument: []const u8) !void {
    try output.append(allocator, '"');
    var backslashes: usize = 0;
    for (argument) |byte| {
        if (byte == '\\') {
            backslashes += 1;
            continue;
        }
        const count = if (byte == '"') backslashes * 2 + 1 else backslashes;
        for (0..count) |_| try output.append(allocator, '\\');
        backslashes = 0;
        try output.append(allocator, byte);
    }
    for (0..backslashes * 2) |_| try output.append(allocator, '\\');
    try output.append(allocator, '"');
}

fn wellFormed(command: []const u8) bool {
    var quoted = false;
    var backslashes: usize = 0;
    for (command) |byte| {
        if (byte == '\\') {
            backslashes += 1;
            continue;
        }
        if (byte == '"' and backslashes % 2 == 0) quoted = !quoted;
        backslashes = 0;
    }
    return !quoted;
}

fn executableKind(path: []const u8) ?enum { powershell, pwsh } {
    const slash = std.mem.lastIndexOfAny(u8, path, "\\/");
    const name = if (slash) |index| path[index + 1 ..] else path;
    if (std.ascii.eqlIgnoreCase(name, "powershell") or std.ascii.eqlIgnoreCase(name, "powershell.exe")) return .powershell;
    if (std.ascii.eqlIgnoreCase(name, "pwsh") or std.ascii.eqlIgnoreCase(name, "pwsh.exe")) return .pwsh;
    return null;
}

pub fn planAlloc(allocator: std.mem.Allocator, command: []const u8, script_path: []const u8) !?[]u8 {
    if (command.len == 0 or script_path.len == 0 or !wellFormed(command)) return null;
    const wide = std.unicode.utf8ToUtf16LeAlloc(allocator, command) catch return null;
    defer allocator.free(wide);
    var iterator = try std.process.Args.Iterator.Windows.init(allocator, wide);
    defer iterator.deinit();
    const executable = iterator.next() orelse return null;
    const kind = executableKind(executable) orelse return null;

    var flags: [3][]const u8 = undefined;
    var flag_count: usize = 0;
    var no_logo = false;
    var no_profile = false;
    var login = false;
    while (iterator.next()) |argument| {
        if (std.ascii.eqlIgnoreCase(argument, "-NoLogo") and !no_logo) {
            no_logo = true;
        } else if (std.ascii.eqlIgnoreCase(argument, "-NoProfile") and !no_profile) {
            no_profile = true;
        } else if (std.ascii.eqlIgnoreCase(argument, "-Login") and kind == .pwsh and !login) {
            login = true;
        } else return null;
        flags[flag_count] = argument;
        flag_count += 1;
    }

    var quoted_path = std.ArrayList(u8).empty;
    defer quoted_path.deinit(allocator);
    for (script_path) |byte| {
        try quoted_path.append(allocator, byte);
        if (byte == '\'') try quoted_path.append(allocator, '\'');
    }
    const script = try std.fmt.allocPrint(allocator, "try {{ . '{s}' }} catch {{}}", .{quoted_path.items});
    defer allocator.free(script);

    var result = std.ArrayList(u8).empty;
    errdefer result.deinit(allocator);
    try appendWindowsArgument(allocator, &result, executable);
    for (flags[0..flag_count]) |flag| {
        try result.append(allocator, ' ');
        try appendWindowsArgument(allocator, &result, flag);
    }
    for ([_][]const u8{ "-NoExit", "-Command", script }) |argument| {
        try result.append(allocator, ' ');
        try appendWindowsArgument(allocator, &result, argument);
    }
    return try result.toOwnedSlice(allocator);
}

test "plans safe PowerShell commands" {
    const cases = [_][]const u8{
        "powershell.exe",
        "PowerShell -NoLogo -noprofile",
        "pwsh.exe -Login",
        "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\" -NoProfile -NoLogo -Login",
    };
    for (cases) |command| {
        const result = (try planAlloc(std.testing.allocator, command, "C:\\Program Files\\Zigonaut\\shell-integration\\zigonaut.ps1")).?;
        defer std.testing.allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "-NoExit") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "zigonaut.ps1") != null);
    }
}

test "rejects ambiguous PowerShell commands" {
    const cases = [_][]const u8{
        "powershell.exe -Command Get-Date",
        "pwsh.exe -File script.ps1",
        "powershell.exe -EncodedCommand ZQB4AGkAdAA=",
        "powershell.exe script.ps1",
        "powershell.exe -Unknown",
        "powershell.exe -NoLogo -NoLogo",
        "powershell.exe -Login",
        "\"C:\\Program Files\\PowerShell\\pwsh.exe -NoLogo",
        "cmd.exe",
    };
    for (cases) |command| try std.testing.expect((try planAlloc(std.testing.allocator, command, "C:\\zigonaut.ps1")) == null);
}

test "escapes apostrophes in the installed script path" {
    const result = (try planAlloc(std.testing.allocator, "pwsh", "C:\\Iain's Apps\\zigonaut.ps1")).?;
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "Iain''s Apps") != null);
}
