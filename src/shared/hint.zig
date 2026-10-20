const std = @import("std");

pub const alphabet = "asdfghjkl";

pub const Label = extern struct {
    bytes: [8]u8 = @splat(0),
    length: u8 = 0,

    pub fn labelSlice(self: *const Label) []const u8 {
        return self.bytes[0..@min(self.length, self.bytes.len)];
    }
};

/// Offsets into the original ASCII label; a zero length still matches for
/// highlighting, but has no badge to draw.
pub const LabelSuffix = extern struct { offset: u8, length: u8 };

pub const Interaction = extern struct {
    prefix: [8]u8 = @splat(0),
    length: u8 = 0,

    pub const Result = union(enum) { ignored, changed, cancelled, no_match, selected: usize };

    /// Native adapters translate keys to ASCII, Escape (27), or Backspace (8).
    /// Selection uses the first exact match even when longer labels also match.
    pub fn key(self: *Interaction, candidates: anytype, value: u8) Result {
        if (value == 27) return .cancelled;
        if (value == 8) {
            self.length -|= 1;
            return .changed;
        }
        if (std.mem.indexOfScalar(u8, alphabet, value) == null or self.length >= self.prefix.len) return .ignored;
        self.prefix[self.length] = value;
        self.length += 1;
        var any = false;
        for (candidates, 0..) |candidate, index| {
            const suffix = self.visibleLabel(candidate) orelse continue;
            any = true;
            if (suffix.length == 0) return .{ .selected = index };
        }
        return if (any) .changed else .no_match;
    }

    pub fn visibleLabel(self: *const Interaction, candidate: anytype) ?LabelSuffix {
        const label = candidate.labelSlice();
        const prefix = self.prefix[0..@min(self.length, self.prefix.len)];
        if (!std.mem.startsWith(u8, label, prefix)) return null;
        return .{ .offset = @intCast(prefix.len), .length = @intCast(label.len - prefix.len) };
    }
};

/// Negative results are adapter actions; nonnegative results index the labels.
export fn zigonaut_hint_key(state: *Interaction, labels: ?[*]const Label, count: u32, value: u8) i32 {
    return switch (state.key(if (labels) |items| items[0..count] else &.{}, value)) {
        .ignored => -1,
        .changed => -2,
        .cancelled => -3,
        .no_match => -4,
        .selected => |index| @intCast(index),
    };
}

export fn zigonaut_hint_suffix(state: *const Interaction, label: *const Label, output: *LabelSuffix) bool {
    output.* = state.visibleLabel(label.*) orelse return false;
    return true;
}

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
    var interaction: Interaction = .{};
    try std.testing.expectEqual(@as(usize, 1), interaction.key(&candidates, 's').selected);
}

test "labels grow after the single-key alphabet" {
    var output: [8]u8 = @splat(0);
    try std.testing.expectEqualStrings("a", output[0..encodeLabel(0, &output)]);
    try std.testing.expectEqualStrings("l", output[0..encodeLabel(8, &output)]);
    try std.testing.expectEqualStrings("aa", output[0..encodeLabel(9, &output)]);
}

test "hint interaction selects exact labels, exposes suffixes and edits prefixes" {
    const labels = [_]Label{
        .{ .bytes = .{ 's', 'd', 0, 0, 0, 0, 0, 0 }, .length = 2 },
        .{ .bytes = .{ 's', 'a', 0, 0, 0, 0, 0, 0 }, .length = 2 },
        .{ .bytes = .{ 'a', 0, 0, 0, 0, 0, 0, 0 }, .length = 1 },
        .{ .bytes = .{ 'a', 's', 0, 0, 0, 0, 0, 0 }, .length = 2 },
    };
    var state: Interaction = .{};
    try std.testing.expectEqual(.ignored, state.key(&labels, 'x'));
    try std.testing.expectEqual(.changed, state.key(&labels, 's'));
    try std.testing.expectEqual(LabelSuffix{ .offset = 1, .length = 1 }, state.visibleLabel(labels[0]).?);
    try std.testing.expect(state.visibleLabel(labels[2]) == null);
    try std.testing.expectEqual(@as(usize, 1), state.key(&labels, 'a').selected);
    try std.testing.expectEqual(@as(u8, 0), state.visibleLabel(labels[1]).?.length);
    try std.testing.expectEqual(.changed, state.key(&labels, 8));
    try std.testing.expectEqual(.no_match, state.key(&labels, 'l'));
    try std.testing.expectEqual(.cancelled, state.key(&labels, 27));
    state = .{};
    try std.testing.expectEqual(.changed, state.key(&labels, 8));
    try std.testing.expectEqual(@as(usize, 2), state.key(&labels, 'a').selected);
}
