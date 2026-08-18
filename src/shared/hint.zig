const std = @import("std");

pub const alphabet = "asdfghjkl";

pub const Candidate = struct {
    target: []u8,
    row: u16,
    start_column: u16,
    end_column: u16,
    label: [8]u8 = @splat(0),
    label_len: u8 = 0,

    pub fn labelSlice(self: *const Candidate) []const u8 {
        return self.label[0..self.label_len];
    }
};

pub fn deinitCandidates(allocator: std.mem.Allocator, candidates: []Candidate) void {
    for (candidates) |candidate| allocator.free(candidate.target);
    allocator.free(candidates);
}

/// Assigns the shortest labels to the newest visible targets. Duplicate targets
/// share a label, while every occurrence remains available for highlighting.
pub fn assignLabels(candidates: []Candidate) void {
    var next: usize = 0;
    var index = candidates.len;
    while (index > 0) {
        index -= 1;
        var existing: ?[]const u8 = null;
        for (candidates[index + 1 ..]) |candidate| {
            if (std.mem.eql(u8, candidate.target, candidates[index].target)) {
                existing = candidate.labelSlice();
                break;
            }
        }
        if (existing) |label| {
            @memcpy(candidates[index].label[0..label.len], label);
            candidates[index].label_len = @intCast(label.len);
            continue;
        }
        candidates[index].label_len = @intCast(encodeLabel(next, &candidates[index].label));
        next += 1;
    }
}

fn encodeLabel(value: usize, output: []u8) usize {
    var number = value;
    var length: usize = 1;
    var capacity = alphabet.len;
    while (number >= capacity and length < output.len) {
        number -= capacity;
        length += 1;
        capacity *= alphabet.len;
    }
    var position = length;
    while (position > 0) {
        position -= 1;
        output[position] = alphabet[number % alphabet.len];
        number /= alphabet.len;
    }
    return length;
}

pub fn matchesPrefix(candidate: Candidate, prefix: []const u8) bool {
    return std.mem.startsWith(u8, candidate.labelSlice(), prefix);
}

test "labels are shortest at the bottom and duplicates share keys" {
    var candidates = [_]Candidate{
        .{ .target = @constCast("old"), .row = 0, .start_column = 0, .end_column = 3 },
        .{ .target = @constCast("same"), .row = 1, .start_column = 0, .end_column = 4 },
        .{ .target = @constCast("same"), .row = 2, .start_column = 0, .end_column = 4 },
        .{ .target = @constCast("new"), .row = 3, .start_column = 0, .end_column = 3 },
    };
    assignLabels(&candidates);
    try std.testing.expectEqualStrings("a", candidates[3].labelSlice());
    try std.testing.expectEqualStrings("s", candidates[2].labelSlice());
    try std.testing.expectEqualStrings("s", candidates[1].labelSlice());
    try std.testing.expectEqualStrings("d", candidates[0].labelSlice());
    try std.testing.expect(matchesPrefix(candidates[1], "s"));
}

test "labels grow after the single-key alphabet" {
    var output: [8]u8 = @splat(0);
    try std.testing.expectEqualStrings("a", output[0..encodeLabel(0, &output)]);
    try std.testing.expectEqualStrings("l", output[0..encodeLabel(8, &output)]);
    try std.testing.expectEqualStrings("aa", output[0..encodeLabel(9, &output)]);
}
