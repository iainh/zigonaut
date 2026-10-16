const std = @import("std");

/// OSC 133 has no command IDs. A repeated start replaces the timer; a new
/// primary prompt/input or RIS abandons an incomplete command. Screen changes
/// do not affect this state. All times are from the same monotonic clock.
pub const State = struct {
    enabled: bool = false,
    started_ms: ?i64 = null,
    notified: bool = false,

    pub fn setEnabled(self: *State, enabled: bool) void {
        if (self.enabled != enabled) self.reset();
        self.enabled = enabled;
    }

    pub fn reset(self: *State) void {
        self.started_ms = null;
        self.notified = false;
    }

    pub fn start(self: *State, now_ms: i64) void {
        self.reset();
        if (self.enabled) self.started_ms = now_ms;
    }

    pub fn explicitNotification(self: *State) void {
        if (self.started_ms != null) self.notified = true;
    }

    /// Consume the completion even when focused, disabled or explicitly
    /// notified, so a repeated end cannot deliver an alert later.
    pub fn finish(self: *State, now_ms: i64, focused: bool) bool {
        const started = self.started_ms;
        const notified = self.notified;
        self.reset();
        return self.enabled and !focused and !notified and
            started != null and now_ms -| started.? >= 5000;
    }
};

test "completion requires opt-in, five elapsed seconds, and focus at completion" {
    var state = State{};
    state.start(100);
    try std.testing.expect(!state.finish(10_000, false));
    state.setEnabled(true);
    for ([_]i64{ 4999, 5000, 5001 }) |elapsed| {
        state.start(123);
        try std.testing.expectEqual(elapsed >= 5000, state.finish(123 + elapsed, false));
        try std.testing.expect(!state.finish(20_000, false));
    }
    state.start(500);
    try std.testing.expect(!state.finish(6000, true));
    try std.testing.expect(!state.finish(9000, false));
    state.start(7000);
    try std.testing.expect(state.finish(12_000, false));
}

test "incomplete, repeated, explicitly notified and reset commands do not leak timers" {
    var state = State{ .enabled = true };
    try std.testing.expect(!state.finish(10_000, false));
    state.start(100);
    state.start(4900);
    try std.testing.expect(!state.finish(5100, false));
    state.start(5200);
    state.explicitNotification();
    try std.testing.expect(!state.finish(11_000, false));
    state.start(12_000);
    state.reset();
    try std.testing.expect(!state.finish(18_000, false));
    state.start(19_000);
    state.setEnabled(false);
    state.setEnabled(true);
    try std.testing.expect(!state.finish(30_000, false));
    state.start(31_000);
    state.setEnabled(true); // Reapplying settings must not cancel a command.
    try std.testing.expect(state.finish(36_000, false));
}
