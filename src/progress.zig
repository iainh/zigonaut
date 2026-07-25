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
    notification: Notification,
};

pub const Notification = struct { title: []const u8, body: []const u8 };

pub fn resolvedValue(report: Report, previous: u8) u8 {
    return report.value orelse if (report.state == .normal) 0 else previous;
}

pub const Parser = struct {
    phase: Phase = .text,
    payload: [4096]u8 = undefined,
    length: usize = 0,
    overflow: bool = false,

    const Phase = enum { text, escape, osc, osc_escape };

    pub fn feed(self: *Parser, bytes: []const u8) ?Update {
        var latest: ?Update = null;
        for (bytes) |byte| {
            if (self.feedByte(byte)) |update| latest = update;
        }
        return latest;
    }

    pub fn feedByte(self: *Parser, byte: u8) ?Update {
        return switch (self.phase) {
            .text => if (byte == 0x1b) {
                self.phase = .escape;
                return null;
            } else null,
            .escape => if (byte == ']') {
                self.beginOsc();
                return null;
            } else {
                self.phase = if (byte == 0x1b) .escape else .text;
                return null;
            },
            .osc => if (byte == 0x07 or byte == 0x9c) {
                return self.finish();
            } else if (byte == 0x1b) {
                self.phase = .osc_escape;
                return null;
            } else {
                self.append(byte);
                return null;
            },
            .osc_escape => if (byte == '\\') {
                return self.finish();
            } else {
                self.append(0x1b);
                self.append(byte);
                self.phase = .osc;
                return null;
            },
        };
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
    if (parseProgress(payload)) |update| return update;
    if (std.mem.startsWith(u8, payload, "777;notify;")) {
        const content = payload[11..];
        const separator = std.mem.indexOfScalar(u8, content, ';') orelse return null;
        return .{ .notification = .{ .title = content[0..separator], .body = content[separator + 1 ..] } };
    }
    if (std.mem.startsWith(u8, payload, "9;") and !isConEmu(payload[2..])) {
        return .{ .notification = .{ .title = "", .body = payload[2..] } };
    }
    return null;
}

fn parseProgress(payload: []const u8) ?Update {
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

fn isConEmu(body: []const u8) bool {
    if (std.mem.startsWith(u8, body, "1;") or std.mem.startsWith(u8, body, "2;") or
        std.mem.startsWith(u8, body, "3;") or std.mem.startsWith(u8, body, "6;") or
        std.mem.startsWith(u8, body, "7;") or std.mem.startsWith(u8, body, "8;") or
        std.mem.startsWith(u8, body, "9;") or std.mem.startsWith(u8, body, "11;")) return true;
    if (body.len > 0 and (body[0] == '5' or std.mem.startsWith(u8, body, "12"))) return true;
    return std.mem.eql(u8, body, "10") or
        (body.len == 4 and std.mem.startsWith(u8, body, "10;") and body[3] >= '0' and body[3] <= '3');
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

test "parses OSC 9 and OSC 777 notifications" {
    var parser = Parser{};
    const simple = parser.feed("\x1b]9;build finished\x07").?.notification;
    try std.testing.expectEqualStrings("", simple.title);
    try std.testing.expectEqualStrings("build finished", simple.body);
    const titled = parser.feed("\x1b]777;notify;Build;finished; successfully\x1b\\").?.notification;
    try std.testing.expectEqualStrings("Build", titled.title);
    try std.testing.expectEqualStrings("finished; successfully", titled.body);
    try std.testing.expect(parser.feed("\x1b]9;2;ConEmu message box\x07") == null);
    try std.testing.expectEqualStrings("4;5", parser.feed("\x1b]9;4;5\x07").?.notification.body);
    try std.testing.expectEqualStrings("10;4", parser.feed("\x1b]9;10;4\x07").?.notification.body);
    try std.testing.expect(parser.feed("\x1b]9;5\x07") == null);
    try std.testing.expect(parser.feed("\x1b]9;12\x07") == null);
}
