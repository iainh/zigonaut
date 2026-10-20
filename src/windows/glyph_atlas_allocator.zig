// Fixed skyline allocator adapted from Ghostty src/font/Atlas.zig at commit
// f5880782fe34faccd30bb0c903055987171b6370.
// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors; MIT license:
// licenses/Ghostty-LICENSE.txt. The original cites Jukka Jylanki's
// RectangleBinPack work and freetype-gl's texture-atlas skyline implementation.
// This adaptation keeps a one-pixel guard around every reservation, not only
// the atlas edge. Placement matches the former C++ implementation.
const std = @import("std");

const Node = extern struct { x: u32, y: u32, width: u32 };
pub const Rect = extern struct { x: u32, y: u32, width: u32, height: u32 };

// Mirrored by ZigonautAtlasState in glyph_atlas_allocator.h. Embedded in the
// native RAII owner: no extra handle allocation or per-frame ABI calls.
pub const State = extern struct {
    nodes: [*]Node = undefined,
    length: usize = 0,
    capacity: usize = 0,
    extent: u32 = 0,

    fn list(self: *const State) std.ArrayList(Node) {
        return .{
            .items = self.nodes[0..self.length],
            .capacity = self.capacity,
        };
    }

    fn store(self: *State, nodes: std.ArrayList(Node)) void {
        self.nodes = nodes.items.ptr;
        self.length = nodes.items.len;
        self.capacity = nodes.capacity;
    }

    pub fn init(allocator: std.mem.Allocator, extent: u32) !State {
        var nodes: std.ArrayList(Node) = .empty;
        try nodes.append(allocator, .{ .x = 0, .y = 0, .width = extent });
        var self: State = .{ .extent = extent };
        self.store(nodes);
        return self;
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        var nodes = self.list();
        nodes.deinit(allocator);
        self.* = .{};
    }

    pub fn reserve(self: *State, allocator: std.mem.Allocator, width: u32, height: u32, result: *Rect) bool {
        if (self.extent < 3 or width == 0 or height == 0 or
            width > self.extent - 2 or height > self.extent - 2) return false;
        const w = width + 2;
        const h = height + 2;
        var nodes = self.list();
        var best = nodes.items.len;
        var best_y: u32 = std.math.maxInt(u32);
        for (nodes.items, 0..) |node, i| {
            // A fit can only raise y: don't walk spans that already cannot
            // fit vertically or cannot beat the best candidate's height.
            const max_y = @min(best_y, self.extent - h);
            if (node.y > max_y) continue;
            const y = self.fit(i, w, max_y) orelse continue;
            // Strict comparison preserves the first candidate on exact ties.
            if (y < best_y or (y == best_y and node.width < nodes.items[best].width)) {
                best = i;
                best_y = y;
            }
        }
        if (best == nodes.items.len) return false;
        const x = nodes.items[best].x;
        const end = x + w;
        var stop = best;
        while (stop < nodes.items.len and nodes.items[stop].x + nodes.items[stop].width <= end) : (stop += 1) {}

        // Replace all covered nodes at once. Only a split can increase length;
        // secure capacity before any mutation so OOM also leaves result intact.
        if (stop == best) nodes.ensureUnusedCapacity(allocator, 1) catch return false;
        if (stop < nodes.items.len and nodes.items[stop].x < end) {
            nodes.items[stop].width -= end - nodes.items[stop].x;
            nodes.items[stop].x = end;
        }
        nodes.replaceRangeAssumeCapacity(best, stop - best, &.{.{ .x = x, .y = best_y + h, .width = w }});
        // The old skyline has no equal-height neighbours. Only the two new
        // boundaries can merge; don't scan or copy the whole skyline again.
        if (best + 1 < nodes.items.len and nodes.items[best].y == nodes.items[best + 1].y) {
            nodes.items[best].width += nodes.items[best + 1].width;
            _ = nodes.orderedRemove(best + 1);
        }
        if (best > 0 and nodes.items[best - 1].y == nodes.items[best].y) {
            nodes.items[best - 1].width += nodes.items[best].width;
            _ = nodes.orderedRemove(best);
        }
        self.store(nodes);
        result.* = .{ .x = x + 1, .y = best_y + 1, .width = width, .height = height };
        return true;
    }

    fn fit(self: *const State, index: usize, width: u32, max_y: u32) ?u32 {
        const nodes = self.list().items;
        if (nodes[index].x > self.extent - width) return null;
        var remaining = width;
        var y = nodes[index].y;
        for (nodes[index..]) |node| {
            y = @max(y, node.y);
            if (y > max_y) return null;
            if (node.width >= remaining) return y;
            remaining -= node.width;
        }
        return null;
    }
};

export fn zigonaut_atlas_init(state: *State, extent: u32) callconv(.c) bool {
    state.* = State.init(std.heap.c_allocator, extent) catch return false;
    return true;
}

export fn zigonaut_atlas_deinit(state: *State) callconv(.c) void {
    state.deinit(std.heap.c_allocator);
}

export fn zigonaut_atlas_reserve(state: *State, width: u32, height: u32, result: *Rect) callconv(.c) bool {
    return state.reserve(std.heap.c_allocator, width, height, result);
}

test "one-pixel guards and transactional rejection at extent boundaries" {
    const t = std.testing;
    for ([_]u32{ 0, 1, 2, 3, 1024, 2048, std.math.maxInt(u32) }) |extent| {
        var state = try State.init(t.allocator, extent);
        defer state.deinit(t.allocator);
        var rect: Rect = .{ .x = 7, .y = 8, .width = 9, .height = 10 };
        const sentinel = rect;
        try t.expect(!state.reserve(t.allocator, 0, 1, &rect));
        try t.expect(!state.reserve(t.allocator, std.math.maxInt(u32), 1, &rect));
        try t.expectEqualDeep(sentinel, rect);
        if (extent < 3) {
            try t.expect(!state.reserve(t.allocator, 1, 1, &rect));
        } else {
            try t.expect(state.reserve(t.allocator, extent - 2, extent - 2, &rect));
            try t.expectEqualDeep(Rect{ .x = 1, .y = 1, .width = extent - 2, .height = extent - 2 }, rect);
            const full = rect;
            try t.expect(!state.reserve(t.allocator, 1, 1, &rect));
            try t.expectEqualDeep(full, rect);
        }
    }
}

test "allocation failure leaves subsequent placements unchanged" {
    const t = std.testing;
    var failing = t.FailingAllocator.init(t.allocator, .{ .resize_fail_index = 0 });
    const allocator = failing.allocator();
    var state = try State.init(allocator, 2048);
    defer state.deinit(allocator);
    var repeat = try State.init(t.allocator, 2048);
    defer repeat.deinit(t.allocator);
    var rect: Rect = undefined;
    var expected: Rect = undefined;
    var failures: usize = 0;
    // Varied heights force skyline splits and capacity growth, rather than
    // testing only the initial allocation or a constant-height shelf.
    for (0..100) |i| {
        const height: u32 = @intCast(150 - i);
        const sentinel: Rect = .{ .x = 7, .y = 8, .width = 9, .height = 10 };
        rect = sentinel;
        failing.fail_index = failing.alloc_index;
        if (!state.reserve(allocator, 3, height, &rect)) {
            failures += 1;
            try t.expectEqualDeep(sentinel, rect);
            failing.fail_index = std.math.maxInt(usize);
            try t.expect(state.reserve(allocator, 3, height, &rect));
        }
        try t.expect(repeat.reserve(t.allocator, 3, height, &expected));
        try t.expectEqualDeep(expected, rect);
    }
    try t.expect(failures > 0);
}

test "mixed-height reservations preserve bottom-left placement after merging" {
    const t = std.testing;
    var state = try State.init(t.allocator, 16);
    defer state.deinit(t.allocator);
    const expected = [_]Rect{
        .{ .x = 1, .y = 1, .width = 3, .height = 6 },
        .{ .x = 6, .y = 1, .width = 4, .height = 2 },
        .{ .x = 12, .y = 1, .width = 3, .height = 2 },
        .{ .x = 6, .y = 5, .width = 3, .height = 2 },
        .{ .x = 11, .y = 5, .width = 4, .height = 2 },
        .{ .x = 1, .y = 9, .width = 14, .height = 6 },
    };
    for (expected) |placement| {
        var rect: Rect = undefined;
        try t.expect(state.reserve(t.allocator, placement.width, placement.height, &rect));
        try t.expectEqualDeep(placement, rect);
    }
    var rect: Rect = expected[0];
    try t.expect(!state.reserve(t.allocator, 1, 1, &rect));
    try t.expectEqualDeep(expected[0], rect);
}
