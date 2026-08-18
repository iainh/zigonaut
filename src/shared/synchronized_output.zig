const std = @import("std");

const timeout_ms: u64 = 1000;

pub const Watchdog = struct {
    deadline_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn update(self: *Watchdog, enabled: bool, now_ms: u64) bool {
        if (!enabled) return self.clear();
        const deadline = now_ms +| timeout_ms;
        return self.deadline_ms.cmpxchgStrong(0, deadline, .acq_rel, .acquire) == null;
    }

    pub fn remaining(self: *const Watchdog, now_ms: u64) ?u32 {
        const deadline = self.deadline_ms.load(.acquire);
        if (deadline == 0) return null;
        if (deadline <= now_ms) return 0;
        return @intCast(@min(deadline - now_ms, std.math.maxInt(u32)));
    }

    pub fn clear(self: *Watchdog) bool {
        return self.deadline_ms.swap(0, .acq_rel) != 0;
    }
};

test "watchdog arms once, expires, and clears" {
    var state = Watchdog{};
    try std.testing.expect(state.update(true, 100));
    try std.testing.expectEqual(@as(?u32, 1000), state.remaining(100));
    try std.testing.expect(!state.update(true, 500));
    try std.testing.expectEqual(@as(?u32, 600), state.remaining(500));
    try std.testing.expectEqual(@as(?u32, 0), state.remaining(1100));
    try std.testing.expect(state.clear());
    try std.testing.expectEqual(@as(?u32, null), state.remaining(1100));
    try std.testing.expect(!state.update(false, 1200));
}
