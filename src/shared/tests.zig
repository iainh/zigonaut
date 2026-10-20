const std = @import("std");
const shared = @import("root.zig");

const modules = .{
    shared.background_span,
    shared.decoration_path,
    shared.hint,
    shared.link,
    shared.pane_tree,
    shared.pseudographics,
    shared.search,
    shared.selection_path,
    shared.synchronized_output,
    shared.terminal,
    shared.text_runs,
    shared.theme,
};

test "shared declarations compile" {
    inline for (modules) |module| std.testing.refAllDecls(module);
}
