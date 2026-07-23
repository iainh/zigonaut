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

        return .{
            .terminal = terminal,
            .render_state = render_state,
            .row_iterator = row_iterator,
            .row_cells = row_cells,
        };
    }

    pub fn deinit(self: *Terminal) void {
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
