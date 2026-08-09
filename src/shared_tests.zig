const std = @import("std");

const modules = .{
    @import("link.zig"),
    @import("pane_tree.zig"),
    @import("search.zig"),
    @import("terminal.zig"),
    @import("theme.zig"),
};

test "shared declarations compile" {
    inline for (modules) |module| std.testing.refAllDecls(module);
}
