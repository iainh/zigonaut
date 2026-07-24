const std = @import("std");

const modules = .{
    @import("app.zig"),
    @import("chrome_bridge.zig"),
    @import("config.zig"),
    @import("directwrite_renderer.zig"),
    @import("pty.zig"),
    @import("session.zig"),
    @import("terminal.zig"),
    @import("terminal_view.zig"),
    @import("theme.zig"),
    @import("win32.zig"),
};

test "public declarations compile" {
    inline for (modules) |module| std.testing.refAllDecls(module);
}

test {
    _ = @import("main.zig");
}
