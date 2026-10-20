const std = @import("std");

fn Command(comptime T: type) type {
    return extern struct { tag: u32, x: T, y: T, c1x: T, c1y: T, c2x: T, c2y: T };
}

fn curly(comptime T: type, width: T, output: ?[*]Command(T), capacity: usize) usize {
    if (!std.math.isFinite(width) or width <= 0 or width > 65535) return 0;
    const cycles: usize = @intFromFloat(@max(1, @round(width / 8)));
    const segments = cycles * 2;
    if (capacity == 0) return segments + 1;
    const half_wave = width / @as(T, @floatFromInt(segments));
    output.?[0] = .{ .tag = 0, .x = 0, .y = 0, .c1x = 0, .c1y = 0, .c2x = 0, .c2y = 0 };
    var x: T = 0;
    var direction: T = 1;
    for (0..@min(segments, capacity - 1)) |segment| {
        const end = x + half_wave;
        output.?[segment + 1] = .{
            .tag = 1,
            .x = end,
            .y = 0,
            .c1x = x + half_wave / 3,
            .c1y = 2 * direction,
            .c2x = x + 2 * half_wave / 3,
            .c2y = 2 * direction,
        };
        x = end;
        direction *= -1;
    }
    return segments + 1;
}

pub export fn zigonaut_curly_underline_f32(width: f32, output: ?[*]Command(f32), capacity: usize) usize {
    return curly(f32, width, output, capacity);
}

pub export fn zigonaut_curly_underline_f64(width: f64, output: ?[*]Command(f64), capacity: usize) usize {
    return curly(f64, width, output, capacity);
}

test "curly commands retain native lobes and rounding boundary in both precisions" {
    inline for (.{ f32, f64 }) |T| {
        const generate = if (T == f32) zigonaut_curly_underline_f32 else zigonaut_curly_underline_f64;
        var commands: [6]Command(T) = undefined;
        try std.testing.expectEqual(@as(usize, 3), generate(11.99, null, 0));
        try std.testing.expectEqual(@as(usize, 5), generate(12, &commands, commands.len));
        try std.testing.expectEqual(@as(u32, 0), commands[0].tag);
        try std.testing.expectEqual(@as(T, 0), commands[0].x);
        try std.testing.expectEqualDeep(Command(T){ .tag = 1, .x = 3, .y = 0, .c1x = 1, .c1y = 2, .c2x = 2, .c2y = 2 }, commands[1]);
        try std.testing.expectEqualDeep(Command(T){ .tag = 1, .x = 6, .y = 0, .c1x = 4, .c1y = -2, .c2x = 5, .c2y = -2 }, commands[2]);
        try std.testing.expectEqual(@as(T, 12), commands[4].x);
        // A bounded write must not touch the next caller-owned record.
        commands[2].tag = 99;
        try std.testing.expectEqual(@as(usize, 5), generate(12, &commands, 2));
        try std.testing.expectEqual(@as(u32, 99), commands[2].tag);
        try std.testing.expectEqual(@as(usize, 3), generate(1, null, 0));
        try std.testing.expectEqual(@as(usize, 0), generate(0, null, 0));
        try std.testing.expectEqual(@as(usize, 0), generate(std.math.inf(T), null, 0));
    }
}
