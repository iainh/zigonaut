const std = @import("std");
const theme = @import("theme.zig");

const vt = @cImport({
    @cDefine("GHOSTTY_STATIC", "1");
    @cInclude("ghostty/vt.h");
});

pub const Terminal = struct {
    terminal: vt.GhosttyTerminal,
    render_state: vt.GhosttyRenderState,
    row_iterator: vt.GhosttyRenderStateRowIterator,
    row_cells: vt.GhosttyRenderStateRowCells,
    key_encoder: vt.GhosttyKeyEncoder,
    key_event: vt.GhosttyKeyEvent,

    pub const Cell = struct {
        x: u16,
        y: u16,
        codepoints: []const u32,
        foreground: theme.Color,
        background: theme.Color,
        bold: bool,
        italic: bool,
    };

    pub const Frame = struct {
        foreground: theme.Color,
        background: theme.Color,
        cursor: theme.Color,
        cursor_visible: bool,
        cursor_x: u16,
        cursor_y: u16,
    };

    pub const Key = enum {
        escape,
        backspace,
        tab,
        enter,
        insert,
        delete,
        end,
        home,
        page_down,
        page_up,
        arrow_down,
        arrow_left,
        arrow_right,
        arrow_up,
        f1,
        f2,
        f3,
        f4,
        f5,
        f6,
        f7,
        f8,
        f9,
        f10,
        f11,
        f12,
    };

    pub const KeyAction = enum {
        press,
        repeat,
        release,
    };

    pub const Modifier = struct {
        pub const shift: u16 = 1 << 0;
        pub const control: u16 = 1 << 1;
        pub const alt: u16 = 1 << 2;
        pub const super: u16 = 1 << 3;
    };

    pub fn init(columns: u16, rows: u16, terminal_theme: theme.Theme) !Terminal {
        var terminal: vt.GhosttyTerminal = null;
        try check(vt.ghostty_terminal_new(null, &terminal, .{
            .cols = columns,
            .rows = rows,
            .max_scrollback = 10_000,
        }));
        errdefer vt.ghostty_terminal_free(terminal);

        var render_state: vt.GhosttyRenderState = null;
        try check(vt.ghostty_render_state_new(null, &render_state));
        errdefer vt.ghostty_render_state_free(render_state);

        var row_iterator: vt.GhosttyRenderStateRowIterator = null;
        try check(vt.ghostty_render_state_row_iterator_new(null, &row_iterator));
        errdefer vt.ghostty_render_state_row_iterator_free(row_iterator);

        var row_cells: vt.GhosttyRenderStateRowCells = null;
        try check(vt.ghostty_render_state_row_cells_new(null, &row_cells));
        errdefer vt.ghostty_render_state_row_cells_free(row_cells);

        var key_encoder: vt.GhosttyKeyEncoder = null;
        try check(vt.ghostty_key_encoder_new(null, &key_encoder));
        errdefer vt.ghostty_key_encoder_free(key_encoder);

        var key_event: vt.GhosttyKeyEvent = null;
        try check(vt.ghostty_key_event_new(null, &key_event));
        errdefer vt.ghostty_key_event_free(key_event);

        try applyTheme(terminal, terminal_theme);

        return .{
            .terminal = terminal,
            .render_state = render_state,
            .row_iterator = row_iterator,
            .row_cells = row_cells,
            .key_encoder = key_encoder,
            .key_event = key_event,
        };
    }

    pub fn deinit(self: *Terminal) void {
        vt.ghostty_key_event_free(self.key_event);
        vt.ghostty_key_encoder_free(self.key_encoder);
        vt.ghostty_render_state_row_cells_free(self.row_cells);
        vt.ghostty_render_state_row_iterator_free(self.row_iterator);
        vt.ghostty_render_state_free(self.render_state);
        vt.ghostty_terminal_free(self.terminal);
    }

    pub fn resize(self: *Terminal, columns: u16, rows: u16, cell_width: u32, cell_height: u32) !void {
        try check(vt.ghostty_terminal_resize(
            self.terminal,
            columns,
            rows,
            cell_width,
            cell_height,
        ));
    }

    pub fn feed(self: *Terminal, bytes: []const u8) void {
        vt.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    }

    pub fn renderViewport(self: *Terminal, renderer: anytype) !void {
        try check(vt.ghostty_render_state_update(self.render_state, self.terminal));

        var colors = std.mem.zeroes(vt.GhosttyRenderStateColors);
        colors.size = @sizeOf(vt.GhosttyRenderStateColors);
        try check(vt.ghostty_render_state_colors_get(self.render_state, &colors));
        var cursor_visible = false;
        var cursor_has_position = false;
        var cursor_x: u16 = 0;
        var cursor_y: u16 = 0;
        try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursor_visible));
        try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursor_has_position));
        if (cursor_has_position) {
            try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cursor_x));
            try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cursor_y));
        }
        const frame = Frame{
            .foreground = fromGhostty(colors.foreground),
            .background = fromGhostty(colors.background),
            .cursor = fromGhostty(if (colors.cursor_has_value) colors.cursor else colors.foreground),
            .cursor_visible = cursor_visible and cursor_has_position,
            .cursor_x = cursor_x,
            .cursor_y = cursor_y,
        };
        renderer.beginFrame(frame);

        try check(vt.ghostty_render_state_get(
            self.render_state,
            vt.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            @ptrCast(&self.row_iterator),
        ));
        var y: u16 = 0;
        while (vt.ghostty_render_state_row_iterator_next(self.row_iterator)) : (y += 1) {
            try check(vt.ghostty_render_state_row_get(
                self.row_iterator,
                vt.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                @ptrCast(&self.row_cells),
            ));
            var x: u16 = 0;
            while (vt.ghostty_render_state_row_cells_next(self.row_cells)) : (x += 1) {
                var style = std.mem.zeroes(vt.GhosttyStyle);
                style.size = @sizeOf(vt.GhosttyStyle);
                try check(vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE,
                    &style,
                ));
                var foreground = colors.foreground;
                var background = colors.background;
                if (vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR,
                    &foreground,
                ) != vt.GHOSTTY_SUCCESS) foreground = colors.foreground;
                if (style.bold and style.fg_color.tag == vt.GHOSTTY_STYLE_COLOR_PALETTE and style.fg_color.value.palette < 8) {
                    foreground = colors.palette[style.fg_color.value.palette + 8];
                }
                if (vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                    &background,
                ) != vt.GHOSTTY_SUCCESS) background = colors.background;
                if (style.inverse) std.mem.swap(vt.GhosttyColorRgb, &foreground, &background);

                var codepoint_count: u32 = 0;
                try check(vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    &codepoint_count,
                ));
                var codepoints: [16]u32 = undefined;
                const count: usize = @intCast(@min(codepoint_count, codepoints.len));
                if (count > 0 and codepoint_count <= codepoints.len) {
                    try check(vt.ghostty_render_state_row_cells_get(
                        self.row_cells,
                        vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                        &codepoints,
                    ));
                }
                renderer.drawCell(Cell{
                    .x = x,
                    .y = y,
                    .codepoints = if (style.invisible or codepoint_count > codepoints.len) codepoints[0..0] else codepoints[0..count],
                    .foreground = fromGhostty(foreground),
                    .background = fromGhostty(background),
                    .bold = style.bold,
                    .italic = style.italic,
                });
            }
        }
        renderer.endFrame(frame);
    }

    pub fn encodeKey(self: *Terminal, key: Key, action: KeyAction, modifiers: u16, output: []u8) ![]const u8 {
        vt.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.terminal);
        vt.ghostty_key_event_set_action(self.key_event, switch (action) {
            .press => vt.GHOSTTY_KEY_ACTION_PRESS,
            .repeat => vt.GHOSTTY_KEY_ACTION_REPEAT,
            .release => vt.GHOSTTY_KEY_ACTION_RELEASE,
        });
        vt.ghostty_key_event_set_key(self.key_event, switch (key) {
            .escape => vt.GHOSTTY_KEY_ESCAPE,
            .backspace => vt.GHOSTTY_KEY_BACKSPACE,
            .tab => vt.GHOSTTY_KEY_TAB,
            .enter => vt.GHOSTTY_KEY_ENTER,
            .insert => vt.GHOSTTY_KEY_INSERT,
            .delete => vt.GHOSTTY_KEY_DELETE,
            .end => vt.GHOSTTY_KEY_END,
            .home => vt.GHOSTTY_KEY_HOME,
            .page_down => vt.GHOSTTY_KEY_PAGE_DOWN,
            .page_up => vt.GHOSTTY_KEY_PAGE_UP,
            .arrow_down => vt.GHOSTTY_KEY_ARROW_DOWN,
            .arrow_left => vt.GHOSTTY_KEY_ARROW_LEFT,
            .arrow_right => vt.GHOSTTY_KEY_ARROW_RIGHT,
            .arrow_up => vt.GHOSTTY_KEY_ARROW_UP,
            .f1 => vt.GHOSTTY_KEY_F1,
            .f2 => vt.GHOSTTY_KEY_F2,
            .f3 => vt.GHOSTTY_KEY_F3,
            .f4 => vt.GHOSTTY_KEY_F4,
            .f5 => vt.GHOSTTY_KEY_F5,
            .f6 => vt.GHOSTTY_KEY_F6,
            .f7 => vt.GHOSTTY_KEY_F7,
            .f8 => vt.GHOSTTY_KEY_F8,
            .f9 => vt.GHOSTTY_KEY_F9,
            .f10 => vt.GHOSTTY_KEY_F10,
            .f11 => vt.GHOSTTY_KEY_F11,
            .f12 => vt.GHOSTTY_KEY_F12,
        });
        vt.ghostty_key_event_set_mods(self.key_event, modifiers);
        vt.ghostty_key_event_set_consumed_mods(self.key_event, 0);
        vt.ghostty_key_event_set_composing(self.key_event, false);
        vt.ghostty_key_event_set_utf8(self.key_event, null, 0);
        vt.ghostty_key_event_set_unshifted_codepoint(self.key_event, 0);

        var length: usize = 0;
        try check(vt.ghostty_key_encoder_encode(
            self.key_encoder,
            self.key_event,
            output.ptr,
            output.len,
            &length,
        ));
        return output[0..length];
    }

    pub fn writeViewportText(self: *Terminal, output: []u8) ![]const u8 {
        try check(vt.ghostty_render_state_update(self.render_state, self.terminal));
        try check(vt.ghostty_render_state_get(
            self.render_state,
            vt.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            @ptrCast(&self.row_iterator),
        ));

        var stream = std.io.fixedBufferStream(output);
        var row_index: usize = 0;
        while (vt.ghostty_render_state_row_iterator_next(self.row_iterator)) : (row_index += 1) {
            if (row_index != 0) try stream.writer().writeByte('\n');
            try check(vt.ghostty_render_state_row_get(
                self.row_iterator,
                vt.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                @ptrCast(&self.row_cells),
            ));

            while (vt.ghostty_render_state_row_cells_next(self.row_cells)) {
                var codepoint_count: u32 = 0;
                try check(vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    @ptrCast(&codepoint_count),
                ));
                if (codepoint_count == 0) {
                    try stream.writer().writeByte(' ');
                    continue;
                }

                var codepoints: [16]u32 = undefined;
                try check(vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                    @ptrCast(&codepoints),
                ));
                const count = @min(codepoint_count, codepoints.len);
                for (codepoints[0..count]) |codepoint| {
                    var encoded: [4]u8 = undefined;
                    const scalar = std.math.cast(u21, codepoint) orelse return error.InvalidCodepoint;
                    const length = try std.unicode.utf8Encode(scalar, &encoded);
                    try stream.writer().writeAll(encoded[0..length]);
                }
            }
            while (stream.pos > 0 and output[stream.pos - 1] == ' ') stream.pos -= 1;
        }

        return std.mem.trimRight(u8, stream.getWritten(), " \n");
    }
};

fn applyTheme(terminal: vt.GhosttyTerminal, value: theme.Theme) !void {
    var palette: [256]vt.GhosttyColorRgb = undefined;
    try check(vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_COLOR_PALETTE, &palette));
    for (value.ansi, 0..) |color, index| palette[index] = toGhostty(color);
    var foreground = toGhostty(value.foreground);
    var background = toGhostty(value.background);
    var cursor = toGhostty(value.cursor);
    try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground));
    try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background));
    try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor));
    try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, &palette));
}

fn toGhostty(color: theme.Color) vt.GhosttyColorRgb {
    return .{ .r = color.red, .g = color.green, .b = color.blue };
}

fn fromGhostty(color: vt.GhosttyColorRgb) theme.Color {
    return .{ .red = color.r, .green = color.g, .blue = color.b };
}

fn check(result: vt.GhosttyResult) !void {
    if (result != vt.GHOSTTY_SUCCESS) return error.LibGhosttyFailure;
}

test "libghostty parses control sequences into viewport state" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("plain \x1b[31mred\x1b[0m\r\nsecond");
    var buffer: [256]u8 = undefined;
    const viewport = try terminal.writeViewportText(&buffer);

    try std.testing.expectEqualStrings("plain red\nsecond", viewport);
}

test "render state resolves ANSI colors through the Rasmus theme" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("\x1b[31mX");
    var renderer = TestRenderer{};
    try terminal.renderViewport(&renderer);

    try std.testing.expectEqual(theme.rasmus.background, renderer.frame.?.background);
    try std.testing.expectEqual(theme.rasmus.ansi[1], renderer.x_foreground.?);
}

test "libghostty encodes navigation keys" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();

    var buffer: [64]u8 = undefined;
    const encoded = try terminal.encodeKey(.arrow_up, .press, 0, &buffer);
    try std.testing.expectEqualStrings("\x1b[A", encoded);
}

test "libghostty encodes physical special and function keys" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b", try terminal.encodeKey(.escape, .press, 0, &buffer));
    try std.testing.expectEqualStrings("\x1b[2~", try terminal.encodeKey(.insert, .press, 0, &buffer));
    try std.testing.expectEqualStrings("\x1bOP", try terminal.encodeKey(.f1, .press, 0, &buffer));
    try std.testing.expectEqual(@as(usize, 0), (try terminal.encodeKey(.f1, .release, 0, &buffer)).len);
}

const TestRenderer = struct {
    frame: ?Terminal.Frame = null,
    x_foreground: ?theme.Color = null,

    pub fn beginFrame(self: *TestRenderer, frame: Terminal.Frame) void {
        self.frame = frame;
    }

    pub fn drawCell(self: *TestRenderer, cell: Terminal.Cell) void {
        if (cell.codepoints.len == 1 and cell.codepoints[0] == 'X') self.x_foreground = cell.foreground;
    }

    pub fn endFrame(_: *TestRenderer, _: Terminal.Frame) void {}
};
