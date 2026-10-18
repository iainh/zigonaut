const std = @import("std");
const shared = @import("shared");
const Terminal = shared.terminal.Terminal;
const allocator = std.heap.c_allocator;

pub extern fn main(c_int, [*][*:0]u8) c_int;

extern fn zgtk_write(?*anyopaque, [*]const u8, usize) void;
extern fn zgtk_title(?*anyopaque, [*]const u8, usize) void;
extern fn zgtk_clipboard(?*anyopaque, [*]const u8, usize) void;
extern fn zgtk_begin_frame(?*anyopaque, u32) void;
extern fn zgtk_draw_cell(?*anyopaque, u16, u16, u8, [*]const u8, usize, u32, u32, u32, u8) void;
extern fn zgtk_draw_cursor(?*anyopaque, u16, u16, u8, u8, u32) void;

const Core = struct {
    terminal: Terminal,
    host: ?*anyopaque,

    fn write(context: ?*anyopaque, bytes: []const u8) void {
        const self: *Core = @ptrCast(@alignCast(context.?));
        zgtk_write(self.host, bytes.ptr, bytes.len);
    }

    fn title(context: ?*anyopaque, bytes: []const u8) void {
        const self: *Core = @ptrCast(@alignCast(context.?));
        zgtk_title(self.host, bytes.ptr, bytes.len);
    }

    pub fn beginFrame(self: *Core, frame: Terminal.Frame) void {
        zgtk_begin_frame(self.host, colour(frame.background));
    }

    pub fn beginRow(_: *Core, _: u16) void {}
    pub fn endRow(_: *Core, _: u16) void {}

    pub fn drawCell(self: *Core, cell: Terminal.Cell) void {
        // The wide head paints both columns. Painting its tail would erase
        // the right half of the glyph that Pango just drew.
        if (cell.occupancy == .wide_tail) return;
        var buffer: [64]u8 = undefined;
        var length: usize = 0;
        for (cell.codepoints) |codepoint| {
            const scalar = std.math.cast(u21, codepoint) orelse continue;
            length += std.unicode.utf8Encode(scalar, buffer[length..][0..4]) catch continue;
        }
        const flags: u8 = @as(u8, @intFromBool(cell.bold)) |
            (@as(u8, @intFromBool(cell.italic)) << 1) |
            (@as(u8, @intFromBool(cell.underline != 0)) << 2) |
            (@as(u8, @intFromBool(cell.strikethrough)) << 3) |
            (@as(u8, @intFromBool(cell.faint)) << 4) |
            (@as(u8, @intFromBool(cell.selected)) << 5) |
            (@as(u8, @intFromBool(cell.overline)) << 6);
        zgtk_draw_cell(self.host, cell.x, cell.y, if (cell.occupancy == .wide) 2 else 1, &buffer, length, colour(cell.foreground), colour(cell.background), colour(cell.underline_color), flags);
    }

    pub fn endFrame(self: *Core, frame: Terminal.Frame) void {
        if (frame.cursor_visible) zgtk_draw_cursor(self.host, frame.cursor_x, frame.cursor_y, frame.cursor_columns, @intFromEnum(frame.cursor_style), colour(frame.cursor));
    }
};

fn colour(value: shared.theme.Color) u32 {
    return @as(u32, value.red) << 16 | @as(u32, value.green) << 8 | value.blue;
}

export fn zgtk_create(host: ?*anyopaque) ?*Core {
    const core = allocator.create(Core) catch return null;
    core.* = .{ .terminal = Terminal.init(80, 24, shared.theme.rasmus) catch {
        allocator.destroy(core);
        return null;
    }, .host = host };
    core.terminal.setWritePty(Core.write, core) catch {
        zgtk_destroy(core);
        return null;
    };
    core.terminal.setTitleChanged(Core.title, core) catch {
        zgtk_destroy(core);
        return null;
    };
    return core;
}

export fn zgtk_destroy(core: *Core) void {
    core.terminal.deinit();
    allocator.destroy(core);
}

export fn zgtk_feed(core: *Core, bytes: [*]const u8, length: usize) void {
    core.terminal.feed(bytes[0..length]);
}

export fn zgtk_resize(core: *Core, columns: u16, rows: u16, cell_width: u32, cell_height: u32) bool {
    core.terminal.resize(columns, rows, cell_width, cell_height) catch return false;
    return true;
}

export fn zgtk_render(core: *Core) bool {
    core.terminal.renderViewport(core) catch return false;
    return true;
}

// GDK key names are layout-aware; consumed modifiers must not become terminal
// modifiers (notably Shift for punctuation and AltGr for international text).
fn keyFromName(name: []const u8) ?Terminal.Key {
    if (name.len == 1) {
        const ch = std.ascii.toLower(name[0]);
        if (ch >= 'a' and ch <= 'z') return @enumFromInt(@intFromEnum(Terminal.Key.a) + ch - 'a');
        if (ch >= '0' and ch <= '9') return @enumFromInt(@intFromEnum(Terminal.Key.digit_0) + ch - '0');
    }
    const names = .{
        .{ "Return", "enter" },           .{ "Escape", "escape" },              .{ "BackSpace", "backspace" },
        .{ "Tab", "tab" },                .{ "ISO_Left_Tab", "tab" },           .{ "Up", "arrow_up" },
        .{ "Down", "arrow_down" },        .{ "Left", "arrow_left" },            .{ "Right", "arrow_right" },
        .{ "Home", "home" },              .{ "End", "end" },                    .{ "Page_Up", "page_up" },
        .{ "Page_Down", "page_down" },    .{ "Insert", "insert" },              .{ "Delete", "delete" },
        .{ "space", "space" },            .{ "KP_Enter", "numpad_enter" },      .{ "grave", "backquote" },
        .{ "asciitilde", "backquote" },   .{ "minus", "minus" },                .{ "underscore", "minus" },
        .{ "equal", "equal" },            .{ "plus", "equal" },                 .{ "bracketleft", "bracket_left" },
        .{ "braceleft", "bracket_left" }, .{ "bracketright", "bracket_right" }, .{ "braceright", "bracket_right" },
        .{ "backslash", "backslash" },    .{ "bar", "backslash" },              .{ "semicolon", "semicolon" },
        .{ "colon", "semicolon" },        .{ "apostrophe", "quote" },           .{ "quotedbl", "quote" },
        .{ "comma", "comma" },            .{ "less", "comma" },                 .{ "period", "period" },
        .{ "greater", "period" },         .{ "slash", "slash" },                .{ "question", "slash" },
        .{ "exclam", "digit_1" },         .{ "at", "digit_2" },                 .{ "numbersign", "digit_3" },
        .{ "dollar", "digit_4" },         .{ "percent", "digit_5" },            .{ "asciicircum", "digit_6" },
        .{ "ampersand", "digit_7" },      .{ "asterisk", "digit_8" },           .{ "parenleft", "digit_9" },
        .{ "parenright", "digit_0" },
    };
    inline for (names) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return @field(Terminal.Key, entry[1]);
    }
    if (name.len >= 2 and name[0] == 'F') {
        const number = std.fmt.parseInt(u8, name[1..], 10) catch return null;
        if (number >= 1 and number <= 24) return @enumFromInt(@intFromEnum(Terminal.Key.f1) + number - 1);
    }
    return null;
}

export fn zgtk_key(core: *Core, name: [*:0]const u8, modifiers: u16, consumed: u16, text: [*]const u8, length: usize, release: bool) bool {
    const key = keyFromName(std.mem.span(name)) orelse {
        if (!release and length != 0) {
            _ = core.terminal.scrollToBottom() catch return false;
            core.terminal.setSelection(null) catch return false;
            zgtk_write(core.host, text, length);
        }
        return true;
    };
    const action: Terminal.KeyAction = if (release) .release else .press;
    if (core.terminal.handleScrollbackKey(key, action, modifiers) catch return false) return true;
    var output: [512]u8 = undefined;
    const bytes = core.terminal.encodeKey(key, action, modifiers, consumed, text[0..length], if (length == 1) std.ascii.toLower(text[0]) else 0, &output) catch return false;
    if (!release and bytes.len != 0) {
        _ = core.terminal.scrollToBottom() catch return false;
        core.terminal.setSelection(null) catch return false;
    }
    zgtk_write(core.host, bytes.ptr, bytes.len);
    return true;
}

export fn zgtk_paste(core: *Core, text: [*]const u8, length: usize) bool {
    const mutable = allocator.dupe(u8, text[0..length]) catch return false;
    defer allocator.free(mutable);
    const bytes = core.terminal.encodePasteAlloc(allocator, mutable) catch return false;
    defer allocator.free(bytes);
    _ = core.terminal.scrollToBottom() catch return false;
    zgtk_write(core.host, bytes.ptr, bytes.len);
    return true;
}

export fn zgtk_scroll(core: *Core, lines: c_int) void {
    core.terminal.scrollViewport(lines);
}

export fn zgtk_focus(core: *Core, focused: bool) void {
    core.terminal.setFocused(focused);
}

export fn zgtk_select(core: *Core, x: u16, y: u16, begin: bool, rectangle: bool) bool {
    const point: Terminal.Point = .{ .x = @min(x, core.terminal.columns - 1), .y = @min(y, core.terminal.rows - 1) };
    if (begin) core.terminal.beginSelectionAnchor(point) catch return false;
    core.terminal.setDerivedSelection(point, .cell, rectangle) catch return false;
    return true;
}

export fn zgtk_copy(core: *Core) void {
    if (!core.terminal.hasSelection()) return;
    const text = core.terminal.selectedTextAlloc(allocator) catch return;
    defer allocator.free(text);
    zgtk_clipboard(core.host, text.ptr, text.len);
}
