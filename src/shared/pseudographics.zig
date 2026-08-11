//! Complete CPU A8 rasterizer for Unicode Box Drawing and Block Elements.
//!
//! The topology and geometry are adapted from Ghostty's MIT-licensed sprite
//! renderer (`font/sprite/draw/{box,block,common}.zig`). See
//! `licenses/Ghostty-LICENSE.txt`. This is a focused first-party adaptation:
//! it has no dependency on Ghostty package internals and no mutable cache.
const std = @import("std");

pub const Metrics = struct {
    width: u16,
    height: u16,
    thickness: u8 = 0,

    pub fn valid(m: Metrics) bool {
        return m.width > 0 and m.height > 0 and m.width <= 4096 and m.height <= 4096 and
            m.thickness <= @min(m.width, m.height);
    }

    fn stroke(m: Metrics) usize {
        return if (m.thickness > 0) m.thickness else @max(1, (@as(usize, m.height) + 8) / 16);
    }
};

pub const Error = error{ InvalidCodepoint, InvalidMetrics, BufferTooSmall };

pub fn covers(cp: u21) bool {
    return cp >= 0x2500 and cp <= 0x259f;
}

pub fn requiredBytes(m: Metrics, stride: usize) Error!usize {
    if (!m.valid() or stride < m.width) return error.InvalidMetrics;
    return std.math.mul(usize, stride, m.height) catch error.InvalidMetrics;
}

const Canvas = struct {
    pixels: []u8,
    stride: usize,
    width: usize,
    height: usize,

    fn rect(c: Canvas, x0_: usize, y0_: usize, x1_: usize, y1_: usize, a: u8) void {
        const x0 = @min(x0_, c.width);
        const x1 = @min(x1_, c.width);
        var y = @min(y0_, c.height);
        const y1 = @min(y1_, c.height);
        while (y < y1) : (y += 1) @memset(c.pixels[y * c.stride + x0 .. y * c.stride + x1], a);
    }

    fn blend(c: Canvas, x: usize, y: usize, a: u8) void {
        if (x >= c.width or y >= c.height) return;
        c.pixels[y * c.stride + x] = @max(c.pixels[y * c.stride + x], a);
    }
};

pub fn render(cp: u21, m: Metrics, stride: usize, out: []u8) Error!usize {
    if (!covers(cp)) return error.InvalidCodepoint;
    const n = try requiredBytes(m, stride);
    if (out.len < n) return error.BufferTooSmall;
    @memset(out[0..n], 0);
    const canvas: Canvas = .{ .pixels = out[0..n], .stride = stride, .width = m.width, .height = m.height };
    if (cp < 0x2580) renderBox(cp, m, canvas) else renderBlock(cp, canvas);
    return n;
}

// Two bits per arm, low to high: up, down, left, right. 0=none,
// 1=light, 2=heavy, 3=double. This is an exact transcription of Ghostty's
// U+2500..U+257F switch, with special geometry entries left zero.
const topology = [128]u8{
    0x50, 0xa0, 0x05, 0x0a, 0,    0,    0,    0,    0,    0,    0,    0,    0x44, 0x84, 0x48, 0x88,
    0x14, 0x24, 0x18, 0x28, 0x41, 0x81, 0x42, 0x82, 0x11, 0x21, 0x12, 0x22, 0x45, 0x85, 0x46, 0x49,
    0x4a, 0x86, 0x89, 0x8a, 0x15, 0x25, 0x16, 0x19, 0x1a, 0x26, 0x29, 0x2a, 0x54, 0x64, 0x94, 0xa4,
    0x58, 0x68, 0x98, 0xa8, 0x51, 0x61, 0x91, 0xa1, 0x52, 0x62, 0x92, 0xa2, 0x55, 0x65, 0x95, 0xa5,
    0x56, 0x59, 0x5a, 0x66, 0x96, 0x69, 0x99, 0xa6, 0xa9, 0x6a, 0x9a, 0xaa, 0,    0,    0,    0,
    0xf0, 0x0f, 0xc4, 0x4c, 0xcc, 0x34, 0x1c, 0x3c, 0xc1, 0x43, 0xc3, 0x31, 0x13, 0x33, 0xc5, 0x4f,
    0xcf, 0x35, 0x1f, 0x3f, 0xf4, 0x5c, 0xfc, 0xf1, 0x53, 0xf3, 0xf5, 0x5f, 0xff, 0,    0,    0,
    0,    0,    0,    0,    0x10, 0x01, 0x40, 0x04, 0x20, 0x02, 0x80, 0x08, 0x90, 0x09, 0x60, 0x06,
};

fn centered(extent: usize, thick: usize) struct { usize, usize } {
    const n = @min(extent, thick);
    const lo = (extent - n) / 2;
    return .{ lo, lo + n };
}

const Style = enum(u2) { none, light, heavy, double };
const Lines = struct { up: Style = .none, right: Style = .none, down: Style = .none, left: Style = .none };

fn linesChar(c: Canvas, lines: Lines, base: usize) void {
    // This is the neighbor-aware guide and endpoint selection used by Ghostty.
    // In particular, double strokes stop on different perpendicular guides so
    // that corners join while the channel between their rails remains empty.
    const heavy = @min(@min(c.width, c.height), base * 2);
    const hl = centered(c.height, base);
    const hh = centered(c.height, heavy);
    const vl = centered(c.width, base);
    const vh = centered(c.width, heavy);
    const hdt = hl[0] -| base;
    const hdb = @min(c.height, hl[1] + base);
    const vdl = vl[0] -| base;
    const vdr = @min(c.width, vl[1] + base);

    const up_bottom = if (lines.left == .heavy or lines.right == .heavy) hh[1] else if (lines.left != lines.right or lines.down == lines.up) (if (lines.left == .double or lines.right == .double) hdb else hl[1]) else if (lines.left == .none and lines.right == .none) hl[1] else hl[0];
    const down_top = if (lines.left == .heavy or lines.right == .heavy) hh[0] else if (lines.left != lines.right or lines.up == lines.down) (if (lines.left == .double or lines.right == .double) hdt else hl[0]) else if (lines.left == .none and lines.right == .none) hl[0] else hl[1];
    const left_right = if (lines.up == .heavy or lines.down == .heavy) vh[1] else if (lines.up != lines.down or lines.left == lines.right) (if (lines.up == .double or lines.down == .double) vdr else vl[1]) else if (lines.up == .none and lines.down == .none) vl[1] else vl[0];
    const right_left = if (lines.up == .heavy or lines.down == .heavy) vh[0] else if (lines.up != lines.down or lines.right == lines.left) (if (lines.up == .double or lines.down == .double) vdl else vl[0]) else if (lines.up == .none and lines.down == .none) vl[0] else vl[1];

    switch (lines.up) {
        .none => {},
        .light => c.rect(vl[0], 0, vl[1], up_bottom, 255),
        .heavy => c.rect(vh[0], 0, vh[1], up_bottom, 255),
        .double => {
            c.rect(vdl, 0, vl[0], if (lines.left == .double) hl[0] else up_bottom, 255);
            c.rect(vl[1], 0, vdr, if (lines.right == .double) hl[0] else up_bottom, 255);
        },
    }
    switch (lines.right) {
        .none => {},
        .light => c.rect(right_left, hl[0], c.width, hl[1], 255),
        .heavy => c.rect(right_left, hh[0], c.width, hh[1], 255),
        .double => {
            c.rect(if (lines.up == .double) vl[1] else right_left, hdt, c.width, hl[0], 255);
            c.rect(if (lines.down == .double) vl[1] else right_left, hl[1], c.width, hdb, 255);
        },
    }
    switch (lines.down) {
        .none => {},
        .light => c.rect(vl[0], down_top, vl[1], c.height, 255),
        .heavy => c.rect(vh[0], down_top, vh[1], c.height, 255),
        .double => {
            c.rect(vdl, if (lines.left == .double) hl[1] else down_top, vl[0], c.height, 255);
            c.rect(vl[1], if (lines.right == .double) hl[1] else down_top, vdr, c.height, 255);
        },
    }
    switch (lines.left) {
        .none => {},
        .light => c.rect(0, hl[0], left_right, hl[1], 255),
        .heavy => c.rect(0, hh[0], left_right, hh[1], 255),
        .double => {
            c.rect(0, hdt, if (lines.up == .double) vl[0] else left_right, hl[0], 255);
            c.rect(0, hl[1], if (lines.down == .double) vl[0] else left_right, hdb, 255);
        },
    }
}

fn dashed(c: Canvas, horizontal: bool, heavy: bool, count: usize, base: usize) void {
    const extent = if (horizontal) c.width else c.height;
    const thick = @min(if (horizontal) c.height else c.width, base * (if (heavy) @as(usize, 2) else 1));
    // Divide the actual integer tile into 2N-1 cells. Boundaries are computed
    // from the same origin, making adjacent terminal tiles phase-compatible.
    const units = count * 2 - 1;
    for (0..count) |i| {
        const a = (i * 2 * extent) / units;
        const b = ((i * 2 + 1) * extent + units - 1) / units;
        const mid = centered(if (horizontal) c.height else c.width, thick);
        if (horizontal) c.rect(a, mid[0], b, mid[1], 255) else c.rect(mid[0], a, mid[1], b, 255);
    }
}

fn aaLine(c: Canvas, rising: bool, base: usize) void {
    // Deterministic 4x4 coverage sampling gives antialiasing without allocation.
    const samples = 4;
    const wf: f64 = @floatFromInt(c.width);
    const hf: f64 = @floatFromInt(c.height);
    const radius: f64 = @as(f64, @floatFromInt(base)) / 2.0;
    for (0..c.height) |y| for (0..c.width) |x| {
        var inside: usize = 0;
        for (0..samples) |sy| for (0..samples) |sx| {
            const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / samples;
            const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / samples;
            const target = if (rising) (px / wf) * hf else (1.0 - px / wf) * hf;
            if (@abs(py - target) <= radius) inside += 1;
        };
        if (inside > 0) c.blend(x, y, @intCast((inside * 255) / (samples * samples)));
    };
}

fn rounded(c: Canvas, cp: u21, base: usize) void {
    // Ghostty's centered, circular cubic with straight tangent lead-ins.
    const right = cp == 0x256d or cp == 0x2570;
    const down = cp == 0x256d or cp == 0x256e;
    const xb = centered(c.width, base);
    const yb = centered(c.height, base);
    const cx = @as(f64, @floatFromInt(xb[0])) + @as(f64, @floatFromInt(base)) / 2.0;
    const cy = @as(f64, @floatFromInt(yb[0])) + @as(f64, @floatFromInt(base)) / 2.0;
    const r = @as(f64, @floatFromInt(@min(c.width, c.height))) / 2.0;
    const sign_x: f64 = if (right) 1 else -1;
    const sign_y: f64 = if (down) 1 else -1;
    const radius = @as(f64, @floatFromInt(base)) / 2.0;
    for (0..c.height) |y| for (0..c.width) |x| {
        var hit: usize = 0;
        for (0..4) |sy| for (0..4) |sx| {
            const px = @as(f64, @floatFromInt(x)) + (@as(f64, @floatFromInt(sx)) + 0.5) / 4.0;
            const py = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(sy)) + 0.5) / 4.0;
            var best = @min(segmentDistance(px, py, cx, if (down) @as(f64, @floatFromInt(c.height)) else 0, cx, cy + sign_y * r), segmentDistance(px, py, cx + sign_x * r, cy, if (right) @as(f64, @floatFromInt(c.width)) else 0, cy));
            var ax = cx;
            var ay = cy + sign_y * r;
            for (1..17) |i| {
                const t = @as(f64, @floatFromInt(i)) / 16.0;
                const u = 1.0 - t;
                const bx = u * u * u * cx + 3 * u * u * t * cx + 3 * u * t * t * (cx + sign_x * 0.25 * r) + t * t * t * (cx + sign_x * r);
                const by = u * u * u * (cy + sign_y * r) + 3 * u * u * t * (cy + sign_y * 0.25 * r) + 3 * u * t * t * cy + t * t * t * cy;
                best = @min(best, segmentDistance(px, py, ax, ay, bx, by));
                ax = bx;
                ay = by;
            }
            if (best <= radius) hit += 1;
        };
        if (hit > 0) c.blend(x, y, @intCast(hit * 255 / 16));
    };
}

fn segmentDistance(px: f64, py: f64, ax: f64, ay: f64, bx: f64, by: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const d = dx * dx + dy * dy;
    const t = if (d == 0) 0 else std.math.clamp(((px - ax) * dx + (py - ay) * dy) / d, 0, 1);
    return @sqrt((px - ax - t * dx) * (px - ax - t * dx) + (py - ay - t * dy) * (py - ay - t * dy));
}

fn renderBox(cp: u21, m: Metrics, c: Canvas) void {
    const base = @min(@min(c.width, c.height), m.stroke());
    switch (cp) {
        0x2504...0x250b => dashed(c, cp == 0x2504 or cp == 0x2505 or cp == 0x2508 or cp == 0x2509, (cp & 1) == 1, if (cp < 0x2508) 3 else 4, base),
        0x254c...0x254f => dashed(c, cp < 0x254e, (cp & 1) == 1, 2, base),
        0x256d...0x2570 => rounded(c, cp, base),
        0x2571 => aaLine(c, false, base),
        0x2572 => aaLine(c, true, base),
        0x2573 => {
            aaLine(c, false, base);
            aaLine(c, true, base);
        },
        else => {
            const t = topology[cp - 0x2500];
            linesChar(c, .{
                .up = @enumFromInt(@as(u2, @truncate(t))),
                .down = @enumFromInt(@as(u2, @truncate(t >> 2))),
                .left = @enumFromInt(@as(u2, @truncate(t >> 4))),
                .right = @enumFromInt(@as(u2, @truncate(t >> 6))),
            }, base);
        },
    }
}

fn boundary(n: usize, extent: usize) usize {
    return (n * extent + 4) / 8;
}

fn renderBlock(cp: u21, c: Canvas) void {
    switch (cp) {
        0x2580 => c.rect(0, 0, c.width, boundary(4, c.height), 255),
        0x2581...0x2588 => c.rect(0, boundary(8 - (cp - 0x2580), c.height), c.width, c.height, 255),
        0x2589...0x258f => c.rect(0, 0, boundary(8 - (cp - 0x2588), c.width), c.height, 255),
        0x2590 => c.rect(boundary(4, c.width), 0, c.width, c.height, 255),
        0x2591...0x2593 => c.rect(0, 0, c.width, c.height, @intCast((cp - 0x2590) * 0x40)),
        0x2594 => c.rect(0, 0, c.width, boundary(1, c.height), 255),
        0x2595 => c.rect(boundary(7, c.width), 0, c.width, c.height, 255),
        0x2596...0x259f => {
            const masks = [10]u4{ 0b0100, 0b1000, 0b0001, 0b1101, 0b1001, 0b0111, 0b1011, 0b0010, 0b0110, 0b1110 };
            const mask = masks[cp - 0x2596];
            const mx = boundary(4, c.width);
            const my = boundary(4, c.height);
            if (mask & 1 != 0) c.rect(0, 0, mx, my, 255);
            if (mask & 2 != 0) c.rect(mx, 0, c.width, my, 255);
            if (mask & 4 != 0) c.rect(0, my, mx, c.height, 255);
            if (mask & 8 != 0) c.rect(mx, my, c.width, c.height, 255);
        },
        else => unreachable,
    }
}

test "all glyphs are deterministic and nonempty at varied metrics" {
    const metrics = [_]Metrics{
        .{ .width = 7, .height = 13, .thickness = 1 },
        .{ .width = 8, .height = 14, .thickness = 1 },
        .{ .width = 9, .height = 15, .thickness = 2 },
        .{ .width = 10, .height = 16, .thickness = 2 },
    };
    for (metrics) |m| {
        var a: [160]u8 = undefined;
        var b: [160]u8 = undefined;
        var cp: u21 = 0x2500;
        while (cp <= 0x259f) : (cp += 1) {
            const n = try render(cp, m, m.width, &a);
            _ = try render(cp, m, m.width, &b);
            try std.testing.expectEqualSlices(u8, a[0..n], b[0..n]);
            try std.testing.expect(std.mem.indexOfNone(u8, a[0..n], &.{0}) != null);
        }
    }
}

test "default light stroke rounds with cell height" {
    try std.testing.expectEqual(@as(usize, 1), (Metrics{ .width = 8, .height = 23 }).stroke());
    try std.testing.expectEqual(@as(usize, 2), (Metrics{ .width = 12, .height = 24 }).stroke());
    try std.testing.expectEqual(@as(usize, 2), (Metrics{ .width = 18, .height = 35 }).stroke());
}

test "blocks shades complements topology and antialiasing" {
    const m: Metrics = .{ .width = 9, .height = 15, .thickness = 1 };
    var a: [135]u8 = undefined;
    var b: [135]u8 = undefined;
    _ = try render(0x2588, m, 9, &a);
    for (a) |v| try std.testing.expectEqual(@as(u8, 255), v);
    for (0x2591..0x2594) |cp| {
        _ = try render(@intCast(cp), m, 9, &a);
        for (a) |v| try std.testing.expectEqual(@as(u8, @intCast((cp - 0x2590) * 0x40)), v);
    }
    _ = try render(0x2580, m, 9, &a);
    _ = try render(0x2584, m, 9, &b);
    for (a, b) |x, y| try std.testing.expect(x != 0 or y != 0);
    _ = try render(0x250c, m, 9, &a);
    _ = try render(0x2510, m, 9, &b);
    try std.testing.expect(std.hash.Wyhash.hash(0, &a) != std.hash.Wyhash.hash(0, &b));
    _ = try render(0x2571, m, 9, &a);
    try std.testing.expect(std.mem.indexOfAny(u8, &a, &.{ 16, 31, 47, 63, 79, 95, 111, 127, 143, 159, 175, 191, 207, 223, 239 }) != null);
}

test "double corners and junctions preserve connected rails and channels" {
    const metrics = [_]Metrics{
        .{ .width = 11, .height = 17, .thickness = 2 },
        .{ .width = 12, .height = 18, .thickness = 2 },
    };
    const cps = [_]u21{ 0x2554, 0x2557, 0x255a, 0x255d, 0x256a, 0x256b, 0x256c };
    for (metrics) |m| for (cps) |cp| {
        var pixels: [216]u8 = undefined;
        _ = try render(cp, m, m.width, &pixels);
        const w: usize = m.width;
        const h: usize = m.height;
        const hl = centered(h, 2);
        const vl = centered(w, 2);
        const hdt = hl[0] - 2;
        const vdl = vl[0] - 2;

        // Every declared double edge has two complete rails from the cell edge
        // to its perpendicular guide. These ranges overlap the corresponding
        // perpendicular rails, proving joins rather than mere edge marks.
        const t = topology[cp - 0x2500];
        const up: Style = @enumFromInt(@as(u2, @truncate(t)));
        const down: Style = @enumFromInt(@as(u2, @truncate(t >> 2)));
        const left: Style = @enumFromInt(@as(u2, @truncate(t >> 4)));
        const right: Style = @enumFromInt(@as(u2, @truncate(t >> 6)));
        if (up == .double) for (0..hl[0]) |y| {
            try std.testing.expect(pixels[y * w + vdl] != 0);
            try std.testing.expect(pixels[y * w + vl[1]] != 0);
        };
        if (down == .double) for (hl[1]..h) |y| {
            try std.testing.expect(pixels[y * w + vdl] != 0);
            try std.testing.expect(pixels[y * w + vl[1]] != 0);
        };
        if (left == .double) for (0..vl[0]) |x| {
            try std.testing.expect(pixels[hdt * w + x] != 0);
            try std.testing.expect(pixels[hl[1] * w + x] != 0);
        };
        if (right == .double) for (vl[1]..w) |x| {
            try std.testing.expect(pixels[hdt * w + x] != 0);
            try std.testing.expect(pixels[hl[1] * w + x] != 0);
        };

        // The center of both double-line channels remains negative space.
        if (up == .double or down == .double) try std.testing.expectEqual(@as(u8, 0), pixels[0 * w + vl[0]]);
        if (left == .double or right == .double) try std.testing.expectEqual(@as(u8, 0), pixels[hl[0] * w]);
        if (cp == 0x256c) try std.testing.expectEqual(@as(u8, 0), pixels[hl[0] * w + vl[0]]);
    };
}

test "rounded corners use straight snapped edge tangents" {
    const metrics = [_]Metrics{
        .{ .width = 9, .height = 15, .thickness = 1 },
        .{ .width = 10, .height = 16, .thickness = 2 },
    };
    for (metrics) |m| {
        var horizontal: [160]u8 = undefined;
        var vertical: [160]u8 = undefined;
        var arc_pixels: [160]u8 = undefined;
        _ = try render(0x2500, m, m.width, &horizontal);
        _ = try render(0x2502, m, m.width, &vertical);
        for (0x256d..0x2571) |raw_cp| {
            const cp: u21 = @intCast(raw_cp);
            _ = try render(cp, m, m.width, &arc_pixels);
            const right = cp == 0x256d or cp == 0x2570;
            const down = cp == 0x256d or cp == 0x256e;
            const edge_x: usize = if (right) m.width - 1 else 0;
            const edge_y: usize = if (down) m.height - 1 else 0;
            for (0..m.height) |y| try std.testing.expectEqual(horizontal[y * m.width + edge_x], arc_pixels[y * m.width + edge_x]);
            for (0..m.width) |x| try std.testing.expectEqual(vertical[edge_y * m.width + x], arc_pixels[edge_y * m.width + x]);
        }
    }
}
