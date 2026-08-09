const std = @import("std");
const shared = @import("root.zig");

const modules = .{
    shared.link,
    shared.pane_tree,
    shared.search,
    shared.terminal,
    shared.theme,
};

test "shared declarations compile" {
    inline for (modules) |module| std.testing.refAllDecls(module);
}
