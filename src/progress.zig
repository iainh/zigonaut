const std = @import("std");

pub const State = enum {
    normal,
    error_state,
    indeterminate,
    paused,
};

pub const Report = struct {
    state: State,
    value: ?u8,
};

pub const Update = union(enum) {
    remove,
    report: Report,
};

pub fn resolvedValue(report: Report, previous: u8) u8 {
    return report.value orelse if (report.state == .normal) 0 else previous;
}

pub const Parser = struct {
    phase: Phase = .text,
    payload: [64]u8 = undefined,
    length: usize = 0,
    overflow: bool = false,

    const Phase = enum { text, escape, osc, osc_escape };

    pub fn feed(self: *Parser, bytes: []const u8) ?Update {
        var latest: ?Update = null;
        for (bytes) |byte| switch (self.phase) {
            .text => if (byte == 0x1b) {
                self.phase = .escape;
            },
            .escape => if (byte == ']') {
                self.beginOsc();
            } else {
                self.phase = if (byte == 0x1b) .escape else .text;
            },
            .osc => if (byte == 0x07 or byte == 0x9c) {
                if (self.finish()) |update| latest = update;
            } else if (byte == 0x1b) {
                self.phase = .osc_escape;
            } else {
                self.append(byte);
            },
            .osc_escape => if (byte == '\\') {
                if (self.finish()) |update| latest = update;
            } else {
                self.append(0x1b);
                self.append(byte);
                self.phase = .osc;
            },
        };
        return latest;
    }

    fn beginOsc(self: *Parser) void {
        self.phase = .osc;
        self.length = 0;
        self.overflow = false;
    }

    fn append(self: *Parser, byte: u8) void {
        if (self.length == self.payload.len) {
            self.overflow = true;
            return;
        }
        self.payload[self.length] = byte;
        self.length += 1;
    }

    fn finish(self: *Parser) ?Update {
        defer {
            self.phase = .text;
            self.length = 0;
            self.overflow = false;
        }
        if (self.overflow) return null;
        return parse(self.payload[0..self.length]);
    }
};

fn parse(payload: []const u8) ?Update {
    if (!std.mem.startsWith(u8, payload, "9;4;")) return null;
    var fields = std.mem.splitScalar(u8, payload[4..], ';');
    const state = fields.next() orelse return null;
    if (state.len != 1) return null;
    return switch (state[0]) {
        '0' => .remove,
        '1' => .{ .report = .{ .state = .normal, .value = parseValue(&fields) catch return null } },
        '2' => .{ .report = .{ .state = .error_state, .value = parseValue(&fields) catch return null } },
        '3' => .{ .report = .{ .state = .indeterminate, .value = null } },
        '4' => .{ .report = .{ .state = .paused, .value = parseValue(&fields) catch return null } },
        else => null,
    };
}

fn parseValue(fields: *std.mem.SplitIterator(u8, .scalar)) !?u8 {
    const field = fields.next() orelse return null;
    return @intCast(@min(try std.fmt.parseUnsigned(u16, field, 10), 100));
}

test "parses ConEmu progress states and clamps percentages" {
    var parser = Parser{};
    try std.testing.expectEqual(Update{ .report = .{ .state = .normal, .value = 47 } }, parser.feed("\x1b]9;4;1;47\x07").?);
    try std.testing.expectEqual(Update{ .report = .{ .state = .error_state, .value = 100 } }, parser.feed("\x1b]9;4;2;999\x1b\\").?);
    try std.testing.expectEqual(Update{ .report = .{ .state = .indeterminate, .value = null } }, parser.feed("\x1b]9;4;3\x9c").?);
    try std.testing.expectEqual(Update.remove, parser.feed("\x1b]9;4;0\x07").?);
}

test "progress parser survives split sequences and ignores other OSC" {
    var parser = Parser{};
    try std.testing.expect(parser.feed("text\x1b]9;4;") == null);
    try std.testing.expectEqual(Update{ .report = .{ .state = .paused, .value = 5 } }, parser.feed("4;5\x07tail").?);
    try std.testing.expect(parser.feed("\x1b]0;title\x07") == null);
}

test "UTF-8 continuation bytes do not start C1 OSC" {
    var parser = Parser{};
    try std.testing.expectEqual(Update{ .report = .{ .state = .normal, .value = 47 } }, parser.feed("quote \xe2\x80\x9d \x1b]9;4;1;47\x07").?);
}

test "omitted progress follows protocol state defaults" {
    try std.testing.expectEqual(@as(u8, 0), resolvedValue(.{ .state = .normal, .value = null }, 60));
    try std.testing.expectEqual(@as(u8, 60), resolvedValue(.{ .state = .paused, .value = null }, 60));
    try std.testing.expectEqual(@as(u8, 60), resolvedValue(.{ .state = .error_state, .value = null }, 60));
}
