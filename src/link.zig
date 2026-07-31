const std = @import("std");

pub const Match = struct {
    start: usize,
    end: usize,
};

// Allow only known schemes because terminal text is untrusted. ShellExecuteW
// can invoke an arbitrary registered protocol handler.
const schemes = [_][]const u8{
    "http:", "https:",  "mailto:", "ftp:",  "file:",   "ssh:",    "git:",
    "tel:",  "magnet:", "ipfs:",   "ipns:", "gemini:", "gopher:", "news:",
};

pub fn detectAt(text: []const u8, offset: usize) ?Match {
    if (offset >= text.len or std.ascii.isWhitespace(text[offset])) return null;
    var start = offset;
    while (start > 0 and !std.ascii.isWhitespace(text[start - 1])) start -= 1;
    var end = offset + 1;
    while (end < text.len and !std.ascii.isWhitespace(text[end])) end += 1;

    while (start < end and std.mem.indexOfScalar(u8, "(<[{\"'", text[start]) != null) start += 1;
    while (end > start and std.mem.indexOfScalar(u8, ").,;:!?]>}\"'", text[end - 1]) != null) end -= 1;
    if (offset < start or offset >= end or !hasAllowedScheme(text[start..end])) return null;
    return .{ .start = start, .end = end };
}

pub fn hasAllowedScheme(uri: []const u8) bool {
    for (schemes) |scheme| {
        if (uri.len >= scheme.len and std.ascii.eqlIgnoreCase(uri[0..scheme.len], scheme)) return true;
    }
    return false;
}

test "detects supported URI beneath pointer and trims punctuation" {
    const text = "open (https://example.com/a), now";
    const match = detectAt(text, 12).?;
    try std.testing.expectEqualStrings("https://example.com/a", text[match.start..match.end]);
}

test "rejects bare domains and arbitrary OSC schemes" {
    try std.testing.expectEqual(@as(?Match, null), detectAt("www.example.com", 4));
    try std.testing.expect(!hasAllowedScheme("javascript:alert(1)"));
}
