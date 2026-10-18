const std = @import("std");
const c = @cImport(@cInclude("core.h"));
comptime {
    _ = @import("core.zig");
}

const Capture = struct {
    output: std.Io.Writer.Allocating = .init(std.testing.allocator),
    clipboard: std.Io.Writer.Allocating = .init(std.testing.allocator),
    title: std.Io.Writer.Allocating = .init(std.testing.allocator),
    first_row: [80]u8 = @splat(' '),
    wide_columns: u8 = 0,
    red_cell: bool = false,

    fn deinit(self: *Capture) void {
        self.output.deinit();
        self.clipboard.deinit();
        self.title.deinit();
    }
};

fn capture(host: ?*anyopaque) *Capture {
    return @ptrCast(@alignCast(host.?));
}

export fn zgtk_write(host: ?*anyopaque, bytes: [*]const u8, length: usize) void {
    capture(host).output.writer.writeAll(bytes[0..length]) catch unreachable;
}
export fn zgtk_title(host: ?*anyopaque, bytes: [*]const u8, length: usize) void {
    capture(host).title.writer.writeAll(bytes[0..length]) catch unreachable;
}
export fn zgtk_clipboard(host: ?*anyopaque, bytes: [*]const u8, length: usize) void {
    capture(host).clipboard.writer.writeAll(bytes[0..length]) catch unreachable;
}
export fn zgtk_begin_frame(host: ?*anyopaque, _: u32) void {
    capture(host).first_row = @splat(' ');
}
export fn zgtk_draw_cell(host: ?*anyopaque, x: u16, y: u16, columns: u8, text: [*]const u8, length: usize, foreground: u32, _: u32, _: u32, _: u8) void {
    const state = capture(host);
    if (y == 0 and x < 80 and length == 1) state.first_row[x] = text[0];
    if (length == 3 and std.mem.eql(u8, text[0..length], "界")) state.wide_columns = columns;
    if (length == 1 and text[0] == 'R' and foreground == 0xff0000) state.red_cell = true;
}
export fn zgtk_draw_cursor(_: ?*anyopaque, _: u16, _: u16, _: u8, _: u8, _: u32) void {}

fn feed(core: *c.TerminalCore, bytes: []const u8) !void {
    c.zgtk_feed(core, bytes.ptr, bytes.len);
}

test "Linux input respects terminal modes, modifiers, UTF-8 and paste framing" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_key(core, "c", 2, 0, "c", 1, false));
    try std.testing.expect(c.zgtk_key(core, "Up", 0, 0, "", 0, false));
    try feed(core, "\x1b[?1h");
    try std.testing.expect(c.zgtk_key(core, "Up", 0, 0, "", 0, false));
    try std.testing.expect(c.zgtk_key(core, "plus", 1, 1, "+", 1, false));
    try std.testing.expect(c.zgtk_key(core, "EuroSign", 6, 6, "€", 3, false));
    try std.testing.expect(c.zgtk_key(core, "a", 0, 0, "", 0, true));
    try std.testing.expect(c.zgtk_paste(core, "one\ntwo", 7));
    try feed(core, "\x1b[?2004h");
    try std.testing.expect(c.zgtk_paste(core, "three\nfour", 10));
    try std.testing.expectEqualStrings("\x03\x1b[A\x1bOA+€one\rtwo\x1b[200~three\nfour\x1b[201~", state.output.written());
}

test "Linux rendering, selection and titles preserve terminal data across resize" {
    var state = Capture{};
    defer state.deinit();
    const core = c.zgtk_create(&state) orelse return error.InitFailed;
    defer c.zgtk_destroy(core);
    try std.testing.expect(c.zgtk_resize(core, 31, 7, 10, 19));
    try feed(core, "Alpha \x1b[38;2;255;0;0mR\x1b[0m 界\r\nBeta\x1b]2;Linux shell\x07");
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expect(state.red_cell);
    try std.testing.expectEqual(@as(u8, 2), state.wide_columns);
    try std.testing.expectEqualStrings("Alpha R ", state.first_row[0..8]);
    try std.testing.expectEqualStrings("Linux shell", state.title.written());
    try std.testing.expect(c.zgtk_select(core, 4, 0, true, false));
    try std.testing.expect(c.zgtk_select(core, 1, 0, false, false));
    c.zgtk_copy(core);
    try std.testing.expectEqualStrings("lpha", state.clipboard.written());
    try std.testing.expect(c.zgtk_resize(core, 47, 12, 10, 19));
    try std.testing.expect(c.zgtk_render(core));
    try std.testing.expectEqualStrings("Alpha R ", state.first_row[0..8]);
}
