const std = @import("std");

/// Owned OSC 7501 records. Array order is least to most recently updated.
/// Limits match the pinned public protocol; no allocation depends on PTY text.
pub const Store = struct {
    pub const capacity = 64;
    pub const State = enum(u8) { idle, working, done, blocked, failed, clear };
    pub const Record = struct {
        state: State = .idle,
        kind: u8 = 0,
        progress: i8 = -1,
        id: Text(128) = .{},
        app: Text(32) = .{},
        title: Text(192) = .{},
        message: Text(2048) = .{},
    };
    records: [capacity]Record = @splat(.{}),
    count: usize = 0,
    generation: u64 = 0,

    pub fn put(self: *Store, state: State, kind: u8, progress: i8, id: []const u8, app: []const u8, title: []const u8, message: []const u8) void {
        if (state == .clear) {
            var i: usize = 0;
            while (i < self.count) {
                if (within(self.records[i].id.slice(), id)) self.remove(i) else i += 1;
            }
        } else {
            for (self.records[0..self.count], 0..) |record, i| {
                if (std.mem.eql(u8, record.id.slice(), id)) {
                    self.remove(i);
                    break;
                }
            }
            if (self.count == capacity) self.remove(0);
            self.records[self.count] = .{
                .state = state,
                .kind = kind,
                .progress = progress,
                .id = Text(128).copy(id),
                .app = Text(32).copy(app),
                .title = Text(192).copy(title),
                .message = Text(2048).copy(message),
            };
            self.count += 1;
        }
        self.generation +%= 1;
    }

    /// A prompt or process exit ends transient work, not unseen results.
    pub fn endProgram(self: *Store) void {
        self.prune(false);
    }

    /// Results remain available until the user next focuses this terminal.
    pub fn acknowledge(self: *Store) void {
        self.prune(true);
    }

    fn prune(self: *Store, results: bool) void {
        var i: usize = 0;
        var changed = false;
        while (i < self.count) {
            const state = self.records[i].state;
            const is_result = state == .done or state == .failed;
            if (is_result == results) {
                self.remove(i);
                changed = true;
            } else i += 1;
        }
        if (changed) self.generation +%= 1;
    }

    fn remove(self: *Store, index: usize) void {
        std.mem.copyForwards(Record, self.records[index .. self.count - 1], self.records[index + 1 .. self.count]);
        self.count -= 1;
    }

    pub fn get(self: *const Store, id: []const u8) ?*const Record {
        for (self.records[0..self.count]) |*record| {
            if (std.mem.eql(u8, record.id.slice(), id)) return record;
        }
        return null;
    }

    /// Resolve dynamically: replacing/clearing an ancestor changes inheritance.
    pub fn appFor(self: *const Store, record: *const Record) []const u8 {
        if (record.app.len != 0) return record.app.slice();
        var best: []const u8 = "";
        var depth: usize = 0;
        for (self.records[0..self.count]) |*ancestor| {
            const id = ancestor.id.slice();
            if (ancestor.app.len == 0 or !within(record.id.slice(), id)) continue;
            if (best.len == 0 or id.len > depth) {
                best = ancestor.app.slice();
                depth = id.len;
            }
        }
        return best;
    }

    /// Attention first, then completed results, then work. Newest wins ties.
    pub fn selected(self: *const Store) ?*const Record {
        var best: ?*const Record = null;
        for (self.records[0..self.count]) |*record| {
            if (best == null or priority(record.state) >= priority(best.?.state)) best = record;
        }
        return best;
    }

    pub fn label(self: *const Store, buffer: []u8) []const u8 {
        const record = self.selected() orelse return "";
        const state = switch (record.state) {
            .idle => "Idle",
            .working => "Working",
            .done => "Done",
            .blocked => switch (record.kind) {
                1 => "Approval needed",
                2 => "Answer needed",
                3 => "Authentication needed",
                else => "Blocked",
            },
            .failed => "Error",
            .clear => unreachable,
        };
        const title = record.title.slice();
        // Keep the badge short; the full safe message is retained in the record.
        var message_end = @min(record.message.len, 256);
        const message = record.message.slice();
        while (message_end < message.len and message_end > 0 and message[message_end] & 0xc0 == 0x80) message_end -= 1;
        var writer = std.Io.Writer.fixed(buffer);
        writer.writeAll(state) catch return state;
        if (record.progress >= 0) writer.print(" {d}%", .{record.progress}) catch return state;
        if (title.len != 0) writer.print(" · {s}", .{title}) catch return state;
        if (message_end != 0) writer.print(" — {s}", .{message[0..message_end]}) catch return state;
        const app = self.appFor(record);
        if (app.len != 0) writer.print(" (app: {s})", .{app}) catch return state;
        return writer.buffered();
    }
};

fn priority(state: Store.State) u8 {
    return switch (state) {
        .failed => 5,
        .blocked => 4,
        .done => 3,
        .working => 2,
        .idle => 1,
        .clear => 0,
    };
}

fn within(id: []const u8, parent: []const u8) bool {
    return parent.len == 0 or std.mem.eql(u8, id, parent) or
        (id.len > parent.len and std.mem.startsWith(u8, id, parent) and id[parent.len] == '/');
}

fn Text(comptime capacity: usize) type {
    return struct {
        bytes: [capacity]u8 = @splat(0),
        len: usize = 0,

        fn copy(input: []const u8) @This() {
            var result: @This() = .{};
            var iterator = (std.unicode.Utf8View.init(input) catch return result).iterator();
            while (iterator.nextCodepointSlice()) |encoded| {
                const cp = std.unicode.utf8Decode(encoded) catch continue;
                // Plain, single-line native text, without Unicode format controls
                // (including bidi overrides/isolates, zero-width and tag controls).
                if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f) or invisible(cp)) continue;
                if (result.len + encoded.len > capacity) break;
                @memcpy(result.bytes[result.len..][0..encoded.len], encoded);
                result.len += encoded.len;
            }
            return result;
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

fn invisible(cp: u21) bool {
    return switch (cp) {
        0x00ad,
        0x034f,
        0x061c,
        0x06dd,
        0x070f,
        0x08e2,
        0x180e,
        0xfeff,
        0x0600...0x0605,
        0x0890...0x0891,
        0x115f...0x1160,
        0x17b4...0x17b5,
        0x200b...0x200f,
        0x2028...0x202e,
        0x2060...0x206f,
        0xfff9...0xfffb,
        0x110bd,
        0x110cd,
        0x13430...0x1343f,
        0x1bca0...0x1bca3,
        0x1d173...0x1d17a,
        0xe0000...0xe0fff,
        => true,
        else => false,
    };
}
