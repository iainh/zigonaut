const std = @import("std");

pub const Match = struct { row: u32, start: u16, end: u16 };

pub const RowMatches = struct {
    matches: []const Match,
    start_index: usize,
};

pub const RowCursor = struct {
    matches: []const Match,
    index: usize = 0,

    pub fn init(matches: []const Match, first_row: u64) RowCursor {
        return .{ .matches = matches, .index = matchesForRow(matches, first_row).start_index };
    }

    pub fn next(self: *RowCursor, row: u64) RowMatches {
        while (self.index < self.matches.len and self.matches[self.index].row < row) self.index += 1;
        const start = self.index;
        while (self.index < self.matches.len and self.matches[self.index].row == row) self.index += 1;
        return .{ .matches = self.matches[start..self.index], .start_index = start };
    }
};

pub fn matchesForRow(matches: []const Match, row: u64) RowMatches {
    var low: usize = 0;
    var high = matches.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (matches[middle].row < row) low = middle + 1 else high = middle;
    }
    var end = low;
    while (end < matches.len and matches[end].row == row) end += 1;
    return .{ .matches = matches[low..end], .start_index = low };
}

pub fn highlightRow(row_matches: RowMatches, active: ?usize, column: u16) u2 {
    for (row_matches.matches, row_matches.start_index..) |match, index| {
        if (column >= match.start and column < match.end) return if (active == index) 2 else 1;
    }
    return 0;
}

pub fn highlight(matches: []const Match, active: ?usize, row: u64, column: u16) u2 {
    return highlightRow(matchesForRow(matches, row), active, column);
}

pub const State = struct {
    enabled: bool = false,
    query: std.ArrayList(u8) = .empty,
    matches: std.ArrayList(Match) = .empty,
    active: ?usize = null,
    scanning: bool = false,
    next_row: u32 = 0,
    scanned_generation: u64 = 0,
    saved_offset: ?u64 = null,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.matches.deinit(allocator);
    }

    pub fn reset(self: *State) void {
        self.matches.clearRetainingCapacity();
        self.active = null;
        self.next_row = 0;
        self.scanning = self.query.items.len != 0;
    }

    pub fn navigate(self: *State, forward: bool) ?Match {
        if (self.matches.items.len == 0) return null;
        const current = self.active orelse if (forward) self.matches.items.len - 1 else 0;
        self.active = if (forward)
            (current + 1) % self.matches.items.len
        else if (current == 0) self.matches.items.len - 1 else current - 1;
        return self.matches.items[self.active.?];
    }
};

test "search navigation wraps in both directions" {
    var state = State{};
    defer state.deinit(std.testing.allocator);
    try state.matches.append(std.testing.allocator, .{ .row = 2, .start = 1, .end = 3 });
    try state.matches.append(std.testing.allocator, .{ .row = 8, .start = 0, .end = 2 });
    try std.testing.expectEqual(@as(u32, 2), state.navigate(true).?.row);
    try std.testing.expectEqual(@as(u32, 8), state.navigate(true).?.row);
    try std.testing.expectEqual(@as(u32, 2), state.navigate(true).?.row);
    try std.testing.expectEqual(@as(u32, 8), state.navigate(false).?.row);
}

test "highlight finds a visible match without scanning earlier rows" {
    const matches = [_]Match{
        .{ .row = 2, .start = 1, .end = 3 },
        .{ .row = 8000, .start = 4, .end = 8 },
        .{ .row = 8000, .start = 10, .end = 12 },
    };
    try std.testing.expectEqual(@as(u2, 0), highlight(&matches, 2, 8000, 3));
    try std.testing.expectEqual(@as(u2, 1), highlight(&matches, 2, 8000, 5));
    try std.testing.expectEqual(@as(u2, 2), highlight(&matches, 2, 8000, 10));
}

test "row cursor advances through visible matches" {
    const matches = [_]Match{
        .{ .row = 2, .start = 1, .end = 3 },
        .{ .row = 8000, .start = 4, .end = 8 },
        .{ .row = 8000, .start = 10, .end = 12 },
        .{ .row = 8002, .start = 0, .end = 2 },
    };
    var cursor = RowCursor.init(&matches, 8000);
    const first = cursor.next(8000);
    try std.testing.expectEqual(@as(usize, 1), first.start_index);
    try std.testing.expectEqual(@as(usize, 2), first.matches.len);
    try std.testing.expectEqual(@as(usize, 0), cursor.next(8001).matches.len);
    try std.testing.expectEqual(@as(u16, 2), cursor.next(8002).matches[0].end);
}
