//! Allocation-free selection outlines. Native consumers own command storage
//! and path construction. The two entry points deliberately retain the native
//! arithmetic precision, boundary evaluation order and redundant line segments.
const std = @import("std");

pub const Line = extern struct { row: i64, start_column: i64, end_column: i64 };
pub const Interval = extern struct { start: u32, end: u32, active: u32 };
pub const Command = extern struct { tag: u32, reserved: u32 = 0, x: f64 = 0, y: f64 = 0, cx: f64 = 0, cy: f64 = 0 };
pub const CommandF32 = extern struct { tag: u32, x: f32 = 0, y: f32 = 0, cx: f32 = 0, cy: f32 = 0 };

fn Writer(comptime C: type) type {
    return struct {
        output: ?[*]C,
        capacity: usize,
        count: usize = 0,

        fn emit(self: *@This(), command: C) void {
            if (self.count < self.capacity) self.output.?[self.count] = command;
            self.count += 1;
        }
    };
}

fn Outline(comptime T: type, comptime windows: bool) type {
    return struct {
        const C = if (windows) CommandF32 else Command;
        const Edge = struct { left: T, right: T, top: T };

        fn line(writer: *Writer(C), x: T, y: T) void {
            writer.emit(.{ .tag = 1, .x = x, .y = y });
        }

        fn curve(writer: *Writer(C), cx: T, cy: T, x: T, y: T) void {
            writer.emit(.{ .tag = 2, .x = x, .y = y, .cx = cx, .cy = cy });
        }

        fn radius(width: T, height: T) T {
            return @min(height * 0.15, width * 0.25);
        }

        fn edge(value: anytype, origin_x: T, origin_y: T, width: T, height: T) Edge {
            if (windows) return value;
            return .{
                .left = origin_x + @as(T, @floatFromInt(value.start_column)) * width,
                .right = origin_x + @as(T, @floatFromInt(value.end_column)) * width,
                .top = origin_y + @as(T, @floatFromInt(value.row)) * height,
            };
        }

        fn component(writer: *Writer(C), lines: anytype, rows: i64, origin_x: T, origin_y: T, width: T, height: T, clip_top: bool, clip_bottom: bool) void {
            // Do not contract multiply/add: Windows and CGFloat callers rely on
            // rounding each operation, particularly at fractional scroll offsets.
            @setFloatMode(.strict);
            const r = radius(width, height);
            const vr = if (windows) @min(r, height * 0.5) else r;
            const first = edge(lines[0], origin_x, origin_y, width, height);
            const last = edge(lines[lines.len - 1], origin_x, origin_y, width, height);
            const first_width = if (windows) first.right - first.left else @abs(first.right - first.left);
            const last_width = if (windows) last.right - last.left else @abs(last.right - last.left);
            const tr = if (clip_top) 0 else @min(r, first_width * 0.5);
            const br = if (clip_bottom) 0 else @min(r, last_width * 0.5);
            const tv = if (clip_top) 0 else vr;
            const bv = if (clip_bottom) 0 else vr;
            writer.emit(.{ .tag = 0, .x = first.right - tr, .y = first.top });
            if (windows) {
                if (!clip_top) curve(writer, first.right, first.top, first.right, first.top + tv);
            } else if (tr > 0) {
                curve(writer, first.right, first.top, first.right, first.top + tv);
            } else line(writer, first.right, first.top);

            var forward: usize = 0;
            while (forward + 1 < lines.len) {
                const i = forward;
                forward += 1;
                if (!windows) while (!valid(lines[forward], rows)) {
                    forward += 1;
                };
                const upper = edge(lines[i], origin_x, origin_y, width, height);
                const lower = edge(lines[forward], origin_x, origin_y, width, height);
                const boundary = if (windows) lower.top else upper.top + height;
                if (!windows or upper.right != lower.right) line(writer, upper.right, boundary - vr);
                if (upper.right == lower.right) {
                    line(writer, lower.right, boundary);
                } else {
                    const direction: T = if (lower.right > upper.right) 1 else -1;
                    const hr = @min(r, @abs(lower.right - upper.right) * 0.5);
                    curve(writer, upper.right, boundary, upper.right + direction * hr, boundary);
                    line(writer, lower.right - direction * hr, boundary);
                    curve(writer, lower.right, boundary, lower.right, boundary + vr);
                }
            }
            const bottom = last.top + height;
            if (windows and clip_bottom) {
                line(writer, last.right, bottom);
                line(writer, last.left, bottom);
            } else {
                line(writer, last.right, bottom - bv);
                if (br > 0 or (windows and !clip_bottom)) {
                    curve(writer, last.right, bottom, last.right - br, bottom);
                } else line(writer, last.right, bottom);
                line(writer, last.left + br, bottom);
                if (br > 0 or (windows and !clip_bottom)) {
                    curve(writer, last.left, bottom, last.left, bottom - bv);
                } else line(writer, last.left, bottom);
            }
            var i = lines.len - 1;
            while (i > 0) {
                const lower = edge(lines[i], origin_x, origin_y, width, height);
                i -= 1;
                if (!windows) while (!valid(lines[i], rows)) {
                    i -= 1;
                };
                const upper = edge(lines[i], origin_x, origin_y, width, height);
                const boundary = lower.top;
                if (!windows or lower.left != upper.left) line(writer, lower.left, boundary + vr);
                if (lower.left == upper.left) {
                    line(writer, upper.left, boundary);
                } else {
                    const direction: T = if (upper.left > lower.left) 1 else -1;
                    const hr = @min(r, @abs(upper.left - lower.left) * 0.5);
                    curve(writer, lower.left, boundary, lower.left + direction * hr, boundary);
                    line(writer, upper.left - direction * hr, boundary);
                    curve(writer, upper.left, boundary, upper.left, boundary - vr);
                }
            }
            line(writer, first.left, if (windows and clip_top) first.top else first.top + tv);
            if (windows) {
                if (!clip_top) curve(writer, first.left, first.top, first.left + tr, first.top);
            } else if (tr > 0) {
                curve(writer, first.left, first.top, first.left + tr, first.top);
            } else line(writer, first.left, first.top);
            writer.emit(.{ .tag = 3 });
        }
    };
}

fn valid(line: Line, rows: i64) bool {
    return line.row >= 0 and line.row < rows and line.start_column < line.end_column;
}

fn connected(a: Line, b: Line) bool {
    return b.row - a.row == 1 and @max(a.start_column, b.start_column) < @min(a.end_column, b.end_column);
}

pub export fn zigonaut_selection_path(lines: ?[*]const Line, line_count: usize, row_count: i64, origin_x: f64, origin_y: f64, cell_width: f64, line_height: f64, output: ?[*]Command, capacity: usize) usize {
    @setFloatMode(.strict);
    if (row_count <= 0 or !(cell_width > 0) or !(line_height > 0) or line_count == 0) return 0;
    var writer: Writer(Command) = .{ .output = output, .capacity = capacity };
    // Components can contain invalid input rows. Stream their valid edges using
    // an iterator, rather than allocating a filtered copy or component arrays.
    const input = lines.?[0..line_count];
    var begin: usize = 0;
    while (begin < input.len) {
        if (!valid(input[begin], row_count)) {
            begin += 1;
            continue;
        }
        var end = begin + 1;
        var previous = begin;
        while (end < input.len) : (end += 1) {
            if (!valid(input[end], row_count)) continue;
            if (!connected(input[previous], input[end])) break;
            previous = end;
        }
        Outline(f64, false).component(&writer, input[begin .. previous + 1], row_count, origin_x, origin_y, cell_width, line_height, input[begin].row == 0, input[previous].row == row_count - 1);
        begin = end;
    }
    return writer.count;
}

fn overlaps(a: Interval, b: Interval) bool {
    return a.active != 0 and b.active != 0 and @max(a.start, b.start) < @min(a.end, b.end);
}

pub export fn zigonaut_selection_row_path(intervals: [*]const Interval, origin_x: f32, top: f32, cell_width: f32, cell_height: f32, top_clipped: u8, bottom_clipped: u8, output: ?[*]CommandF32, capacity: usize) usize {
    @setFloatMode(.strict);
    if (intervals[1].active == 0 or cell_width <= 0 or cell_height <= 0) return 0;
    var lines: [3]Outline(f32, true).Edge = undefined;
    var count: usize = 0;
    for (0..3) |i| {
        if (i != 1 and !overlaps(intervals[i], intervals[1])) continue;
        lines[count] = .{
            .left = origin_x + @as(f32, @floatFromInt(intervals[i].start)) * cell_width,
            .right = origin_x + @as(f32, @floatFromInt(intervals[i].end)) * cell_width,
            .top = switch (i) {
                0 => top - cell_height,
                1 => top,
                else => top + cell_height,
            },
        };
        count += 1;
    }
    var writer: Writer(CommandF32) = .{ .output = output, .capacity = capacity };
    Outline(f32, true).component(&writer, lines[0..count], 0, origin_x, top, cell_width, cell_height, top_clipped != 0 and lines[0].top == top, bottom_clipped != 0 and lines[count - 1].top == top);
    return writer.count;
}

test "caller-owned command capacity supports sizing and bounded writes" {
    const lines = [_]Line{
        .{ .row = 1, .start_column = 3, .end_column = 8 },
        .{ .row = 2, .start_column = 0, .end_column = 5 },
        .{ .row = 3, .start_column = 5, .end_column = 7 },
    };
    const required = zigonaut_selection_path(&lines, lines.len, 5, 0.25, -3.75, 8.5, 19.25, null, 0);
    try std.testing.expectEqual(26, required);
    var output: [28]Command = @splat(.{ .tag = 99 });
    try std.testing.expectEqual(required, zigonaut_selection_path(&lines, lines.len, 5, 0.25, -3.75, 8.5, 19.25, &output, 1));
    try std.testing.expectEqual(0, output[0].tag);
    try std.testing.expectEqual(99, output[1].tag);
    try std.testing.expectEqual(required, zigonaut_selection_path(&lines, lines.len, 5, 0.25, -3.75, 8.5, 19.25, &output, 27));
    try std.testing.expectEqual(3, output[required - 1].tag);
    try std.testing.expectEqual(99, output[27].tag);

    const intervals = [_]Interval{
        .{ .start = 0, .end = 4, .active = 1 },
        .{ .start = 2, .end = 4, .active = 1 },
        .{ .start = 3, .end = 8, .active = 1 },
    };
    const row_required = zigonaut_selection_row_path(&intervals, 0, 20, 10, 20, 1, 1, null, 0);
    var row_output: [28]CommandF32 = @splat(.{ .tag = 99 });
    try std.testing.expect(row_required <= 27);
    try std.testing.expectEqual(row_required, zigonaut_selection_row_path(&intervals, 0, 20, 10, 20, 1, 1, &row_output, 1));
    try std.testing.expectEqual(99, row_output[1].tag);
    try std.testing.expectEqual(row_required, zigonaut_selection_row_path(&intervals, 0, 20, 10, 20, 1, 1, &row_output, 27));
    try std.testing.expectEqual(3, row_output[row_required - 1].tag);
    try std.testing.expectEqual(99, row_output[27].tag);
}

test "Windows fractional coordinates retain Float intermediate rounding" {
    const intervals = [_]Interval{
        .{ .start = 1, .end = 9, .active = 1 },
        .{ .start = 3, .end = 8, .active = 1 },
        .{ .start = 2, .end = 10, .active = 1 },
    };
    var output: [27]CommandF32 = undefined;
    const count = zigonaut_selection_row_path(&intervals, 0.3, 0.3, 10.123, 19.23456789, 0, 0, &output, output.len);
    try std.testing.expectEqual(25, count);
    // Captured from the original C++ sink, not calculated with the Zig code.
    // These cover column multiplication, top-height, top+height and the last
    // bottom edge. Widening intermediate operations changes the outline bits.
    try std.testing.expectEqual(@as(u32, 0x42b1c0a5), @as(u32, @bitCast(output[0].x)));
    try std.testing.expectEqual(@as(u32, 0xc19779ff), @as(u32, @bitCast(output[0].y)));
    try std.testing.expectEqual(@as(u32, 0x419c46cb), @as(u32, @bitCast(output[7].y)));
    try std.testing.expectEqual(@as(u32, 0x421b1398), @as(u32, @bitCast(output[11].y)));
}
