//! Match slices must stay sorted by row and then by start column. This order
//! lets row queries use binary search and forward-only cursors.

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

/// Integer-cell spans retain native traversal order, including overlapping wide
/// heads/tails. Highlight is opaque: native consumers may use a kind or colour.
pub const Span = extern struct {
    row: u32 = 0,
    start: u32 = 0,
    end: u32 = 0,
    highlight: u32 = 0,
};

/// Push a cell, returning a completed span when continuity breaks. Push a zero
/// highlight to flush (also at end of input). No allocation or pixel arithmetic.
pub export fn zigonaut_search_span_push(pending: *Span, row: u32, column: u32, width: u32, kind: u32, output: *Span) bool {
    const present = pending.highlight != 0;
    if (present and kind != 0 and pending.row == row and
        pending.end == column and pending.highlight == kind)
    {
        pending.end = column + width;
        return false;
    }
    if (present) output.* = pending.*;
    pending.* = .{ .row = row, .start = column, .end = column + width, .highlight = kind };
    return present;
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

test "search spans preserve gaps, kinds, rows and overlapping wide cells" {
    var pending = Span{};
    var output: Span = undefined;
    try std.testing.expect(!zigonaut_search_span_push(&pending, 3, 1, 2, 1, &output));
    try std.testing.expect(!zigonaut_search_span_push(&pending, 3, 3, 1, 1, &output));
    try std.testing.expect(zigonaut_search_span_push(&pending, 3, 4, 1, 2, &output));
    try std.testing.expectEqual(Span{ .row = 3, .start = 1, .end = 4, .highlight = 1 }, output);
    try std.testing.expect(zigonaut_search_span_push(&pending, 3, 6, 2, 2, &output));
    try std.testing.expectEqual(Span{ .row = 3, .start = 4, .end = 5, .highlight = 2 }, output);
    // A wide tail overlaps its head rather than extending it, as in native drawing.
    try std.testing.expect(zigonaut_search_span_push(&pending, 3, 7, 1, 2, &output));
    try std.testing.expectEqual(Span{ .row = 3, .start = 6, .end = 8, .highlight = 2 }, output);
    try std.testing.expect(zigonaut_search_span_push(&pending, 4, 8, 1, 2, &output));
    try std.testing.expectEqual(@as(u32, 3), output.row);
    try std.testing.expect(zigonaut_search_span_push(&pending, 0, 0, 0, 0, &output));
    try std.testing.expectEqual(Span{ .row = 4, .start = 8, .end = 9, .highlight = 2 }, output);
    try std.testing.expect(!zigonaut_search_span_push(&pending, 0, 0, 0, 0, &output));
}
