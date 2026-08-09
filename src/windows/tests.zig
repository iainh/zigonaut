const std = @import("std");
const shared = @import("shared");

const modules = .{
    @import("app.zig"),
    @import("chrome_bridge.zig"),
    @import("config.zig"),
    @import("directwrite_renderer.zig"),
    @import("gdi_renderer.zig"),
    @import("input.zig"),
    shared.pane_tree,
    @import("pty.zig"),
    shared.search,
    @import("session.zig"),
    @import("shell_quote.zig"),
    shared.terminal,
    @import("terminal_view.zig"),
    shared.theme,
    @import("win32.zig"),
};

test "public declarations compile" {
    inline for (modules) |module| std.testing.refAllDecls(module);
}

test {
    _ = @import("main.zig");
}
