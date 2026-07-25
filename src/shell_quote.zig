const std = @import("std");

pub const Shell = enum { powershell, wsl };

pub fn pathAlloc(allocator: std.mem.Allocator, path: []const u8, shell: Shell) ![]u8 {
    var normalized = std.ArrayList(u8).empty;
    defer normalized.deinit(allocator);
    if (shell == .wsl) {
        try appendWslPath(allocator, &normalized, path);
    } else {
        try normalized.appendSlice(allocator, path);
    }

    var quoted = std.ArrayList(u8).empty;
    errdefer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (normalized.items) |byte| {
        if (byte == '\'') {
            if (shell == .powershell) {
                try quoted.appendSlice(allocator, "''");
            } else {
                try quoted.appendSlice(allocator, "'\\''");
            }
        } else {
            try quoted.append(allocator, byte);
        }
    }
    try quoted.append(allocator, '\'');
    return quoted.toOwnedSlice(allocator);
}

fn appendWslPath(allocator: std.mem.Allocator, output: *std.ArrayList(u8), path: []const u8) !void {
    if (path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and isSeparator(path[2])) {
        try output.appendSlice(allocator, "/mnt/");
        try output.append(allocator, std.ascii.toLower(path[0]));
        for (path[2..]) |byte| try output.append(allocator, if (byte == '\\') '/' else byte);
        return;
    }
    for (path) |byte| try output.append(allocator, if (byte == '\\') '/' else byte);
}

fn isSeparator(byte: u8) bool {
    return byte == '\\' or byte == '/';
}

test "quotes PowerShell paths and embedded apostrophes" {
    const quoted = try pathAlloc(std.testing.allocator, "C:\\Users\\Iain's file.txt", .powershell);
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'C:\\Users\\Iain''s file.txt'", quoted);
}

test "converts drive paths and quotes apostrophes for WSL" {
    const quoted = try pathAlloc(std.testing.allocator, "D:\\My Files\\it's.txt", .wsl);
    defer std.testing.allocator.free(quoted);
    try std.testing.expectEqualStrings("'/mnt/d/My Files/it'\\''s.txt'", quoted);
}
