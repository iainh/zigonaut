const std = @import("std");

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

    pub const Key = enum {
        delete,
        end,
        home,
        page_down,
        page_up,
        arrow_down,
        arrow_left,
        arrow_right,
        arrow_up,
    };

    pub const Modifier = struct {
        pub const shift: u16 = 1 << 0;
        pub const control: u16 = 1 << 1;
        pub const alt: u16 = 1 << 2;
        pub const super: u16 = 1 << 3;
    };

    pub fn init(columns: u16, rows: u16) !Terminal {
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

    pub fn encodeKey(self: *Terminal, key: Key, repeat: bool, modifiers: u16, output: []u8) ![]const u8 {
        vt.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.terminal);
        vt.ghostty_key_event_set_action(
            self.key_event,
            if (repeat) vt.GHOSTTY_KEY_ACTION_REPEAT else vt.GHOSTTY_KEY_ACTION_PRESS,
        );
        vt.ghostty_key_event_set_key(self.key_event, switch (key) {
            .delete => vt.GHOSTTY_KEY_DELETE,
            .end => vt.GHOSTTY_KEY_END,
            .home => vt.GHOSTTY_KEY_HOME,
            .page_down => vt.GHOSTTY_KEY_PAGE_DOWN,
            .page_up => vt.GHOSTTY_KEY_PAGE_UP,
            .arrow_down => vt.GHOSTTY_KEY_ARROW_DOWN,
            .arrow_left => vt.GHOSTTY_KEY_ARROW_LEFT,
            .arrow_right => vt.GHOSTTY_KEY_ARROW_RIGHT,
            .arrow_up => vt.GHOSTTY_KEY_ARROW_UP,
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

fn check(result: vt.GhosttyResult) !void {
    if (result != vt.GHOSTTY_SUCCESS) return error.LibGhosttyFailure;
}

test "libghostty parses control sequences into viewport state" {
    var terminal = try Terminal.init(20, 3);
    defer terminal.deinit();

    terminal.feed("plain \x1b[31mred\x1b[0m\r\nsecond");
    var buffer: [256]u8 = undefined;
    const viewport = try terminal.writeViewportText(&buffer);

    try std.testing.expectEqualStrings("plain red\nsecond", viewport);
}

test "libghostty encodes navigation keys" {
    var terminal = try Terminal.init(20, 3);
    defer terminal.deinit();

    var buffer: [64]u8 = undefined;
    const encoded = try terminal.encodeKey(.arrow_up, false, 0, &buffer);
    try std.testing.expectEqualStrings("\x1b[A", encoded);
}
