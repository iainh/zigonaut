const std = @import("std");
const panes = @import("shared").pane_tree;
const allocator = std.heap.c_allocator;

// Main-thread confined, like the native window model. Native terminal objects
// never cross this ABI; IDs are assigned by its UUID registry, not UUID hashes.
export fn zigonaut_panes_create(nodes: [*]const panes.LayoutNode, count: usize) ?*panes.Tree {
    const tree = allocator.create(panes.Tree) catch return null;
    tree.* = panes.Tree.fromPreorder(allocator, nodes[0..count]) catch {
        allocator.destroy(tree);
        return null;
    };
    return tree;
}

export fn zigonaut_panes_destroy(tree: *panes.Tree) void {
    tree.deinit();
    allocator.destroy(tree);
}

export fn zigonaut_panes_split(tree: *panes.Tree, target: u64, pane: u64, split: u64, vertical: bool) bool {
    tree.split(target, pane, split, if (vertical) .top_bottom else .left_right) catch return false;
    _ = tree.focus(pane);
    return true;
}

export fn zigonaut_panes_move(tree: *panes.Tree, source: u64, target: u64, split: u64, edge: u8) bool {
    if (edge > 3) return false;
    tree.movePane(source, target, split, @fromBackingInt(@intCast(edge))) catch return false;
    return true;
}

export fn zigonaut_panes_close(tree: *panes.Tree, pane: u64) bool {
    // Closing the final pane is a native tab/window operation. Preserve macOS's
    // first-remaining-pane focus policy, rather than Linux's neighbour policy.
    if (tree.nodeCount() <= 1 or !tree.close(pane)) return false;
    var nodes: [panes.max_panes * 2 - 1]panes.LayoutNode = undefined;
    var writer = panes.LayoutWriter{ .output = &nodes };
    tree.writePreorder(&writer) catch unreachable;
    for (nodes[0..writer.index]) |node| if (!node.split) {
        _ = tree.focus(node.id);
        break;
    };
    return true;
}

export fn zigonaut_panes_focus(tree: *panes.Tree, pane: u64) bool {
    return tree.focus(pane);
}
export fn zigonaut_panes_focused(tree: *const panes.Tree) u64 {
    return tree.focused orelse 0;
}
export fn zigonaut_panes_zoomed(tree: *const panes.Tree) u64 {
    return tree.zoomed orelse 0;
}
// Same action numbers as Linux: directional focus, cycle, resize, equalize, zoom.
export fn zigonaut_panes_action(tree: *panes.Tree, action: u8) bool {
    return switch (action) {
        4, 5 => tree.focusCycle(action == 5),
        6...9 => tree.resizeFocused(@fromBackingInt(@intCast(action - 6)), 3277),
        10 => tree.equalize(),
        11 => tree.toggleZoom(),
        else => false,
    };
}
export fn zigonaut_panes_can_resize(tree: *const panes.Tree, direction: u8) bool {
    return direction <= 3 and tree.canResize(@fromBackingInt(@intCast(direction)));
}
export fn zigonaut_panes_ratio(tree: *panes.Tree, split: u64, ratio: u16) bool {
    tree.setRatio(split, ratio) catch return false;
    return true;
}
export fn zigonaut_panes_nodes(tree: *const panes.Tree, nodes: [*]panes.LayoutNode, capacity: usize) usize {
    const count = tree.nodeCount();
    if (capacity < count) return count;
    var writer = panes.LayoutWriter{ .output = nodes[0..capacity] };
    tree.writePreorder(&writer) catch unreachable;
    return count;
}
export fn zigonaut_panes_destination(source: u64, direction: u8, frames: [*]const panes.MeasuredPane, count: usize) u64 {
    if (direction > 3) return 0;
    return panes.measuredDestination(source, @fromBackingInt(@intCast(direction)), frames[0..count]) orelse 0;
}
export fn zigonaut_panes_drop_edge(x: f64, y: f64, width: f64, height: f64) i8 {
    return if (panes.nearestDropEdge(x, y, width, height)) |edge| @intCast(@backingInt(edge)) else -1;
}
