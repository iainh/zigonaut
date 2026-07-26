const std = @import("std");

pub const PaneId = u64;
pub const SplitId = u64;

pub const Axis = enum { left_right, top_bottom };
pub const Direction = enum { left, right, up, down };

pub const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const Item = union(enum) {
    leaf: struct { id: PaneId, rect: Rect },
    split: struct { id: SplitId, axis: Axis, ratio: u16, subtree_size: u32, rect: Rect },
};

pub const Error = error{
    InvalidId,
    DuplicateId,
    PaneNotFound,
    SplitNotFound,
};

const Node = union(enum) {
    leaf: PaneId,
    split: Split,

    const Split = struct {
        id: SplitId,
        axis: Axis,
        ratio: u16,
        first: *Node,
        second: *Node,
    };
};

pub const Tree = struct {
    allocator: std.mem.Allocator,
    root: ?*Node,
    focused: ?PaneId,

    pub fn init(allocator: std.mem.Allocator, pane_id: PaneId) (Error || std.mem.Allocator.Error)!Tree {
        if (pane_id == 0) return error.InvalidId;
        const root = try allocator.create(Node);
        root.* = .{ .leaf = pane_id };
        return .{ .allocator = allocator, .root = root, .focused = pane_id };
    }

    pub fn deinit(self: *Tree) void {
        if (self.root) |root| destroyNode(self.allocator, root);
        self.* = .{ .allocator = self.allocator, .root = null, .focused = null };
    }

    pub fn split(self: *Tree, target: PaneId, new_pane: PaneId, split_id: SplitId, axis: Axis) (Error || std.mem.Allocator.Error)!void {
        if (new_pane == 0 or split_id == 0) return error.InvalidId;
        if (findPane(self.root, new_pane) != null or findSplit(self.root, split_id) != null)
            return error.DuplicateId;
        const leaf = findPane(self.root, target) orelse return error.PaneNotFound;
        const old_id = leaf.leaf;
        const first = try self.allocator.create(Node);
        errdefer self.allocator.destroy(first);
        const second = try self.allocator.create(Node);
        first.* = .{ .leaf = old_id };
        second.* = .{ .leaf = new_pane };
        leaf.* = .{ .split = .{
            .id = split_id,
            .axis = axis,
            .ratio = 32768,
            .first = first,
            .second = second,
        } };
    }

    pub fn focus(self: *Tree, pane_id: PaneId) bool {
        if (findPane(self.root, pane_id) == null) return false;
        self.focused = pane_id;
        return true;
    }

    pub fn setRatio(self: *Tree, split_id: SplitId, ratio: u16) Error!void {
        const node = findSplit(self.root, split_id) orelse return error.SplitNotFound;
        node.split.ratio = ratio;
    }

    /// Returns a caller-owned preorder snapshot. Rect coordinates are normalized
    /// to the full u32 range and do not depend on terminal titles or pixel size.
    pub fn flatten(self: *const Tree, allocator: std.mem.Allocator) std.mem.Allocator.Error![]Item {
        var items: std.ArrayList(Item) = .empty;
        defer items.deinit(allocator);
        if (self.root) |root| try appendItems(root, full_rect, &items, allocator);
        return items.toOwnedSlice(allocator);
    }

    pub fn close(self: *Tree, pane_id: PaneId) bool {
        if (findPane(self.root, pane_id) == null) return false;
        var previous: ?PaneId = null;
        var next: ?PaneId = null;
        var seen = false;
        neighbors(self.root.?, pane_id, &seen, &previous, &next);
        self.root = removeLeaf(self.allocator, self.root.?, pane_id);
        if (self.focused == pane_id) self.focused = previous orelse next;
        if (self.root == null) self.focused = null;
        return true;
    }

    pub fn focusDirection(self: *Tree, direction: Direction) bool {
        const current_id = self.focused orelse return false;
        var leaves: std.ArrayList(Item) = .empty;
        defer leaves.deinit(self.allocator);
        appendItems(self.root orelse return false, full_rect, &leaves, self.allocator) catch return false;

        var current: ?Rect = null;
        for (leaves.items) |item| switch (item) {
            .leaf => |leaf| if (leaf.id == current_id) {
                current = leaf.rect;
            },
            .split => {},
        };
        const from = current orelse return false;
        var best: ?PaneId = null;
        var best_primary: u64 = std.math.maxInt(u64);
        var best_secondary: u64 = std.math.maxInt(u64);
        for (leaves.items) |item| switch (item) {
            .split => {},
            .leaf => |leaf| {
                if (leaf.id == current_id) continue;
                const scores = directionScores(from, leaf.rect, direction) orelse continue;
                if (scores.primary < best_primary or
                    (scores.primary == best_primary and scores.secondary < best_secondary))
                {
                    best = leaf.id;
                    best_primary = scores.primary;
                    best_secondary = scores.secondary;
                }
            },
        };
        if (best) |id| {
            self.focused = id;
            return true;
        }
        return false;
    }
};

const full_rect = Rect{ .x = 0, .y = 0, .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) };

fn destroyNode(allocator: std.mem.Allocator, node: *Node) void {
    switch (node.*) {
        .leaf => {},
        .split => |split| {
            destroyNode(allocator, split.first);
            destroyNode(allocator, split.second);
        },
    }
    allocator.destroy(node);
}

fn findPane(root: ?*Node, id: PaneId) ?*Node {
    const node = root orelse return null;
    return switch (node.*) {
        .leaf => |pane| if (pane == id) node else null,
        .split => |split| findPane(split.first, id) orelse findPane(split.second, id),
    };
}

fn findSplit(root: ?*Node, id: SplitId) ?*Node {
    const node = root orelse return null;
    return switch (node.*) {
        .leaf => null,
        .split => |split| if (split.id == id) node else findSplit(split.first, id) orelse findSplit(split.second, id),
    };
}

fn appendItems(node: *const Node, rect: Rect, items: *std.ArrayList(Item), allocator: std.mem.Allocator) !void {
    switch (node.*) {
        .leaf => |id| try items.append(allocator, .{ .leaf = .{ .id = id, .rect = rect } }),
        .split => |split| {
            const split_index = items.items.len;
            try items.append(allocator, .{ .split = .{ .id = split.id, .axis = split.axis, .ratio = split.ratio, .subtree_size = 0, .rect = rect } });
            const first_size: u32 = @intCast((@as(u64, if (split.axis == .left_right) rect.width else rect.height) * split.ratio) / std.math.maxInt(u16));
            var first = rect;
            var second = rect;
            if (split.axis == .left_right) {
                first.width = first_size;
                second.x += first_size;
                second.width -= first_size;
            } else {
                first.height = first_size;
                second.y += first_size;
                second.height -= first_size;
            }
            try appendItems(split.first, first, items, allocator);
            try appendItems(split.second, second, items, allocator);
            items.items[split_index].split.subtree_size = @intCast(items.items.len - split_index);
        },
    }
}

fn neighbors(node: *const Node, target: PaneId, seen: *bool, previous: *?PaneId, next: *?PaneId) void {
    switch (node.*) {
        .split => |split| {
            neighbors(split.first, target, seen, previous, next);
            neighbors(split.second, target, seen, previous, next);
        },
        .leaf => |id| {
            if (next.* != null) return;
            if (seen.*) next.* = id else if (id == target) seen.* = true else previous.* = id;
        },
    }
}

fn removeLeaf(allocator: std.mem.Allocator, node: *Node, target: PaneId) ?*Node {
    switch (node.*) {
        .leaf => |id| if (id == target) {
            allocator.destroy(node);
            return null;
        },
        .split => |*split| {
            split.first = removeLeaf(allocator, split.first, target) orelse {
                const survivor = split.second;
                allocator.destroy(node);
                return survivor;
            };
            split.second = removeLeaf(allocator, split.second, target) orelse {
                const survivor = split.first;
                allocator.destroy(node);
                return survivor;
            };
        },
    }
    return node;
}

const Scores = struct { primary: u64, secondary: u64 };

fn directionScores(from: Rect, candidate: Rect, direction: Direction) ?Scores {
    const fx1: u64 = from.x;
    const fy1: u64 = from.y;
    const fx2 = fx1 + from.width;
    const fy2 = fy1 + from.height;
    const cx1: u64 = candidate.x;
    const cy1: u64 = candidate.y;
    const cx2 = cx1 + candidate.width;
    const cy2 = cy1 + candidate.height;
    const horizontal = direction == .left or direction == .right;
    const primary = switch (direction) {
        .left => if (cx2 <= fx1) fx1 - cx2 else return null,
        .right => if (cx1 >= fx2) cx1 - fx2 else return null,
        .up => if (cy2 <= fy1) fy1 - cy2 else return null,
        .down => if (cy1 >= fy2) cy1 - fy2 else return null,
    };
    const a1 = if (horizontal) fy1 else fx1;
    const a2 = if (horizontal) fy2 else fx2;
    const b1 = if (horizontal) cy1 else cx1;
    const b2 = if (horizontal) cy2 else cx2;
    const overlaps = a1 < b2 and b1 < a2;
    const center_distance = if (a1 + a2 > b1 + b2) a1 + a2 - b1 - b2 else b1 + b2 - a1 - a2;
    return .{ .primary = primary, .secondary = center_distance + (if (overlaps) 0 else @as(u64, 1) << 63) };
}

test "mixed splits, ratios, and preorder are structural" {
    var tree = try Tree.init(std.testing.allocator, 10);
    defer tree.deinit();
    try tree.split(10, 20, 100, .left_right);
    try tree.split(10, 30, 101, .top_bottom);
    try tree.split(20, 40, 102, .top_bottom);
    try tree.setRatio(100, 40000);
    const items = try tree.flatten(std.testing.allocator);
    defer std.testing.allocator.free(items);
    try std.testing.expectEqual(@as(usize, 7), items.len);
    try std.testing.expectEqual(@as(SplitId, 100), items[0].split.id);
    try std.testing.expectEqual(@as(u16, 40000), items[0].split.ratio);
    try std.testing.expectEqual(@as(SplitId, 101), items[1].split.id);
    try std.testing.expectEqual(@as(u32, 7), items[0].split.subtree_size);
    try std.testing.expectEqual(@as(u32, 3), items[1].split.subtree_size);
    try std.testing.expectEqual(@as(PaneId, 10), items[2].leaf.id);
    try std.testing.expectEqual(@as(PaneId, 30), items[3].leaf.id);
    try std.testing.expectEqual(@as(SplitId, 102), items[4].split.id);
}

test "directional focus handles nested unequal splits and outside edges" {
    var tree = try Tree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, 2, 11, .left_right);
    try tree.setRatio(11, 20000);
    try tree.split(2, 3, 12, .top_bottom);
    try tree.setRatio(12, 45000);
    try std.testing.expect(!tree.focusDirection(.left));
    try std.testing.expect(tree.focusDirection(.right));
    try std.testing.expectEqual(@as(?PaneId, 2), tree.focused);
    try std.testing.expect(tree.focusDirection(.down));
    try std.testing.expectEqual(@as(?PaneId, 3), tree.focused);
    try std.testing.expect(!tree.focusDirection(.down));
    try std.testing.expect(tree.focusDirection(.left));
    try std.testing.expectEqual(@as(?PaneId, 1), tree.focused);
}

test "close collapses parents and selects preorder neighbor" {
    var tree = try Tree.init(std.testing.allocator, 1);
    defer tree.deinit();
    try tree.split(1, 2, 11, .left_right);
    try tree.split(2, 3, 12, .top_bottom);
    try std.testing.expect(tree.focus(2));
    try std.testing.expect(tree.close(2));
    try std.testing.expectEqual(@as(?PaneId, 1), tree.focused);
    try std.testing.expectError(error.SplitNotFound, tree.setRatio(12, 1));
    try std.testing.expect(tree.focus(1));
    try std.testing.expect(tree.close(1));
    try std.testing.expectEqual(@as(?PaneId, 3), tree.focused);
    try std.testing.expect(tree.close(3));
    try std.testing.expectEqual(@as(?PaneId, null), tree.focused);
    try std.testing.expect(!tree.close(3));
}

test "invalid duplicate and stale ids do not mutate the tree" {
    try std.testing.expectError(error.InvalidId, Tree.init(std.testing.allocator, 0));
    var tree = try Tree.init(std.testing.allocator, 7);
    defer tree.deinit();
    try std.testing.expectError(error.InvalidId, tree.split(7, 0, 1, .left_right));
    try std.testing.expectError(error.InvalidId, tree.split(7, 8, 0, .left_right));
    try tree.split(7, 8, 70, .left_right);
    try std.testing.expectError(error.DuplicateId, tree.split(7, 8, 71, .top_bottom));
    try std.testing.expectError(error.DuplicateId, tree.split(7, 9, 70, .top_bottom));
    try std.testing.expectError(error.PaneNotFound, tree.split(99, 9, 71, .top_bottom));
    try std.testing.expectError(error.SplitNotFound, tree.setRatio(99, 1));
    try std.testing.expect(!tree.focus(99));
    try std.testing.expectEqual(@as(?PaneId, 7), tree.focused);
}
