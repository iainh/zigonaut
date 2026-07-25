const std = @import("std");

pub const Match = struct { row: u32, start: u16, end: u16 };

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
