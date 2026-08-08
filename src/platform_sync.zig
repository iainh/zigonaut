const std = @import("std");

pub const Mutex = if (@import("builtin").os.tag == .windows) @import("win32.zig").Mutex else struct {
    value: std.atomic.Mutex = .unlocked,

    pub fn lock(self: *@This()) void {
        while (!self.value.tryLock()) std.atomic.spinLoopHint();
    }

    pub fn unlock(self: *@This()) void {
        self.value.unlock();
    }
};
