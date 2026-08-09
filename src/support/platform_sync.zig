const std = @import("std");

pub const Mutex = struct {
    value: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(self: *@This()) void {
        std.debug.assert(std.c.pthread_mutex_lock(&self.value) == .SUCCESS);
    }

    pub fn unlock(self: *@This()) void {
        std.debug.assert(std.c.pthread_mutex_unlock(&self.value) == .SUCCESS);
    }
};
