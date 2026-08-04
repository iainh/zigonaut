const std = @import("std");
const link = @import("link.zig");
const theme = @import("theme.zig");
const SearchMatch = @import("search.zig").Match;

const vt = @cImport({
    @cDefine("GHOSTTY_STATIC", "1");
    @cInclude("ghostty/vt.h");
});
const image_native = @import("win32.zig").c;

// Bound both encoded and decoded images. Terminal output is untrusted and can
// otherwise make the process retain an unbounded amount of image data.
const kitty_image_limit: usize = 32 * 1024 * 1024;
var decode_png_mutex: @import("win32.zig").Mutex = .{};
var decode_png_installed = false;

fn installDecodePng() !void {
    decode_png_mutex.lock();
    defer decode_png_mutex.unlock();
    if (decode_png_installed) return;
    try check(vt.ghostty_sys_set(vt.GHOSTTY_SYS_OPT_DECODE_PNG, @as(vt.GhosttySysDecodePngFn, decodePng)));
    decode_png_installed = true;
}

pub const Terminal = struct {
    terminal: vt.GhosttyTerminal,
    render_state: vt.GhosttyRenderState,
    row_iterator: vt.GhosttyRenderStateRowIterator,
    row_cells: vt.GhosttyRenderStateRowCells,
    key_encoder: vt.GhosttyKeyEncoder,
    key_event: vt.GhosttyKeyEvent,
    mouse_encoder: vt.GhosttyMouseEncoder,
    mouse_event: vt.GhosttyMouseEvent,
    selection_anchor: vt.GhosttyTrackedGridRef = null,
    write_pty: ?WritePty = null,
    write_pty_context: ?*anyopaque = null,
    title_changed: ?TitleChanged = null,
    title_context: ?*anyopaque = null,
    clipboard_write: ?ClipboardWrite = null,
    clipboard_context: ?*anyopaque = null,
    desktop_notification: ?DesktopNotification = null,
    desktop_notification_context: ?*anyopaque = null,
    progress_report: ?ProgressReport = null,
    progress_report_context: ?*anyopaque = null,
    columns: u16,
    rows: u16,

    pub const WritePty = *const fn (?*anyopaque, []const u8) void;
    pub const TitleChanged = *const fn (?*anyopaque, []const u8) void;
    pub const ClipboardWrite = *const fn (?*anyopaque, ClipboardWriteOperation) ClipboardWriteResult;
    pub const ClipboardWriteOperation = union(enum) { clear, text: []const u8 };
    pub const ClipboardWriteResult = enum { success, denied, unsupported, busy, invalid_data, io_error };
    pub const DesktopNotification = *const fn (?*anyopaque, []const u8, []const u8) void;
    pub const ProgressReport = *const fn (?*anyopaque, ProgressUpdate) void;
    pub const ProgressUpdate = union(enum) {
        remove,
        report: struct {
            state: ProgressState,
            value: ?u8,
        },
    };
    pub const ProgressState = enum {
        normal,
        error_state,
        indeterminate,
        paused,
    };

    pub const Cell = struct {
        pub const Occupancy = enum(u8) {
            narrow,
            wide,
            wide_tail,
            wrap_spacer,
        };

        x: u16,
        y: u16,
        occupancy: Occupancy,
        codepoints: []const u32,
        foreground: theme.Color,
        background: theme.Color,
        underline_color: theme.Color,
        bold: bool,
        italic: bool,
        faint: bool,
        strikethrough: bool,
        overline: bool,
        underline: u8,
        selected: bool,
    };

    pub const Point = struct {
        x: u16,
        y: u16,
    };

    pub const Selection = struct {
        anchor: Point,
        focus: Point,
        rectangle: bool = false,
    };

    pub const SelectionUnit = enum { cell, word, line };
    pub const PixelPoint = struct { x: i32, y: i32 };
    pub const MouseGeometry = struct {
        screen_width: u32,
        screen_height: u32,
        cell_width: u32,
        cell_height: u32,
        padding_top: u32,
        padding_bottom: u32,
        padding_left: u32,
        padding_right: u32,
    };
    pub const MouseAction = enum { press, release, motion };
    pub const MouseButton = enum { none, left, middle, right, wheel_up, wheel_down, wheel_left, wheel_right };

    pub const Frame = struct {
        pub const CursorStyle = enum(u8) {
            bar,
            block,
            underline,
            hollow,
        };

        foreground: theme.Color,
        background: theme.Color,
        cursor: theme.Color,
        cursor_style: CursorStyle,
        cursor_visible: bool,
        cursor_has_position: bool,
        cursor_x: u16,
        cursor_y: u16,
        cursor_columns: u8,
    };

    pub const Image = struct {
        image_id: u32,
        generation: u64,
        pixels: []const u8,
        width: u32,
        height: u32,
        source_x: u32,
        source_y: u32,
        source_width: u32,
        source_height: u32,
        pixel_width: u32,
        pixel_height: u32,
        viewport_col: i32,
        viewport_row: i32,
        x_offset: u32,
        y_offset: u32,
        z: i32,
    };

    pub const RenderSnapshot = struct {
        frame: ?Frame = null,
        cells: std.ArrayList(OwnedCell) = .empty,
        rows: std.ArrayList(Row) = .empty,
        images: std.ArrayList(OwnedImage) = .empty,
        placements: std.ArrayList(Placement) = .empty,

        const OwnedImage = struct {
            image_id: u32,
            generation: u64,
            width: u32,
            height: u32,
            pixels: []u8,
        };

        const Placement = struct {
            image_index: usize,
            image_id: u32,
            source_x: u32,
            source_y: u32,
            source_width: u32,
            source_height: u32,
            pixel_width: u32,
            pixel_height: u32,
            viewport_col: i32,
            viewport_row: i32,
            x_offset: u32,
            y_offset: u32,
            z: i32,
        };

        const Row = struct {
            graphemes: std.ArrayList(u32) = .empty,
            dirty: bool = false,
        };

        const OwnedCell = struct {
            codepoint_offset: u32,
            foreground: theme.Color,
            background: theme.Color,
            underline_color: theme.Color,
            codepoint_count: u8,
            attributes: packed struct(u16) {
                occupancy: u2,
                bold: bool,
                italic: bool,
                faint: bool,
                strikethrough: bool,
                overline: bool,
                selected: bool,
                underline: u8,
            },

            fn init(cell: Cell, codepoint_offset: u32) OwnedCell {
                return .{
                    .codepoint_offset = codepoint_offset,
                    .foreground = cell.foreground,
                    .background = cell.background,
                    .underline_color = cell.underline_color,
                    .codepoint_count = @intCast(@min(cell.codepoints.len, 16)),
                    .attributes = .{
                        .occupancy = @intCast(@intFromEnum(cell.occupancy)),
                        .bold = cell.bold,
                        .italic = cell.italic,
                        .faint = cell.faint,
                        .strikethrough = cell.strikethrough,
                        .overline = cell.overline,
                        .selected = cell.selected,
                        .underline = cell.underline,
                    },
                };
            }

            fn codepoints(self: *const OwnedCell, row: *const Row) []const u32 {
                return row.graphemes.items[self.codepoint_offset..][0..self.codepoint_count];
            }

            fn value(self: *const OwnedCell, row: *const Row, x: u16, y: u16) Cell {
                return .{
                    .x = x,
                    .y = y,
                    .occupancy = @enumFromInt(self.attributes.occupancy),
                    .codepoints = self.codepoints(row),
                    .foreground = self.foreground,
                    .background = self.background,
                    .underline_color = self.underline_color,
                    .bold = self.attributes.bold,
                    .italic = self.attributes.italic,
                    .faint = self.attributes.faint,
                    .strikethrough = self.attributes.strikethrough,
                    .overline = self.attributes.overline,
                    .underline = self.attributes.underline,
                    .selected = self.attributes.selected,
                };
            }
        };

        pub const cell_size = @sizeOf(OwnedCell);

        const Recorder = struct {
            snapshot: *RenderSnapshot,
            allocator: std.mem.Allocator,

            pub fn beginFrame(self: *Recorder, frame: Frame) void {
                self.snapshot.frame = frame;
            }

            pub fn beginRow(self: *Recorder, y: u16) void {
                self.snapshot.rows.items[y].dirty = true;
                self.snapshot.rows.items[y].graphemes.clearRetainingCapacity();
            }

            pub fn drawCell(self: *Recorder, cell: Cell) !void {
                const row = &self.snapshot.rows.items[cell.y];
                const count = @min(cell.codepoints.len, 16);
                const offset: u32 = @intCast(row.graphemes.items.len);
                try row.graphemes.appendSlice(self.allocator, cell.codepoints[0..count]);
                const index = @as(usize, cell.y) * self.snapshot.columns() + cell.x;
                self.snapshot.cells.items[index] = .init(cell, offset);
            }

            pub fn endRow(_: *Recorder, _: u16) void {}

            pub fn endFrame(_: *Recorder, _: Frame) void {}
        };

        pub fn deinit(self: *RenderSnapshot, allocator: std.mem.Allocator) void {
            for (self.rows.items) |*row| row.graphemes.deinit(allocator);
            self.cells.deinit(allocator);
            self.rows.deinit(allocator);
            self.clearImages(allocator);
            self.images.deinit(allocator);
            self.placements.deinit(allocator);
            self.* = .{};
        }

        pub fn capture(self: *RenderSnapshot, allocator: std.mem.Allocator, terminal: *Terminal) !void {
            const cell_count = @as(usize, terminal.columns) * @as(usize, terminal.rows);
            const resized = self.cells.items.len != cell_count or self.rows.items.len != terminal.rows;
            if (resized) {
                var replacement = RenderSnapshot{};
                errdefer replacement.deinit(allocator);
                try replacement.cells.resize(allocator, cell_count);
                try replacement.rows.resize(allocator, terminal.rows);
                for (replacement.rows.items) |*row| row.* = .{};
                for (replacement.rows.items) |*row|
                    try row.graphemes.ensureTotalCapacity(allocator, terminal.columns);
                var recorder = Recorder{ .snapshot = &replacement, .allocator = allocator };
                try terminal.renderViewportInternal(&recorder, null);
                for (replacement.rows.items) |*row| row.dirty = true;
                try replacement.captureImages(allocator, terminal);
                self.deinit(allocator);
                self.* = replacement;
                return;
            }
            const previous_frame = self.frame;
            for (self.rows.items) |*row| row.dirty = false;
            var recorder = Recorder{ .snapshot = self, .allocator = allocator };
            terminal.renderViewportInternal(&recorder, self.frame) catch |err| {
                // A row arena may have been partially rebuilt. Force the next
                // successful capture to replace every row before replaying it.
                self.frame = null;
                return err;
            };
            if (previous_frame) |previous| {
                const current = self.frame.?;
                if (cursorChanged(previous, current)) {
                    if (previous.cursor_has_position and previous.cursor_y < self.rows.items.len)
                        self.rows.items[previous.cursor_y].dirty = true;
                    if (current.cursor_has_position and current.cursor_y < self.rows.items.len)
                        self.rows.items[current.cursor_y].dirty = true;
                }
            }
            self.captureImages(allocator, terminal) catch |err| {
                // Dirty flags were consumed while rebuilding rows. Force the
                // next capture to replace the complete snapshot.
                self.frame = null;
                return err;
            };
        }

        fn cursorChanged(previous: Frame, current: Frame) bool {
            return previous.cursor_has_position != current.cursor_has_position or
                previous.cursor_x != current.cursor_x or previous.cursor_y != current.cursor_y or
                previous.cursor_visible != current.cursor_visible or
                previous.cursor_style != current.cursor_style or
                !std.meta.eql(previous.cursor, current.cursor) or
                previous.cursor_columns != current.cursor_columns;
        }

        fn clearImages(self: *RenderSnapshot, allocator: std.mem.Allocator) void {
            for (self.images.items) |image| allocator.free(image.pixels);
            self.images.clearRetainingCapacity();
            self.placements.clearRetainingCapacity();
        }

        fn captureImages(self: *RenderSnapshot, allocator: std.mem.Allocator, terminal: *Terminal) !void {
            self.clearImages(allocator);
            errdefer self.clearImages(allocator);
            var graphics: vt.GhosttyKittyGraphics = null;
            if (vt.ghostty_terminal_get(terminal.terminal, vt.GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, @ptrCast(&graphics)) != vt.GHOSTTY_SUCCESS or graphics == null) return;
            var iterator: vt.GhosttyKittyGraphicsPlacementIterator = null;
            try check(vt.ghostty_kitty_graphics_placement_iterator_new(null, &iterator));
            defer vt.ghostty_kitty_graphics_placement_iterator_free(iterator);
            try check(vt.ghostty_kitty_graphics_get(graphics, vt.GHOSTTY_KITTY_GRAPHICS_DATA_PLACEMENT_ITERATOR, @ptrCast(&iterator)));
            while (vt.ghostty_kitty_graphics_placement_next(iterator)) {
                var image_id: u32 = 0;
                var virtual = false;
                var z: i32 = 0;
                var x_offset: u32 = 0;
                var y_offset: u32 = 0;
                try check(vt.ghostty_kitty_graphics_placement_get(iterator, vt.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IMAGE_ID, &image_id));
                try check(vt.ghostty_kitty_graphics_placement_get(iterator, vt.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_IS_VIRTUAL, &virtual));
                try check(vt.ghostty_kitty_graphics_placement_get(iterator, vt.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Z, &z));
                // Virtual placements are references only. Negative-z images
                // must be behind text, but this renderer composites after text.
                if (virtual or z < 0) continue;
                _ = vt.ghostty_kitty_graphics_placement_get(iterator, vt.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_X_OFFSET, &x_offset);
                _ = vt.ghostty_kitty_graphics_placement_get(iterator, vt.GHOSTTY_KITTY_GRAPHICS_PLACEMENT_DATA_Y_OFFSET, &y_offset);
                const handle = vt.ghostty_kitty_graphics_image(graphics, image_id) orelse continue;
                var width: u32 = 0;
                var height: u32 = 0;
                var generation: u64 = 0;
                var format: vt.GhosttyKittyImageFormat = vt.GHOSTTY_KITTY_IMAGE_FORMAT_RGB;
                var data_ptr: [*c]const u8 = null;
                var data_len: usize = 0;
                if (vt.ghostty_kitty_graphics_image_get(handle, vt.GHOSTTY_KITTY_IMAGE_DATA_WIDTH, &width) != vt.GHOSTTY_SUCCESS or
                    vt.ghostty_kitty_graphics_image_get(handle, vt.GHOSTTY_KITTY_IMAGE_DATA_HEIGHT, &height) != vt.GHOSTTY_SUCCESS or
                    vt.ghostty_kitty_graphics_image_get(handle, vt.GHOSTTY_KITTY_IMAGE_DATA_GENERATION, &generation) != vt.GHOSTTY_SUCCESS or
                    vt.ghostty_kitty_graphics_image_get(handle, vt.GHOSTTY_KITTY_IMAGE_DATA_FORMAT, &format) != vt.GHOSTTY_SUCCESS or
                    vt.ghostty_kitty_graphics_image_get(handle, vt.GHOSTTY_KITTY_IMAGE_DATA_DATA_PTR, @ptrCast(&data_ptr)) != vt.GHOSTTY_SUCCESS or
                    vt.ghostty_kitty_graphics_image_get(handle, vt.GHOSTTY_KITTY_IMAGE_DATA_DATA_LEN, &data_len) != vt.GHOSTTY_SUCCESS) continue;
                const expected = std.math.mul(usize, std.math.mul(usize, width, height) catch continue, 4) catch continue;
                if (format != vt.GHOSTTY_KITTY_IMAGE_FORMAT_RGBA or expected != data_len or data_len > kitty_image_limit or data_ptr == null) continue;
                var info: vt.GhosttyKittyGraphicsPlacementRenderInfo = std.mem.zeroes(vt.GhosttyKittyGraphicsPlacementRenderInfo);
                info.size = @sizeOf(vt.GhosttyKittyGraphicsPlacementRenderInfo);
                if (vt.ghostty_kitty_graphics_placement_render_info(iterator, handle, terminal.terminal, &info) != vt.GHOSTTY_SUCCESS or !info.viewport_visible) continue;
                if (info.source_x > width or info.source_y > height or info.source_width > width - info.source_x or info.source_height > height - info.source_y) continue;
                var image_index: ?usize = null;
                for (self.images.items, 0..) |image, index| {
                    if (image.image_id == image_id) {
                        image_index = index;
                        break;
                    }
                }
                if (image_index == null) {
                    const pixels = try allocator.dupe(u8, data_ptr[0..data_len]);
                    self.images.append(allocator, .{
                        .image_id = image_id,
                        .generation = generation,
                        .width = width,
                        .height = height,
                        .pixels = pixels,
                    }) catch |err| {
                        allocator.free(pixels);
                        return err;
                    };
                    image_index = self.images.items.len - 1;
                }
                try self.placements.append(allocator, .{
                    .image_index = image_index.?,
                    .image_id = image_id,
                    .source_x = info.source_x,
                    .source_y = info.source_y,
                    .source_width = info.source_width,
                    .source_height = info.source_height,
                    .pixel_width = info.pixel_width,
                    .pixel_height = info.pixel_height,
                    .viewport_col = info.viewport_col,
                    .viewport_row = info.viewport_row,
                    .x_offset = x_offset,
                    .y_offset = y_offset,
                    .z = z,
                });
            }
            // libghostty's placement iterator is hash ordered, which is not a
            // stable compositing order. Keep equal-z images deterministic too.
            sortPlacements(self.placements.items);
        }

        fn sortPlacements(placements_to_sort: []Placement) void {
            var index: usize = 1;
            while (index < placements_to_sort.len) : (index += 1) {
                var current = index;
                while (current > 0 and placementLessThan(placements_to_sort[current], placements_to_sort[current - 1])) : (current -= 1) {
                    std.mem.swap(Placement, &placements_to_sort[current], &placements_to_sort[current - 1]);
                }
            }
        }

        fn placementLessThan(a: Placement, b: Placement) bool {
            return a.z < b.z or (a.z == b.z and a.image_id < b.image_id);
        }

        fn columns(self: *const RenderSnapshot) usize {
            return if (self.rows.items.len == 0) 0 else self.cells.items.len / self.rows.items.len;
        }

        pub fn replay(self: *const RenderSnapshot, renderer: anytype) void {
            self.replayRows(renderer, false);
        }

        /// Replays only rows replaced by the latest incremental capture. Frame
        /// callbacks are retained so cursor overlays participate in the scene.
        pub fn replayDirty(self: *const RenderSnapshot, renderer: anytype) void {
            self.replayRows(renderer, true);
        }

        fn replayRows(self: *const RenderSnapshot, renderer: anytype, dirty_only: bool) void {
            const frame = self.frame orelse return;
            renderer.beginFrame(frame);
            const column_count = self.columns();
            for (self.rows.items, 0..) |*row, y| {
                if (dirty_only and !row.dirty) continue;
                renderer.beginRow(@intCast(y));
                for (self.cells.items[y * column_count ..][0..column_count], 0..) |*cell, x| {
                    renderer.drawCell(cell.value(row, @intCast(x), @intCast(y)));
                }
                renderer.endRow(@intCast(y));
            }
            for (self.placements.items) |placement| {
                const image = self.images.items[placement.image_index];
                renderer.drawImage(.{
                    .image_id = placement.image_id,
                    .generation = image.generation,
                    .pixels = image.pixels,
                    .width = image.width,
                    .height = image.height,
                    .source_x = placement.source_x,
                    .source_y = placement.source_y,
                    .source_width = placement.source_width,
                    .source_height = placement.source_height,
                    .pixel_width = placement.pixel_width,
                    .pixel_height = placement.pixel_height,
                    .viewport_col = placement.viewport_col,
                    .viewport_row = placement.viewport_row,
                    .x_offset = placement.x_offset,
                    .y_offset = placement.y_offset,
                    .z = placement.z,
                });
            }
            renderer.endFrame(frame);
        }
    };

    pub const SearchScratch = struct {
        text: std.ArrayList(u8) = .empty,
        starts: std.ArrayList(u32) = .empty,

        pub fn deinit(self: *SearchScratch, allocator: std.mem.Allocator) void {
            self.text.deinit(allocator);
            self.starts.deinit(allocator);
            self.* = .{};
        }
    };

    pub const SearchCache = struct {
        const Row = struct { text_start: usize };
        text: std.ArrayList(u8) = .empty,
        starts: std.ArrayList(u32) = .empty,
        rows: std.ArrayList(Row) = .empty,
        scratch: SearchScratch = .{},

        pub fn deinit(self: *SearchCache, allocator: std.mem.Allocator) void {
            self.text.deinit(allocator);
            self.starts.deinit(allocator);
            self.rows.deinit(allocator);
            self.scratch.deinit(allocator);
            self.* = .{};
        }

        pub fn clear(self: *SearchCache, _: std.mem.Allocator) void {
            self.text.clearRetainingCapacity();
            self.starts.clearRetainingCapacity();
            self.rows.clearRetainingCapacity();
        }
    };

    pub const Scrollbar = struct {
        total: u64,
        offset: u64,
        len: u64,
    };

    pub const Link = struct {
        uri: []u8,
        row: u16,
        start_column: u16,
        end_column: u16,
    };

    pub const Key = enum {
        backquote,
        backslash,
        bracket_left,
        bracket_right,
        comma,
        digit_0,
        digit_1,
        digit_2,
        digit_3,
        digit_4,
        digit_5,
        digit_6,
        digit_7,
        digit_8,
        digit_9,
        equal,
        intl_backslash,
        intl_ro,
        intl_yen,
        a,
        b,
        c,
        d,
        e,
        f,
        g,
        h,
        i,
        j,
        k,
        l,
        m,
        n,
        o,
        p,
        q,
        r,
        s,
        t,
        u,
        v,
        w,
        x,
        y,
        z,
        minus,
        period,
        quote,
        semicolon,
        slash,
        alt_left,
        alt_right,
        escape,
        backspace,
        caps_lock,
        context_menu,
        control_left,
        control_right,
        tab,
        enter,
        meta_left,
        meta_right,
        shift_left,
        shift_right,
        space,
        convert,
        kana_mode,
        non_convert,
        insert,
        delete,
        end,
        help,
        home,
        page_down,
        page_up,
        arrow_down,
        arrow_left,
        arrow_right,
        arrow_up,
        num_lock,
        numpad_0,
        numpad_1,
        numpad_2,
        numpad_3,
        numpad_4,
        numpad_5,
        numpad_6,
        numpad_7,
        numpad_8,
        numpad_9,
        numpad_add,
        numpad_decimal,
        numpad_divide,
        numpad_enter,
        numpad_multiply,
        numpad_subtract,
        numpad_separator,
        numpad_up,
        numpad_down,
        numpad_right,
        numpad_left,
        numpad_begin,
        numpad_home,
        numpad_end,
        numpad_insert,
        numpad_delete,
        numpad_page_up,
        numpad_page_down,
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
        f13,
        f14,
        f15,
        f16,
        f17,
        f18,
        f19,
        f20,
        f21,
        f22,
        f23,
        f24,
        print_screen,
        scroll_lock,
        pause,
        browser_back,
        browser_favorites,
        browser_forward,
        browser_home,
        browser_refresh,
        browser_search,
        browser_stop,
        launch_app_1,
        launch_app_2,
        launch_mail,
        media_play_pause,
        media_select,
        media_stop,
        media_track_next,
        media_track_previous,
        sleep,
        audio_volume_down,
        audio_volume_mute,
        audio_volume_up,
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
        return initWithScrollback(columns, rows, terminal_theme, 10_000);
    }

    pub fn initWithScrollback(columns: u16, rows: u16, terminal_theme: theme.Theme, max_scrollback: u32) !Terminal {
        try installDecodePng();
        var terminal: vt.GhosttyTerminal = null;
        try check(vt.ghostty_terminal_new(null, &terminal, columns, rows));
        errdefer vt.ghostty_terminal_free(terminal);
        const scrollback_lines: usize = max_scrollback;
        // Preserve Zigonaut's line-based setting instead of also inheriting
        // libghostty's default byte cap, which could truncate history first.
        try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, null));
        try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollback_lines));
        const image_limit: usize = kitty_image_limit;
        const disabled = false;
        try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &image_limit));
        try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY, &image_limit));
        // Accept inline image data only. External transports can access host
        // files or shared memory named by untrusted terminal output.
        try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE, &disabled));
        try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE, null));
        try check(vt.ghostty_terminal_set(terminal, vt.GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM, &disabled));

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

        var mouse_encoder: vt.GhosttyMouseEncoder = null;
        try check(vt.ghostty_mouse_encoder_new(null, &mouse_encoder));
        errdefer vt.ghostty_mouse_encoder_free(mouse_encoder);
        var mouse_event: vt.GhosttyMouseEvent = null;
        try check(vt.ghostty_mouse_event_new(null, &mouse_event));
        errdefer vt.ghostty_mouse_event_free(mouse_event);

        try applyTheme(terminal, terminal_theme);

        return .{
            .terminal = terminal,
            .render_state = render_state,
            .row_iterator = row_iterator,
            .row_cells = row_cells,
            .key_encoder = key_encoder,
            .key_event = key_event,
            .mouse_encoder = mouse_encoder,
            .mouse_event = mouse_event,
            .columns = columns,
            .rows = rows,
        };
    }

    pub fn deinit(self: *Terminal) void {
        vt.ghostty_tracked_grid_ref_free(self.selection_anchor);
        vt.ghostty_mouse_event_free(self.mouse_event);
        vt.ghostty_mouse_encoder_free(self.mouse_encoder);
        vt.ghostty_key_event_free(self.key_event);
        vt.ghostty_key_encoder_free(self.key_encoder);
        vt.ghostty_render_state_row_cells_free(self.row_cells);
        vt.ghostty_render_state_row_iterator_free(self.row_iterator);
        vt.ghostty_render_state_free(self.render_state);
        vt.ghostty_terminal_free(self.terminal);
    }

    pub fn setTheme(self: *Terminal, value: theme.Theme) !void {
        try applyTheme(self.terminal, value);
    }

    pub fn resize(self: *Terminal, columns: u16, rows: u16, cell_width: u32, cell_height: u32) !void {
        try check(vt.ghostty_terminal_resize(
            self.terminal,
            columns,
            rows,
            cell_width,
            cell_height,
        ));
        self.columns = columns;
        self.rows = rows;
    }

    pub fn feed(self: *Terminal, bytes: []const u8) void {
        vt.ghostty_terminal_vt_write(self.terminal, bytes.ptr, bytes.len);
    }

    pub fn synchronizedOutput(self: *Terminal) bool {
        var enabled = false;
        check(vt.ghostty_terminal_mode_get(self.terminal, vt.ghostty_mode_new(2026, false), &enabled)) catch return false;
        return enabled;
    }

    pub fn setSynchronizedOutput(self: *Terminal, enabled: bool) !void {
        try check(vt.ghostty_terminal_mode_set(self.terminal, vt.ghostty_mode_new(2026, false), enabled));
    }

    pub fn scrollbar(self: *Terminal) !Scrollbar {
        var state = std.mem.zeroes(vt.GhosttyTerminalScrollbar);
        try check(vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_SCROLLBAR, &state));
        return .{
            .total = state.total,
            .offset = state.offset,
            .len = state.len,
        };
    }

    pub fn scrollViewport(self: *Terminal, delta: isize) void {
        vt.ghostty_terminal_scroll_viewport(self.terminal, .{
            .tag = vt.GHOSTTY_SCROLL_VIEWPORT_DELTA,
            .value = .{ .delta = delta },
        });
    }

    pub fn navigatePrompt(self: *Terminal, forward: bool) !bool {
        const state = try self.scrollbar();
        const limit = state.total -| state.len;
        var target: ?u64 = null;
        var row_index: u64 = 0;
        while (row_index < state.total) : (row_index += 1) {
            if (!try self.isPrimaryPromptRow(@intCast(row_index))) continue;
            if (forward) {
                if (row_index > state.offset) {
                    target = row_index;
                    break;
                }
            } else if (row_index < state.offset) {
                target = row_index;
            }
        }
        const destination = @min(target orelse return false, limit);
        const delta: isize = if (destination >= state.offset)
            @intCast(destination - state.offset)
        else
            -@as(isize, @intCast(state.offset - destination));
        self.scrollViewport(delta);
        return true;
    }

    pub fn lastCommandOutputAlloc(self: *Terminal, allocator: std.mem.Allocator) !?[]u8 {
        const total = try self.totalRows();
        var latest_prompt: ?u32 = null;
        var previous_prompt: ?u32 = null;
        var row_index: usize = 0;
        while (row_index < total) : (row_index += 1) {
            if (!try self.isPrimaryPromptRow(@intCast(row_index))) continue;
            previous_prompt = latest_prompt;
            latest_prompt = @intCast(row_index);
        }
        var owner_prompt = latest_prompt orelse return null;
        var output_ref = try self.findOutputInRows(owner_prompt, @intCast(total));
        if (output_ref == null) {
            owner_prompt = previous_prompt orelse return null;
            output_ref = try self.findOutputInRows(owner_prompt, latest_prompt.?);
        }
        const reference = output_ref orelse return null;

        var selection = std.mem.zeroes(vt.GhosttySelection);
        selection.size = @sizeOf(vt.GhosttySelection);
        const selected = vt.ghostty_terminal_select_output(self.terminal, reference, &selection);
        if (selected == vt.GHOSTTY_NO_VALUE) return null;
        try check(selected);
        var selection_start = std.mem.zeroes(vt.GhosttyPointCoordinate);
        try check(vt.ghostty_terminal_point_from_grid_ref(self.terminal, &selection.start, vt.GHOSTTY_POINT_TAG_SCREEN, &selection_start));
        if (selection_start.y < owner_prompt) return null;
        return try self.formatSelectionAlloc(allocator, &selection, false);
    }

    pub fn totalRows(self: *Terminal) !usize {
        var total: usize = 0;
        try check(vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, &total));
        return total;
    }

    fn screenGridRef(self: *Terminal, x: u16, y: u32) !vt.GhosttyGridRef {
        var reference = std.mem.zeroes(vt.GhosttyGridRef);
        reference.size = @sizeOf(vt.GhosttyGridRef);
        try check(vt.ghostty_terminal_grid_ref(self.terminal, .{
            .tag = vt.GHOSTTY_POINT_TAG_SCREEN,
            .value = .{ .coordinate = .{ .x = x, .y = y } },
        }, &reference));
        return reference;
    }

    fn isPrimaryPromptRow(self: *Terminal, y: u32) !bool {
        var reference = try self.screenGridRef(0, y);
        var row = std.mem.zeroes(vt.GhosttyRow);
        try check(vt.ghostty_grid_ref_row(&reference, &row));
        var semantic: vt.GhosttyRowSemanticPrompt = vt.GHOSTTY_ROW_SEMANTIC_NONE;
        try check(vt.ghostty_row_get(row, vt.GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &semantic));
        return semantic == vt.GHOSTTY_ROW_SEMANTIC_PROMPT;
    }

    fn findOutputInRows(self: *Terminal, start: u32, end: u32) !?vt.GhosttyGridRef {
        var row = end;
        while (row > start) {
            row -= 1;
            var column: usize = self.columns;
            while (column > 0) {
                column -= 1;
                var reference = std.mem.zeroes(vt.GhosttyGridRef);
                reference.size = @sizeOf(vt.GhosttyGridRef);
                const resolved = vt.ghostty_terminal_grid_ref(self.terminal, .{
                    .tag = vt.GHOSTTY_POINT_TAG_SCREEN,
                    .value = .{ .coordinate = .{ .x = @intCast(column), .y = row } },
                }, &reference);
                if (resolved == vt.GHOSTTY_INVALID_VALUE) continue;
                try check(resolved);
                var cell = std.mem.zeroes(vt.GhosttyCell);
                try check(vt.ghostty_grid_ref_cell(&reference, &cell));
                var semantic: vt.GhosttyCellSemanticContent = vt.GHOSTTY_CELL_SEMANTIC_OUTPUT;
                var has_text = false;
                try check(vt.ghostty_cell_get(cell, vt.GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &semantic));
                try check(vt.ghostty_cell_get(cell, vt.GHOSTTY_CELL_DATA_HAS_TEXT, &has_text));
                if (semantic == vt.GHOSTTY_CELL_SEMANTIC_OUTPUT and has_text) return reference;
            }
        }
        return null;
    }

    /// Appends byte-exact UTF-8 matches in one screen row. Kept row-at-a-time so
    /// callers can bound terminal lock time and continue processing PTY output.
    pub fn searchRow(self: *Terminal, allocator: std.mem.Allocator, scratch: *SearchScratch, row_index: u32, query: []const u8, output: *std.ArrayList(SearchMatch)) !void {
        if (query.len == 0) return;
        try self.reconstructSearchRow(allocator, scratch, row_index);
        try searchCachedRow(allocator, scratch, row_index, query, output);
    }

    /// Searches a row whose UTF-8 text and byte-to-column map are retained for
    /// subsequent queries. Callers must clear the cache when grid text changes.
    pub fn searchRowCached(self: *Terminal, allocator: std.mem.Allocator, cache: *SearchCache, row_index: u32, query: []const u8, output: *std.ArrayList(SearchMatch)) !void {
        if (query.len == 0) return;
        // Scans are sequential, so a missing row is always appended once.
        if (cache.rows.items.len <= row_index) {
            try self.reconstructSearchRow(allocator, &cache.scratch, row_index);
            const text_start = cache.text.items.len;
            try cache.text.ensureUnusedCapacity(allocator, cache.scratch.text.items.len);
            try cache.starts.ensureUnusedCapacity(allocator, cache.scratch.starts.items.len);
            try cache.rows.ensureUnusedCapacity(allocator, 1);
            cache.text.appendSliceAssumeCapacity(cache.scratch.text.items);
            cache.starts.appendSliceAssumeCapacity(cache.scratch.starts.items);
            cache.rows.appendAssumeCapacity(.{ .text_start = text_start });
        }
        const row = cache.rows.items[row_index];
        const next_row: usize = @as(usize, row_index) + 1;
        const text_end = if (next_row < cache.rows.items.len) cache.rows.items[next_row].text_start else cache.text.items.len;
        const starts_per_row = @as(usize, self.columns) + 1;
        const starts_start = @as(usize, row_index) * starts_per_row;
        try searchRowText(allocator, cache.text.items[row.text_start..text_end], cache.starts.items[starts_start..][0..starts_per_row], row_index, query, output);
    }

    fn reconstructSearchRow(self: *Terminal, allocator: std.mem.Allocator, scratch: *SearchScratch, row_index: u32) !void {
        scratch.text.clearRetainingCapacity();
        scratch.starts.clearRetainingCapacity();
        try scratch.starts.ensureTotalCapacity(allocator, @as(usize, self.columns) + 1);
        scratch.starts.items.len = @as(usize, self.columns) + 1;
        const starts = scratch.starts.items;
        var x: u16 = 0;
        while (x < self.columns) : (x += 1) {
            starts[x] = @intCast(scratch.text.items.len);
            var reference = std.mem.zeroes(vt.GhosttyGridRef);
            reference.size = @sizeOf(vt.GhosttyGridRef);
            try check(vt.ghostty_terminal_grid_ref(self.terminal, .{ .tag = vt.GHOSTTY_POINT_TAG_SCREEN, .value = .{ .coordinate = .{ .x = x, .y = row_index } } }, &reference));
            var codepoints: [16]u32 = undefined;
            var count: usize = 0;
            const result = vt.ghostty_grid_ref_graphemes(&reference, &codepoints, codepoints.len, &count);
            if (result == vt.GHOSTTY_OUT_OF_SPACE) continue;
            try check(result);
            if (count == 0) {
                try scratch.text.append(allocator, ' ');
            } else {
                for (codepoints[0..count]) |cp| {
                    var encoded: [4]u8 = undefined;
                    const scalar = std.math.cast(u21, cp) orelse continue;
                    const len = try std.unicode.utf8Encode(scalar, &encoded);
                    try scratch.text.appendSlice(allocator, encoded[0..len]);
                }
            }
        }
        starts[self.columns] = @intCast(scratch.text.items.len);
    }

    fn searchCachedRow(allocator: std.mem.Allocator, scratch: *const SearchScratch, row_index: u32, query: []const u8, output: *std.ArrayList(SearchMatch)) !void {
        try searchRowText(allocator, scratch.text.items, scratch.starts.items, row_index, query, output);
    }

    fn searchRowText(allocator: std.mem.Allocator, text: []const u8, starts: []const u32, row_index: u32, query: []const u8, output: *std.ArrayList(SearchMatch)) !void {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, query)) |at| {
            const finish = at + query.len;
            const start_column = searchStartColumn(starts[0 .. starts.len - 1], @intCast(at));
            const end_column = searchEndColumn(starts, @intCast(finish));
            try output.append(allocator, .{ .row = row_index, .start = start_column, .end = @max(end_column, start_column + 1) });
            from = at + @max(query.len, 1);
        }
    }

    fn searchStartColumn(starts: []const u32, offset: u32) u16 {
        var low: usize = 0;
        var high = starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (starts[middle] <= offset) low = middle + 1 else high = middle;
        }
        return @intCast(low -| 1);
    }

    fn searchEndColumn(starts: []const u32, offset: u32) u16 {
        var low: usize = 0;
        var high = starts.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (starts[middle] < offset) low = middle + 1 else high = middle;
        }
        return @intCast(low);
    }

    pub fn encodePasteAlloc(self: *Terminal, allocator: std.mem.Allocator, data: []u8) ![]u8 {
        var bracketed = false;
        try check(vt.ghostty_terminal_mode_get(self.terminal, vt.ghostty_mode_new(2004, false), &bracketed));

        var required: usize = data.len + 12;
        var encoded = try allocator.alloc(u8, required);
        errdefer allocator.free(encoded);
        const result = vt.ghostty_paste_encode(data.ptr, data.len, bracketed, encoded.ptr, encoded.len, &required);
        if (result == vt.GHOSTTY_OUT_OF_SPACE) {
            encoded = try allocator.realloc(encoded, required);
            try check(vt.ghostty_paste_encode(data.ptr, data.len, bracketed, encoded.ptr, encoded.len, &required));
        } else {
            try check(result);
        }
        return allocator.realloc(encoded, required);
    }

    pub fn linkAtAlloc(self: *Terminal, allocator: std.mem.Allocator, point: Point) !?Link {
        var reference = std.mem.zeroes(vt.GhosttyGridRef);
        reference.size = @sizeOf(vt.GhosttyGridRef);
        try check(vt.ghostty_terminal_grid_ref(self.terminal, viewportPoint(point), &reference));
        if (try hyperlinkAlloc(allocator, &reference)) |uri| {
            if (!link.hasAllowedScheme(uri)) {
                allocator.free(uri);
                return null;
            }
            var start = point.x;
            while (start > 0 and try self.cellHasHyperlink(start - 1, point.y, uri)) start -= 1;
            var end = point.x + 1;
            while (end < self.columns and try self.cellHasHyperlink(end, point.y, uri)) end += 1;
            return .{ .uri = uri, .row = point.y, .start_column = start, .end_column = end };
        }

        var row = std.ArrayList(u8).empty;
        defer row.deinit(allocator);
        const starts = try allocator.alloc(usize, @as(usize, self.columns) + 1);
        defer allocator.free(starts);
        var column: u16 = 0;
        while (column < self.columns) : (column += 1) {
            starts[column] = row.items.len;
            try self.appendCellText(allocator, &row, column, point.y);
        }
        starts[self.columns] = row.items.len;
        const offset = starts[point.x];
        const match = link.detectAt(row.items, offset) orelse return null;
        var start_column: u16 = 0;
        while (start_column < self.columns and starts[start_column + 1] <= match.start) start_column += 1;
        var end_column = start_column;
        while (end_column < self.columns and starts[end_column] < match.end) end_column += 1;
        return .{
            .uri = try allocator.dupe(u8, row.items[match.start..match.end]),
            .row = point.y,
            .start_column = start_column,
            .end_column = end_column,
        };
    }

    fn cellHasHyperlink(self: *Terminal, x: u16, y: u16, uri: []const u8) !bool {
        var reference = std.mem.zeroes(vt.GhosttyGridRef);
        reference.size = @sizeOf(vt.GhosttyGridRef);
        try check(vt.ghostty_terminal_grid_ref(self.terminal, viewportPoint(.{ .x = x, .y = y }), &reference));
        var required: usize = 0;
        const result = vt.ghostty_grid_ref_hyperlink_uri(&reference, null, 0, &required);
        if (result != vt.GHOSTTY_OUT_OF_SPACE or required != uri.len) return false;
        var buffer: [4096]u8 = undefined;
        if (required > buffer.len) return false;
        try check(vt.ghostty_grid_ref_hyperlink_uri(&reference, &buffer, buffer.len, &required));
        return std.mem.eql(u8, uri, buffer[0..required]);
    }

    fn appendCellText(self: *Terminal, allocator: std.mem.Allocator, row: *std.ArrayList(u8), x: u16, y: u16) !void {
        var reference = std.mem.zeroes(vt.GhosttyGridRef);
        reference.size = @sizeOf(vt.GhosttyGridRef);
        try check(vt.ghostty_terminal_grid_ref(self.terminal, viewportPoint(.{ .x = x, .y = y }), &reference));
        var codepoints: [16]u32 = undefined;
        var count: usize = 0;
        const result = vt.ghostty_grid_ref_graphemes(&reference, &codepoints, codepoints.len, &count);
        if (result == vt.GHOSTTY_OUT_OF_SPACE) return;
        try check(result);
        if (count == 0) {
            try row.append(allocator, ' ');
            return;
        }
        for (codepoints[0..count]) |codepoint| {
            var encoded: [4]u8 = undefined;
            const scalar = std.math.cast(u21, codepoint) orelse continue;
            const length = try std.unicode.utf8Encode(scalar, &encoded);
            try row.appendSlice(allocator, encoded[0..length]);
        }
    }

    pub fn setTitleChanged(self: *Terminal, callback: TitleChanged, context: ?*anyopaque) !void {
        self.title_changed = callback;
        self.title_context = context;
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_USERDATA, self));
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, @as(vt.GhosttyTerminalTitleChangedFn, titleChanged)));
    }

    pub fn setWritePty(self: *Terminal, callback: WritePty, context: ?*anyopaque) !void {
        self.write_pty = callback;
        self.write_pty_context = context;
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_USERDATA, self));
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @as(vt.GhosttyTerminalWritePtyFn, writePty)));
    }

    pub fn setClipboardWrite(self: *Terminal, callback: ClipboardWrite, context: ?*anyopaque) !void {
        self.clipboard_write = callback;
        self.clipboard_context = context;
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_USERDATA, self));
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, @as(vt.GhosttyTerminalClipboardWriteFn, clipboardWrite)));
    }

    pub fn setDesktopNotification(self: *Terminal, callback: DesktopNotification, context: ?*anyopaque) !void {
        self.desktop_notification = callback;
        self.desktop_notification_context = context;
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_USERDATA, self));
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, @as(vt.GhosttyTerminalDesktopNotificationFn, desktopNotification)));
    }

    pub fn setProgressReport(self: *Terminal, callback: ProgressReport, context: ?*anyopaque) !void {
        self.progress_report = callback;
        self.progress_report_context = context;
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_USERDATA, self));
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, @as(vt.GhosttyTerminalProgressReportFn, progressReport)));
    }

    pub fn pwdAlloc(self: *Terminal, allocator: std.mem.Allocator) !?[]u8 {
        var pwd = std.mem.zeroes(vt.GhosttyString);
        try check(vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_PWD, &pwd));
        if (pwd.len == 0) return null;
        return @as(?[]u8, try allocator.dupe(u8, pwd.ptr[0..pwd.len]));
    }

    pub fn renderViewport(self: *Terminal, renderer: anytype) !void {
        try self.renderViewportInternal(renderer, null);
    }

    /// Updates the render state and emits either all rows or only rows marked
    /// dirty by libghostty. Dirty flags are consumed after a successful pass.
    fn renderViewportInternal(self: *Terminal, renderer: anytype, previous_frame: ?Frame) !void {
        try check(vt.ghostty_render_state_update(self.render_state, self.terminal));

        var dirty: vt.GhosttyRenderStateDirty = vt.GHOSTTY_RENDER_STATE_DIRTY_FULL;
        try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty));
        const dirty_only = previous_frame != null;

        var colors = std.mem.zeroes(vt.GhosttyRenderStateColors);
        colors.size = @sizeOf(vt.GhosttyRenderStateColors);
        try check(vt.ghostty_render_state_colors_get(self.render_state, &colors));
        var cursor_visible = false;
        var cursor_has_position = false;
        var cursor_x: u16 = 0;
        var cursor_y: u16 = 0;
        var cursor_wide_tail = false;
        var cursor_visual_style: vt.GhosttyRenderStateCursorVisualStyle = vt.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
        try check(vt.ghostty_render_state_get(
            self.render_state,
            vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE,
            &cursor_visual_style,
        ));
        try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursor_visible));
        try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_HAS_VALUE, &cursor_has_position));
        if (cursor_has_position) {
            try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &cursor_x));
            try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &cursor_y));
            try check(vt.ghostty_render_state_get(self.render_state, vt.GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_WIDE_TAIL, &cursor_wide_tail));
            if (cursor_wide_tail and cursor_x > 0) cursor_x -= 1;
        }
        const frame = Frame{
            .foreground = fromGhostty(colors.foreground),
            .background = fromGhostty(colors.background),
            .cursor = fromGhostty(if (colors.cursor_has_value) colors.cursor else colors.foreground),
            .cursor_style = switch (cursor_visual_style) {
                vt.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR => .bar,
                vt.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE => .underline,
                vt.GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK_HOLLOW => .hollow,
                else => .block,
            },
            .cursor_visible = cursor_visible and cursor_has_position,
            .cursor_has_position = cursor_has_position,
            .cursor_x = cursor_x,
            .cursor_y = cursor_y,
            .cursor_columns = if (cursor_wide_tail) 2 else 1,
        };
        renderer.beginFrame(frame);
        const global_colors_changed = if (previous_frame) |previous|
            !std.meta.eql(previous.foreground, frame.foreground) or
                !std.meta.eql(previous.background, frame.background)
        else
            true;
        if (dirty_only and dirty == vt.GHOSTTY_RENDER_STATE_DIRTY_FALSE and !global_colors_changed) {
            renderer.endFrame(frame);
            return;
        }
        if (global_colors_changed) dirty = vt.GHOSTTY_RENDER_STATE_DIRTY_FULL;

        try check(vt.ghostty_render_state_get(
            self.render_state,
            vt.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR,
            @ptrCast(&self.row_iterator),
        ));
        var y: u16 = 0;
        while (vt.ghostty_render_state_row_iterator_next(self.row_iterator)) : (y += 1) {
            var row_dirty = false;
            try check(vt.ghostty_render_state_row_get(
                self.row_iterator,
                vt.GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY,
                &row_dirty,
            ));
            if (dirty_only and dirty == vt.GHOSTTY_RENDER_STATE_DIRTY_PARTIAL and !row_dirty) continue;
            try check(vt.ghostty_render_state_row_get(
                self.row_iterator,
                vt.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                @ptrCast(&self.row_cells),
            ));
            var selection = std.mem.zeroes(vt.GhosttyRenderStateRowSelection);
            selection.size = @sizeOf(vt.GhosttyRenderStateRowSelection);
            const has_selection = vt.ghostty_render_state_row_get(
                self.row_iterator,
                vt.GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION,
                &selection,
            ) == vt.GHOSTTY_SUCCESS;
            renderer.beginRow(y);
            defer renderer.endRow(y);
            var x: u16 = 0;
            while (vt.ghostty_render_state_row_cells_next(self.row_cells)) : (x += 1) {
                const occupancy = try currentCellOccupancy(self.row_cells);
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
                // Use bright ANSI colours for bold low-palette text. This
                // preserves the conventional terminal bold-colour behaviour.
                if (style.bold and style.fg_color.tag == vt.GHOSTTY_STYLE_COLOR_PALETTE and style.fg_color.value.palette < 8) {
                    foreground = colors.palette[style.fg_color.value.palette + 8];
                }
                if (vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR,
                    &background,
                ) != vt.GHOSTTY_SUCCESS) background = colors.background;
                if (style.inverse) std.mem.swap(vt.GhosttyColorRgb, &foreground, &background);
                var underline_color = foreground;
                switch (style.underline_color.tag) {
                    vt.GHOSTTY_STYLE_COLOR_PALETTE => underline_color = colors.palette[style.underline_color.value.palette],
                    vt.GHOSTTY_STYLE_COLOR_RGB => underline_color = style.underline_color.value.rgb,
                    else => {},
                }

                var codepoint_count: u32 = 0;
                try check(vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    &codepoint_count,
                ));
                var codepoints: [16]u32 = undefined;
                const count: usize = @intCast(@min(codepoint_count, codepoints.len));
                // Hide an oversized cluster instead of truncating it. A prefix
                // can form a different grapheme and display incorrect text.
                if (count > 0 and codepoint_count <= codepoints.len) {
                    try check(vt.ghostty_render_state_row_cells_get(
                        self.row_cells,
                        vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF,
                        &codepoints,
                    ));
                }
                const draw_result = renderer.drawCell(Cell{
                    .x = x,
                    .y = y,
                    .occupancy = occupancy,
                    .codepoints = if (style.invisible or codepoint_count > codepoints.len) codepoints[0..0] else codepoints[0..count],
                    .foreground = fromGhostty(foreground),
                    .background = fromGhostty(background),
                    .underline_color = fromGhostty(underline_color),
                    .bold = style.bold,
                    .italic = style.italic,
                    .faint = style.faint,
                    .strikethrough = style.strikethrough,
                    .overline = style.overline,
                    .underline = @intCast(@max(style.underline, 0)),
                    .selected = has_selection and x >= selection.start_x and x <= selection.end_x,
                });
                if (comptime @TypeOf(draw_result) != void) try draw_result;
            }
            if (dirty_only) {
                row_dirty = false;
                try check(vt.ghostty_render_state_row_set(
                    self.row_iterator,
                    vt.GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY,
                    &row_dirty,
                ));
            }
        }
        renderer.endFrame(frame);
        if (dirty_only) {
            dirty = vt.GHOSTTY_RENDER_STATE_DIRTY_FALSE;
            try check(vt.ghostty_render_state_set(
                self.render_state,
                vt.GHOSTTY_RENDER_STATE_OPTION_DIRTY,
                &dirty,
            ));
        }
    }

    pub fn encodeKey(self: *Terminal, key: Key, action: KeyAction, modifiers: u16, unshifted_codepoint: u32, output: []u8) ![]const u8 {
        vt.ghostty_key_encoder_setopt_from_terminal(self.key_encoder, self.terminal);
        vt.ghostty_key_event_set_action(self.key_event, switch (action) {
            .press => vt.GHOSTTY_KEY_ACTION_PRESS,
            .repeat => vt.GHOSTTY_KEY_ACTION_REPEAT,
            .release => vt.GHOSTTY_KEY_ACTION_RELEASE,
        });
        vt.ghostty_key_event_set_key(self.key_event, switch (key) {
            .backquote => vt.GHOSTTY_KEY_BACKQUOTE,
            .backslash => vt.GHOSTTY_KEY_BACKSLASH,
            .bracket_left => vt.GHOSTTY_KEY_BRACKET_LEFT,
            .bracket_right => vt.GHOSTTY_KEY_BRACKET_RIGHT,
            .comma => vt.GHOSTTY_KEY_COMMA,
            .digit_0 => vt.GHOSTTY_KEY_DIGIT_0,
            .digit_1 => vt.GHOSTTY_KEY_DIGIT_1,
            .digit_2 => vt.GHOSTTY_KEY_DIGIT_2,
            .digit_3 => vt.GHOSTTY_KEY_DIGIT_3,
            .digit_4 => vt.GHOSTTY_KEY_DIGIT_4,
            .digit_5 => vt.GHOSTTY_KEY_DIGIT_5,
            .digit_6 => vt.GHOSTTY_KEY_DIGIT_6,
            .digit_7 => vt.GHOSTTY_KEY_DIGIT_7,
            .digit_8 => vt.GHOSTTY_KEY_DIGIT_8,
            .digit_9 => vt.GHOSTTY_KEY_DIGIT_9,
            .equal => vt.GHOSTTY_KEY_EQUAL,
            .intl_backslash => vt.GHOSTTY_KEY_INTL_BACKSLASH,
            .intl_ro => vt.GHOSTTY_KEY_INTL_RO,
            .intl_yen => vt.GHOSTTY_KEY_INTL_YEN,
            .a => vt.GHOSTTY_KEY_A,
            .b => vt.GHOSTTY_KEY_B,
            .c => vt.GHOSTTY_KEY_C,
            .d => vt.GHOSTTY_KEY_D,
            .e => vt.GHOSTTY_KEY_E,
            .f => vt.GHOSTTY_KEY_F,
            .g => vt.GHOSTTY_KEY_G,
            .h => vt.GHOSTTY_KEY_H,
            .i => vt.GHOSTTY_KEY_I,
            .j => vt.GHOSTTY_KEY_J,
            .k => vt.GHOSTTY_KEY_K,
            .l => vt.GHOSTTY_KEY_L,
            .m => vt.GHOSTTY_KEY_M,
            .n => vt.GHOSTTY_KEY_N,
            .o => vt.GHOSTTY_KEY_O,
            .p => vt.GHOSTTY_KEY_P,
            .q => vt.GHOSTTY_KEY_Q,
            .r => vt.GHOSTTY_KEY_R,
            .s => vt.GHOSTTY_KEY_S,
            .t => vt.GHOSTTY_KEY_T,
            .u => vt.GHOSTTY_KEY_U,
            .v => vt.GHOSTTY_KEY_V,
            .w => vt.GHOSTTY_KEY_W,
            .x => vt.GHOSTTY_KEY_X,
            .y => vt.GHOSTTY_KEY_Y,
            .z => vt.GHOSTTY_KEY_Z,
            .minus => vt.GHOSTTY_KEY_MINUS,
            .period => vt.GHOSTTY_KEY_PERIOD,
            .quote => vt.GHOSTTY_KEY_QUOTE,
            .semicolon => vt.GHOSTTY_KEY_SEMICOLON,
            .slash => vt.GHOSTTY_KEY_SLASH,
            .alt_left => vt.GHOSTTY_KEY_ALT_LEFT,
            .alt_right => vt.GHOSTTY_KEY_ALT_RIGHT,
            .escape => vt.GHOSTTY_KEY_ESCAPE,
            .backspace => vt.GHOSTTY_KEY_BACKSPACE,
            .caps_lock => vt.GHOSTTY_KEY_CAPS_LOCK,
            .context_menu => vt.GHOSTTY_KEY_CONTEXT_MENU,
            .control_left => vt.GHOSTTY_KEY_CONTROL_LEFT,
            .control_right => vt.GHOSTTY_KEY_CONTROL_RIGHT,
            .tab => vt.GHOSTTY_KEY_TAB,
            .enter => vt.GHOSTTY_KEY_ENTER,
            .meta_left => vt.GHOSTTY_KEY_META_LEFT,
            .meta_right => vt.GHOSTTY_KEY_META_RIGHT,
            .shift_left => vt.GHOSTTY_KEY_SHIFT_LEFT,
            .shift_right => vt.GHOSTTY_KEY_SHIFT_RIGHT,
            .space => vt.GHOSTTY_KEY_SPACE,
            .convert => vt.GHOSTTY_KEY_CONVERT,
            .kana_mode => vt.GHOSTTY_KEY_KANA_MODE,
            .non_convert => vt.GHOSTTY_KEY_NON_CONVERT,
            .insert => vt.GHOSTTY_KEY_INSERT,
            .delete => vt.GHOSTTY_KEY_DELETE,
            .end => vt.GHOSTTY_KEY_END,
            .help => vt.GHOSTTY_KEY_HELP,
            .home => vt.GHOSTTY_KEY_HOME,
            .page_down => vt.GHOSTTY_KEY_PAGE_DOWN,
            .page_up => vt.GHOSTTY_KEY_PAGE_UP,
            .arrow_down => vt.GHOSTTY_KEY_ARROW_DOWN,
            .arrow_left => vt.GHOSTTY_KEY_ARROW_LEFT,
            .arrow_right => vt.GHOSTTY_KEY_ARROW_RIGHT,
            .arrow_up => vt.GHOSTTY_KEY_ARROW_UP,
            .num_lock => vt.GHOSTTY_KEY_NUM_LOCK,
            .numpad_0 => vt.GHOSTTY_KEY_NUMPAD_0,
            .numpad_1 => vt.GHOSTTY_KEY_NUMPAD_1,
            .numpad_2 => vt.GHOSTTY_KEY_NUMPAD_2,
            .numpad_3 => vt.GHOSTTY_KEY_NUMPAD_3,
            .numpad_4 => vt.GHOSTTY_KEY_NUMPAD_4,
            .numpad_5 => vt.GHOSTTY_KEY_NUMPAD_5,
            .numpad_6 => vt.GHOSTTY_KEY_NUMPAD_6,
            .numpad_7 => vt.GHOSTTY_KEY_NUMPAD_7,
            .numpad_8 => vt.GHOSTTY_KEY_NUMPAD_8,
            .numpad_9 => vt.GHOSTTY_KEY_NUMPAD_9,
            .numpad_add => vt.GHOSTTY_KEY_NUMPAD_ADD,
            .numpad_decimal => vt.GHOSTTY_KEY_NUMPAD_DECIMAL,
            .numpad_divide => vt.GHOSTTY_KEY_NUMPAD_DIVIDE,
            .numpad_enter => vt.GHOSTTY_KEY_NUMPAD_ENTER,
            .numpad_multiply => vt.GHOSTTY_KEY_NUMPAD_MULTIPLY,
            .numpad_subtract => vt.GHOSTTY_KEY_NUMPAD_SUBTRACT,
            .numpad_separator => vt.GHOSTTY_KEY_NUMPAD_SEPARATOR,
            .numpad_up => vt.GHOSTTY_KEY_NUMPAD_UP,
            .numpad_down => vt.GHOSTTY_KEY_NUMPAD_DOWN,
            .numpad_right => vt.GHOSTTY_KEY_NUMPAD_RIGHT,
            .numpad_left => vt.GHOSTTY_KEY_NUMPAD_LEFT,
            .numpad_begin => vt.GHOSTTY_KEY_NUMPAD_BEGIN,
            .numpad_home => vt.GHOSTTY_KEY_NUMPAD_HOME,
            .numpad_end => vt.GHOSTTY_KEY_NUMPAD_END,
            .numpad_insert => vt.GHOSTTY_KEY_NUMPAD_INSERT,
            .numpad_delete => vt.GHOSTTY_KEY_NUMPAD_DELETE,
            .numpad_page_up => vt.GHOSTTY_KEY_NUMPAD_PAGE_UP,
            .numpad_page_down => vt.GHOSTTY_KEY_NUMPAD_PAGE_DOWN,
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
            .f13 => vt.GHOSTTY_KEY_F13,
            .f14 => vt.GHOSTTY_KEY_F14,
            .f15 => vt.GHOSTTY_KEY_F15,
            .f16 => vt.GHOSTTY_KEY_F16,
            .f17 => vt.GHOSTTY_KEY_F17,
            .f18 => vt.GHOSTTY_KEY_F18,
            .f19 => vt.GHOSTTY_KEY_F19,
            .f20 => vt.GHOSTTY_KEY_F20,
            .f21 => vt.GHOSTTY_KEY_F21,
            .f22 => vt.GHOSTTY_KEY_F22,
            .f23 => vt.GHOSTTY_KEY_F23,
            .f24 => vt.GHOSTTY_KEY_F24,
            .print_screen => vt.GHOSTTY_KEY_PRINT_SCREEN,
            .scroll_lock => vt.GHOSTTY_KEY_SCROLL_LOCK,
            .pause => vt.GHOSTTY_KEY_PAUSE,
            .browser_back => vt.GHOSTTY_KEY_BROWSER_BACK,
            .browser_favorites => vt.GHOSTTY_KEY_BROWSER_FAVORITES,
            .browser_forward => vt.GHOSTTY_KEY_BROWSER_FORWARD,
            .browser_home => vt.GHOSTTY_KEY_BROWSER_HOME,
            .browser_refresh => vt.GHOSTTY_KEY_BROWSER_REFRESH,
            .browser_search => vt.GHOSTTY_KEY_BROWSER_SEARCH,
            .browser_stop => vt.GHOSTTY_KEY_BROWSER_STOP,
            .launch_app_1 => vt.GHOSTTY_KEY_LAUNCH_APP_1,
            .launch_app_2 => vt.GHOSTTY_KEY_LAUNCH_APP_2,
            .launch_mail => vt.GHOSTTY_KEY_LAUNCH_MAIL,
            .media_play_pause => vt.GHOSTTY_KEY_MEDIA_PLAY_PAUSE,
            .media_select => vt.GHOSTTY_KEY_MEDIA_SELECT,
            .media_stop => vt.GHOSTTY_KEY_MEDIA_STOP,
            .media_track_next => vt.GHOSTTY_KEY_MEDIA_TRACK_NEXT,
            .media_track_previous => vt.GHOSTTY_KEY_MEDIA_TRACK_PREVIOUS,
            .sleep => vt.GHOSTTY_KEY_SLEEP,
            .audio_volume_down => vt.GHOSTTY_KEY_AUDIO_VOLUME_DOWN,
            .audio_volume_mute => vt.GHOSTTY_KEY_AUDIO_VOLUME_MUTE,
            .audio_volume_up => vt.GHOSTTY_KEY_AUDIO_VOLUME_UP,
        });
        vt.ghostty_key_event_set_mods(self.key_event, modifiers);
        vt.ghostty_key_event_set_consumed_mods(self.key_event, 0);
        vt.ghostty_key_event_set_composing(self.key_event, false);
        vt.ghostty_key_event_set_utf8(self.key_event, null, 0);
        vt.ghostty_key_event_set_unshifted_codepoint(self.key_event, unshifted_codepoint);

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

        var writer: std.Io.Writer = .fixed(output);
        var row_index: usize = 0;
        while (vt.ghostty_render_state_row_iterator_next(self.row_iterator)) : (row_index += 1) {
            if (row_index != 0) try writer.writeByte('\n');
            try check(vt.ghostty_render_state_row_get(
                self.row_iterator,
                vt.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS,
                @ptrCast(&self.row_cells),
            ));

            while (vt.ghostty_render_state_row_cells_next(self.row_cells)) {
                const occupancy = try currentCellOccupancy(self.row_cells);
                var codepoint_count: u32 = 0;
                try check(vt.ghostty_render_state_row_cells_get(
                    self.row_cells,
                    vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN,
                    @ptrCast(&codepoint_count),
                ));
                if (codepoint_count == 0) {
                    // Do not write a space for a wide tail. Its leading cell
                    // already represents the complete glyph.
                    if (occupancy == .narrow or occupancy == .wrap_spacer) {
                        try writer.writeByte(' ');
                    }
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
                    try writer.writeAll(encoded[0..length]);
                }
            }
            while (writer.end > 0 and output[writer.end - 1] == ' ') writer.end -= 1;
        }

        return std.mem.trimEnd(u8, writer.buffered(), " \n");
    }

    pub fn setSelection(self: *Terminal, selection: ?Selection) !void {
        const value = selection orelse {
            try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, null));
            return;
        };
        var start = std.mem.zeroes(vt.GhosttyGridRef);
        start.size = @sizeOf(vt.GhosttyGridRef);
        try check(vt.ghostty_terminal_grid_ref(self.terminal, viewportPoint(value.anchor), &start));
        var end = std.mem.zeroes(vt.GhosttyGridRef);
        end.size = @sizeOf(vt.GhosttyGridRef);
        try check(vt.ghostty_terminal_grid_ref(self.terminal, viewportPoint(value.focus), &end));
        var native_selection = std.mem.zeroes(vt.GhosttySelection);
        native_selection.size = @sizeOf(vt.GhosttySelection);
        native_selection.start = start;
        native_selection.end = end;
        native_selection.rectangle = value.rectangle;
        try check(vt.ghostty_terminal_set(
            self.terminal,
            vt.GHOSTTY_TERMINAL_OPT_SELECTION,
            &native_selection,
        ));
    }

    pub fn beginSelectionAnchor(self: *Terminal, point: Point) !void {
        if (self.selection_anchor) |anchor| {
            try check(vt.ghostty_tracked_grid_ref_set(anchor, self.terminal, viewportPoint(point)));
        } else {
            try check(vt.ghostty_terminal_grid_ref_track(self.terminal, viewportPoint(point), &self.selection_anchor));
        }
    }

    pub fn endSelectionAnchor(self: *Terminal) void {
        vt.ghostty_tracked_grid_ref_free(self.selection_anchor);
        self.selection_anchor = null;
    }

    pub fn setDerivedSelection(self: *Terminal, focus: Point, unit: SelectionUnit, rectangle: bool) !void {
        const tracked = self.selection_anchor orelse return error.SelectionAnchorLost;
        var a = std.mem.zeroes(vt.GhosttyGridRef);
        a.size = @sizeOf(vt.GhosttyGridRef);
        try check(vt.ghostty_tracked_grid_ref_snapshot(tracked, &a));
        var f = std.mem.zeroes(vt.GhosttyGridRef);
        f.size = @sizeOf(vt.GhosttyGridRef);
        try check(vt.ghostty_terminal_grid_ref(self.terminal, viewportPoint(focus), &f));
        var focus_screen = std.mem.zeroes(vt.GhosttyPointCoordinate);
        try check(vt.ghostty_terminal_point_from_grid_ref(self.terminal, &f, vt.GHOSTTY_POINT_TAG_SCREEN, &focus_screen));
        var anchor_screen = std.mem.zeroes(vt.GhosttyPointCoordinate);
        try check(vt.ghostty_tracked_grid_ref_point(tracked, vt.GHOSTTY_POINT_TAG_SCREEN, &anchor_screen));
        const forward = anchor_screen.y < focus_screen.y or anchor_screen.y == focus_screen.y and anchor_screen.x <= focus_screen.x;
        var selection = std.mem.zeroes(vt.GhosttySelection);
        selection.size = @sizeOf(vt.GhosttySelection);
        if (unit == .cell) {
            selection.start = a;
            selection.end = f;
            selection.rectangle = rectangle;
            try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, &selection));
            return;
        }
        var first = std.mem.zeroes(vt.GhosttySelection);
        first.size = @sizeOf(vt.GhosttySelection);
        var last = std.mem.zeroes(vt.GhosttySelection);
        last.size = @sizeOf(vt.GhosttySelection);
        if (unit == .word) {
            var options = std.mem.zeroes(vt.GhosttyTerminalSelectWordBetweenOptions);
            options.size = @sizeOf(vt.GhosttyTerminalSelectWordBetweenOptions);
            options.start = a;
            options.end = f;
            try check(vt.ghostty_terminal_select_word_between(self.terminal, &options, &first));
            options.start = f;
            options.end = a;
            try check(vt.ghostty_terminal_select_word_between(self.terminal, &options, &last));
        } else {
            var options = std.mem.zeroes(vt.GhosttyTerminalSelectLineOptions);
            options.size = @sizeOf(vt.GhosttyTerminalSelectLineOptions);
            // Let line selection cross prompt boundaries so it follows the
            // visual lines that the user selected.
            options.semantic_prompt_boundary = false;
            options.ref = a;
            try check(vt.ghostty_terminal_select_line(self.terminal, &options, &first));
            options.ref = f;
            try check(vt.ghostty_terminal_select_line(self.terminal, &options, &last));
        }
        selection.start = if (forward) first.start else first.end;
        selection.end = if (forward) last.end else last.start;
        try check(vt.ghostty_terminal_set(self.terminal, vt.GHOSTTY_TERMINAL_OPT_SELECTION, &selection));
    }

    pub fn mouseTracking(self: *Terminal) bool {
        var tracking = false;
        check(vt.ghostty_terminal_get(self.terminal, vt.GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)) catch return false;
        return tracking;
    }

    pub fn encodeMouse(self: *Terminal, action: MouseAction, button: MouseButton, position: PixelPoint, modifiers: u16, geometry: MouseGeometry, any_button_pressed: bool, output: []u8) ![]const u8 {
        vt.ghostty_mouse_encoder_setopt_from_terminal(self.mouse_encoder, self.terminal);
        var size = std.mem.zeroes(vt.GhosttyMouseEncoderSize);
        size.size = @sizeOf(vt.GhosttyMouseEncoderSize);
        size.screen_width = geometry.screen_width;
        size.screen_height = geometry.screen_height;
        size.cell_width = geometry.cell_width;
        size.cell_height = geometry.cell_height;
        size.padding_top = geometry.padding_top;
        size.padding_bottom = geometry.padding_bottom;
        size.padding_left = geometry.padding_left;
        size.padding_right = geometry.padding_right;
        vt.ghostty_mouse_encoder_setopt(self.mouse_encoder, vt.GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
        vt.ghostty_mouse_encoder_setopt(self.mouse_encoder, vt.GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &any_button_pressed);
        vt.ghostty_mouse_event_set_action(self.mouse_event, switch (action) {
            .press => vt.GHOSTTY_MOUSE_ACTION_PRESS,
            .release => vt.GHOSTTY_MOUSE_ACTION_RELEASE,
            .motion => vt.GHOSTTY_MOUSE_ACTION_MOTION,
        });
        if (button == .none) vt.ghostty_mouse_event_clear_button(self.mouse_event) else vt.ghostty_mouse_event_set_button(self.mouse_event, switch (button) {
            .left => vt.GHOSTTY_MOUSE_BUTTON_LEFT,
            .middle => vt.GHOSTTY_MOUSE_BUTTON_MIDDLE,
            .right => vt.GHOSTTY_MOUSE_BUTTON_RIGHT,
            .wheel_up => vt.GHOSTTY_MOUSE_BUTTON_FOUR,
            .wheel_down => vt.GHOSTTY_MOUSE_BUTTON_FIVE,
            .wheel_left => vt.GHOSTTY_MOUSE_BUTTON_SIX,
            .wheel_right => vt.GHOSTTY_MOUSE_BUTTON_SEVEN,
            .none => unreachable,
        });
        vt.ghostty_mouse_event_set_mods(self.mouse_event, modifiers);
        vt.ghostty_mouse_event_set_position(self.mouse_event, .{ .x = @floatFromInt(position.x), .y = @floatFromInt(position.y) });
        var written: usize = 0;
        try check(vt.ghostty_mouse_encoder_encode(self.mouse_encoder, self.mouse_event, output.ptr, output.len, &written));
        return output[0..written];
    }

    pub fn selectedTextAlloc(self: *Terminal, allocator: std.mem.Allocator) ![]u8 {
        return self.formatSelectionAlloc(allocator, null, true);
    }

    fn formatSelectionAlloc(self: *Terminal, allocator: std.mem.Allocator, selection: ?*const vt.GhosttySelection, trim: bool) ![]u8 {
        var options = std.mem.zeroes(vt.GhosttyTerminalSelectionFormatOptions);
        options.size = @sizeOf(vt.GhosttyTerminalSelectionFormatOptions);
        options.emit = vt.GHOSTTY_FORMATTER_FORMAT_PLAIN;
        options.unwrap = true;
        options.trim = trim;
        options.selection = selection;
        var required: usize = 0;
        const query = vt.ghostty_terminal_selection_format_buf(
            self.terminal,
            options,
            null,
            0,
            &required,
        );
        if (query != vt.GHOSTTY_OUT_OF_SPACE and query != vt.GHOSTTY_SUCCESS) return error.LibGhosttyFailure;
        const output = try allocator.alloc(u8, required);
        errdefer allocator.free(output);
        var written: usize = 0;
        try check(vt.ghostty_terminal_selection_format_buf(
            self.terminal,
            options,
            output.ptr,
            output.len,
            &written,
        ));
        return allocator.realloc(output, written);
    }
};

fn hyperlinkAlloc(allocator: std.mem.Allocator, reference: *const vt.GhosttyGridRef) !?[]u8 {
    var required: usize = 0;
    const result = vt.ghostty_grid_ref_hyperlink_uri(reference, null, 0, &required);
    if (result == vt.GHOSTTY_SUCCESS and required == 0) return null;
    if (result != vt.GHOSTTY_OUT_OF_SPACE) try check(result);
    if (required == 0) return null;
    const uri = try allocator.alloc(u8, required);
    errdefer allocator.free(uri);
    try check(vt.ghostty_grid_ref_hyperlink_uri(reference, uri.ptr, uri.len, &required));
    return uri;
}

fn viewportPoint(point: Terminal.Point) vt.GhosttyPoint {
    return .{
        .tag = vt.GHOSTTY_POINT_TAG_VIEWPORT,
        .value = .{ .coordinate = .{ .x = point.x, .y = point.y } },
    };
}

fn writePty(_: vt.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(userdata orelse return));
    const callback = self.write_pty orelse return;
    callback(self.write_pty_context, data[0..len]);
}

fn titleChanged(terminal: vt.GhosttyTerminal, userdata: ?*anyopaque) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(userdata orelse return));
    const callback = self.title_changed orelse return;
    var title = std.mem.zeroes(vt.GhosttyString);
    if (vt.ghostty_terminal_get(terminal, vt.GHOSTTY_TERMINAL_DATA_TITLE, &title) != vt.GHOSTTY_SUCCESS) return;
    callback(self.title_context, title.ptr[0..title.len]);
}

fn desktopNotification(_: vt.GhosttyTerminal, userdata: ?*anyopaque, notification: [*c]const vt.GhosttyTerminalDesktopNotification) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(userdata orelse return));
    const callback = self.desktop_notification orelse return;
    const minimum_size = @offsetOf(vt.GhosttyTerminalDesktopNotification, "body") + @sizeOf(vt.GhosttyString);
    if (notification == null or notification[0].size < minimum_size) return;
    const title = notification[0].title;
    const body = notification[0].body;
    if ((title.len != 0 and title.ptr == null) or (body.len != 0 and body.ptr == null)) return;
    callback(
        self.desktop_notification_context,
        if (title.len == 0) "" else title.ptr[0..title.len],
        if (body.len == 0) "" else body.ptr[0..body.len],
    );
}

fn progressReport(_: vt.GhosttyTerminal, userdata: ?*anyopaque, report: [*c]const vt.GhosttyTerminalProgressReport) callconv(.c) void {
    const self: *Terminal = @ptrCast(@alignCast(userdata orelse return));
    const callback = self.progress_report orelse return;
    const minimum_size = @offsetOf(vt.GhosttyTerminalProgressReport, "progress") + @sizeOf(i8);
    if (report == null or report[0].size < minimum_size) return;
    const update: Terminal.ProgressUpdate = switch (report[0].state) {
        vt.GHOSTTY_TERMINAL_PROGRESS_STATE_REMOVE => .remove,
        vt.GHOSTTY_TERMINAL_PROGRESS_STATE_SET => .{ .report = .{ .state = .normal, .value = progressValue(report[0].progress) } },
        vt.GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR => .{ .report = .{ .state = .error_state, .value = progressValue(report[0].progress) } },
        vt.GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE => .{ .report = .{ .state = .indeterminate, .value = null } },
        vt.GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE => .{ .report = .{ .state = .paused, .value = progressValue(report[0].progress) } },
        else => return,
    };
    callback(self.progress_report_context, update);
}

fn progressValue(value: i8) ?u8 {
    return if (value < 0) null else @intCast(@min(value, 100));
}

fn clipboardWrite(_: vt.GhosttyTerminal, userdata: ?*anyopaque, write: [*c]const vt.GhosttyClipboardWrite) callconv(.c) vt.GhosttyClipboardWriteResult {
    const self: *Terminal = @ptrCast(@alignCast(userdata orelse return vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR));
    const callback = self.clipboard_write orelse return vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
    const minimum_size = @offsetOf(vt.GhosttyClipboardWrite, "contents_len") + @sizeOf(usize);
    if (write == null or write[0].size < minimum_size) return vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
    if (write[0].contents_len == 0) return clipboardWriteResult(callback(self.clipboard_context, .clear));
    if (write[0].contents == null or write[0].contents_len > std.math.maxInt(usize) / @sizeOf(vt.GhosttyClipboardContent)) return vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;

    for (write[0].contents[0..write[0].contents_len]) |content| {
        if ((content.mime.len != 0 and content.mime.ptr == null) or (content.data.len != 0 and content.data.ptr == null)) return vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA;
        const mime = if (content.mime.len == 0) "" else content.mime.ptr[0..content.mime.len];
        if (!std.mem.eql(u8, mime, "text/plain") and !std.mem.eql(u8, mime, "text/plain;charset=utf-8")) continue;
        const data = if (content.data.len == 0) "" else content.data.ptr[0..content.data.len];
        return clipboardWriteResult(callback(self.clipboard_context, .{ .text = data }));
    }
    return vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED;
}

fn clipboardWriteResult(result: Terminal.ClipboardWriteResult) vt.GhosttyClipboardWriteResult {
    return switch (result) {
        .success => vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS,
        .denied => vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED,
        .unsupported => vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED,
        .busy => vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_BUSY,
        .invalid_data => vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_INVALID_DATA,
        .io_error => vt.GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR,
    };
}

fn currentCellOccupancy(cells: vt.GhosttyRenderStateRowCells) !Terminal.Cell.Occupancy {
    var raw: vt.GhosttyCell = 0;
    try check(vt.ghostty_render_state_row_cells_get(
        cells,
        vt.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW,
        &raw,
    ));
    var wide: vt.GhosttyCellWide = vt.GHOSTTY_CELL_WIDE_NARROW;
    try check(vt.ghostty_cell_get(raw, vt.GHOSTTY_CELL_DATA_WIDE, &wide));
    return switch (wide) {
        vt.GHOSTTY_CELL_WIDE_WIDE => .wide,
        vt.GHOSTTY_CELL_WIDE_SPACER_TAIL => .wide_tail,
        vt.GHOSTTY_CELL_WIDE_SPACER_HEAD => .wrap_spacer,
        else => .narrow,
    };
}

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

fn decodePng(_: ?*anyopaque, allocator: [*c]const vt.GhosttyAllocator, data: [*c]const u8, data_len: usize, out: [*c]vt.GhosttySysImage) callconv(.c) bool {
    if (allocator == null or data == null or out == null or data_len == 0 or data_len > kitty_image_limit) return false;
    var decoded: image_native.ZigonautDecodedImage = undefined;
    if (image_native.zigonaut_decode_png(data, data_len, &decoded) < 0) return false;
    defer image_native.zigonaut_free_decoded_image(decoded.pixels);
    if (decoded.pixels == null or decoded.length == 0 or decoded.length > kitty_image_limit) return false;
    const owned = vt.ghostty_alloc(allocator, decoded.length);
    if (owned == null) return false;
    @memcpy(owned[0..decoded.length], decoded.pixels[0..decoded.length]);
    out.* = .{ .width = decoded.width, .height = decoded.height, .data = owned, .data_len = decoded.length };
    return true;
}

test "libghostty reports shell title changes" {
    const Listener = struct {
        value: []const u8 = "",

        fn changed(context: ?*anyopaque, title: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.value = title;
        }
    };

    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();
    var listener = Listener{};
    try terminal.setTitleChanged(Listener.changed, &listener);

    terminal.feed("\x1b]2;project shell\x07");
    try std.testing.expectEqualStrings("project shell", listener.value);
}

test "libghostty returns terminal queries and in-band size reports" {
    const Listener = struct {
        bytes: std.ArrayList(u8) = .empty,

        fn write(context: ?*anyopaque, bytes: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.bytes.appendSlice(std.testing.allocator, bytes) catch @panic("OOM");
        }
    };

    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();
    var listener = Listener{};
    defer listener.bytes.deinit(std.testing.allocator);
    try terminal.setWritePty(Listener.write, &listener);

    terminal.feed("\x1b[?7$p");
    try std.testing.expectEqualStrings("\x1b[?7;1$y", listener.bytes.items);

    listener.bytes.clearRetainingCapacity();
    terminal.feed("\x1b[?2048h");
    try terminal.resize(100, 40, 9, 18);
    try std.testing.expectEqualStrings("\x1b[48;40;100;720;900t", listener.bytes.items);
}

test "libghostty exposes synchronized output mode" {
    var terminal = try Terminal.init(80, 24, theme.rasmus);
    defer terminal.deinit();

    try std.testing.expect(!terminal.synchronizedOutput());
    terminal.feed("\x1b[?2026h");
    try std.testing.expect(terminal.synchronizedOutput());
    terminal.feed("\x1b[?2026l");
    try std.testing.expect(!terminal.synchronizedOutput());

    try terminal.setSynchronizedOutput(true);
    try std.testing.expect(terminal.synchronizedOutput());
    try terminal.resize(100, 40, 9, 18);
    try std.testing.expect(!terminal.synchronizedOutput());

    try terminal.setSynchronizedOutput(true);
    try terminal.setSynchronizedOutput(false);
    try std.testing.expect(!terminal.synchronizedOutput());
}

test "libghostty emits decoded clipboard writes but ignores reads" {
    const Listener = struct {
        bytes: [64]u8 = undefined,
        length: usize = 0,
        calls: usize = 0,
        cleared: bool = false,

        fn write(context: ?*anyopaque, operation: Terminal.ClipboardWriteOperation) Terminal.ClipboardWriteResult {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            const data = switch (operation) {
                .clear => clear: {
                    self.cleared = true;
                    break :clear "";
                },
                .text => |text| text,
            };
            if (data.len > self.bytes.len) return .invalid_data;
            @memcpy(self.bytes[0..data.len], data);
            self.length = data.len;
            return .success;
        }
    };

    var terminal = try Terminal.init(80, 24, theme.rasmus);
    defer terminal.deinit();
    var listener = Listener{};
    try terminal.setClipboardWrite(Listener.write, &listener);

    terminal.feed("\x1b]52;c;aGVsbG8=\x07");
    try std.testing.expectEqual(@as(usize, 1), listener.calls);
    try std.testing.expectEqualStrings("hello", listener.bytes[0..listener.length]);

    terminal.feed("\x1b]52;c;?\x07");
    terminal.feed("\x1b]52;c;not base64!\x07");
    try std.testing.expectEqual(@as(usize, 1), listener.calls);

    terminal.feed("\x1b]52;c;\x07");
    try std.testing.expectEqual(@as(usize, 2), listener.calls);
    try std.testing.expectEqual(@as(usize, 0), listener.length);
    try std.testing.expect(listener.cleared);
}

test "libghostty tracks OSC 7 working directory" {
    var terminal = try Terminal.init(80, 24, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("\x1b]7;file://localhost/C:/My%20Files\x07");
    const pwd = (try terminal.pwdAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(pwd);
    try std.testing.expectEqualStrings("file://localhost/C:/My%20Files", pwd);

    terminal.feed("\x1b]7;\x07");
    try std.testing.expect((try terminal.pwdAlloc(std.testing.allocator)) == null);
}

test "libghostty parses control sequences into viewport state" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("plain \x1b[31mred\x1b[0m\r\nsecond");
    var buffer: [256]u8 = undefined;
    const viewport = try terminal.writeViewportText(&buffer);

    try std.testing.expectEqualStrings("plain red\nsecond", viewport);
}

test "scrollbar tracks and scrolls the viewport" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive");
    const bottom = try terminal.scrollbar();
    try std.testing.expectEqual(@as(u64, 5), bottom.total);
    try std.testing.expectEqual(@as(u64, 3), bottom.len);
    try std.testing.expectEqual(@as(u64, 2), bottom.offset);

    terminal.scrollViewport(-1);
    const scrolled = try terminal.scrollbar();
    try std.testing.expectEqual(@as(u64, 1), scrolled.offset);
}

test "OSC 133 primary prompts navigate through scrollback" {
    var terminal = try Terminal.init(12, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("\x1b]133;A\x07PS> \x1b]133;B\x07one\x1b]133;C\x07\r\nfirst\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> \x1b]133;B\x07two\x1b]133;C\x07\r\nsecond\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> ");

    try std.testing.expect(try terminal.navigatePrompt(false));
    const previous = try terminal.scrollbar();
    try std.testing.expect(previous.offset < previous.total - previous.len);
    try std.testing.expect(try terminal.navigatePrompt(true));
    const next = try terminal.scrollbar();
    try std.testing.expect(next.offset > previous.offset);
}

test "last command output uses OSC 133 semantic boundaries" {
    var terminal = try Terminal.init(20, 4, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("banner\r\n\x1b]133;A\x07PS> \x1b]133;B\x07echo one\x1b]133;C\x07\r\none\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> \x1b]133;B\x07echo two\x1b]133;C\x07\r\ntwo\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> ");

    const output = (try terminal.lastCommandOutputAlloc(std.testing.allocator)).?;
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("two", output);
}

test "empty latest OSC 133 command does not reuse older output" {
    var terminal = try Terminal.init(24, 5, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("\x1b]133;A\x07PS> \x1b]133;B\x07echo old\x1b]133;C\x07\r\nold\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> \x1b]133;B\x07\x1b]133;C\x07\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> ");
    try std.testing.expect((try terminal.lastCommandOutputAlloc(std.testing.allocator)) == null);
}

test "startup text is not command output for an empty integrated command" {
    var terminal = try Terminal.init(24, 4, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("startup banner\r\n\x1b]133;A\x07PS> \x1b]133;B\x07\x1b]133;C\x07\r\n\x1b]133;D;0\x07\x1b]133;A\x07PS> ");
    try std.testing.expect((try terminal.lastCommandOutputAlloc(std.testing.allocator)) == null);
}

test "text without semantic prompts has no command output" {
    var terminal = try Terminal.init(12, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("ordinary output");
    try std.testing.expect((try terminal.lastCommandOutputAlloc(std.testing.allocator)) == null);
}

test "search row resolves UTF-8 matches in scrollback screen coordinates" {
    var terminal = try Terminal.init(12, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("old needle\r\nnew\r\nlast needle");
    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.testing.allocator);
    var scratch = Terminal.SearchScratch{};
    defer scratch.deinit(std.testing.allocator);
    const total = try terminal.totalRows();
    for (0..total) |row| try terminal.searchRow(std.testing.allocator, &scratch, @intCast(row), "needle", &matches);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(u32, 0), matches.items[0].row);
    try std.testing.expectEqual(@as(u16, 4), matches.items[0].start);
}

test "cached search rows preserve text and byte-to-column mappings across queries" {
    var terminal = try Terminal.init(12, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("a\xc3\xa9 needle");
    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.testing.allocator);
    var cache = Terminal.SearchCache{};
    defer cache.deinit(std.testing.allocator);

    try terminal.searchRowCached(std.testing.allocator, &cache, 0, "needle", &matches);
    try std.testing.expectEqual(@as(u16, 3), matches.items[0].start);
    const cached_text_pointer = cache.text.items.ptr;
    matches.clearRetainingCapacity();
    try terminal.searchRowCached(std.testing.allocator, &cache, 0, "\xc3\xa9", &matches);
    try std.testing.expectEqual(cached_text_pointer, cache.text.items.ptr);
    try std.testing.expectEqual(@as(u16, 1), matches.items[0].start);
    try std.testing.expectEqual(@as(u16, 2), matches.items[0].end);

    terminal.feed("\rchanged");
    cache.clear(std.testing.allocator);
    matches.clearRetainingCapacity();
    try terminal.searchRowCached(std.testing.allocator, &cache, 0, "changed", &matches);
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(u16, 0), matches.items[0].start);
}

test "wide cell tails do not add spaces to viewport text" {
    var terminal = try Terminal.init(8, 2, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("中X");
    var buffer: [64]u8 = undefined;
    const viewport = try terminal.writeViewportText(&buffer);

    try std.testing.expectEqualStrings("中X", viewport);
}

test "selected text follows a forward or backward viewport range" {
    var terminal = try Terminal.init(8, 3, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("abcdef\r\nsecond\r\nthird");

    try terminal.setSelection(.{
        .anchor = .{ .x = 2, .y = 0 },
        .focus = .{ .x = 2, .y = 1 },
    });
    const forward = try terminal.selectedTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(forward);
    try std.testing.expectEqualStrings("cdef\nsec", forward);

    try terminal.setSelection(.{
        .anchor = .{ .x = 2, .y = 1 },
        .focus = .{ .x = 2, .y = 0 },
    });
    const backward = try terminal.selectedTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(backward);
    try std.testing.expectEqualStrings(forward, backward);
}

test "selecting either half of a wide cell copies the grapheme once" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("中X");

    try terminal.setSelection(.{
        .anchor = .{ .x = 1, .y = 0 },
        .focus = .{ .x = 1, .y = 0 },
    });
    const selected = try terminal.selectedTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("中", selected);
}

test "selected text excludes ANSI escape sequences" {
    var terminal = try Terminal.init(8, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("\x1b[31mred\x1b[0m plain");

    try terminal.setSelection(.{
        .anchor = .{ .x = 0, .y = 0 },
        .focus = .{ .x = 7, .y = 0 },
    });
    const selected = try terminal.selectedTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(selected);
    try std.testing.expectEqualStrings("red plai", selected);
}

test "resolves OSC 8 and detected links at viewport cells" {
    var terminal = try Terminal.init(80, 4, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("\x1b]8;;https://example.com/target\x1b\\label\x1b]8;;\x1b\\\r\nvisit https://ziglang.org/docs now");

    const explicit = (try terminal.linkAtAlloc(std.testing.allocator, .{ .x = 2, .y = 0 })).?;
    defer std.testing.allocator.free(explicit.uri);
    try std.testing.expectEqualStrings("https://example.com/target", explicit.uri);
    try std.testing.expectEqual(@as(u16, 0), explicit.start_column);
    try std.testing.expectEqual(@as(u16, 5), explicit.end_column);

    const detected = (try terminal.linkAtAlloc(std.testing.allocator, .{ .x = 12, .y = 1 })).?;
    defer std.testing.allocator.free(detected.uri);
    try std.testing.expectEqualStrings("https://ziglang.org/docs", detected.uri);
}

test "shrinking rows and columns keeps a bottom-row cursor in bounds" {
    var terminal = try Terminal.init(80, 24, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("\x1b[24;1HX");
    try terminal.resize(79, 20, 9, 18);
    try std.testing.expectEqual(@as(u16, 79), terminal.columns);
    try std.testing.expectEqual(@as(u16, 20), terminal.rows);
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

test "background erase after soft wrap remains reflow content" {
    var terminal = try Terminal.init(8, 3, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("\x1b[41mabcdefghij\x1b[K\x1b[0m");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    for (snapshot.cells.items[8..16]) |cell| {
        try std.testing.expectEqual(theme.rasmus.ansi[1], cell.background);
    }
    for (snapshot.cells.items[10..16]) |cell| {
        try std.testing.expectEqual(@as(u8, 0), cell.codepoint_count);
    }

    try terminal.resize(12, 3, 9, 18);
    try snapshot.capture(std.testing.allocator, &terminal);
    for (snapshot.cells.items[10..16]) |cell| {
        try std.testing.expectEqual(theme.rasmus.ansi[1], cell.background);
        try std.testing.expectEqual(@as(u8, 0), cell.codepoint_count);
    }
}

test "ls background does not create blank cells across repeated reflow" {
    var terminal = try Terminal.init(90, 12, theme.rasmus);
    defer terminal.deinit();

    for (0..40) |_| {
        terminal.feed(
            "drwxrwxrwx 2 iain iain 123456789 Jul 28 08:27 " ++
                "\x1b[0m\x1b[30;42m" ++
                "zig-x86_64-windows-0.10.1-backup-20240728-2" ++
                "\x1b[0m\x1b[K\r\n",
        );
    }

    for (0..4) |_| {
        for ([_]u16{ 54, 74, 44, 79, 90 }) |columns| {
            try terminal.resize(columns, 12, 9, 18);

            var snapshot = Terminal.RenderSnapshot{};
            defer snapshot.deinit(std.testing.allocator);
            try snapshot.capture(std.testing.allocator, &terminal);
            for (snapshot.cells.items, 0..) |cell, index| {
                if (std.meta.eql(theme.rasmus.ansi[2], cell.background)) {
                    try std.testing.expect(cell.codepoint_count != 0);
                    const row = &snapshot.rows.items[index / snapshot.columns()];
                    try std.testing.expect(cell.codepoints(row)[0] != ' ');
                }
            }
        }
    }
}

test "ls symlink target background does not create blank cells across reflow" {
    var terminal = try Terminal.init(160, 12, theme.rasmus);
    defer terminal.deinit();

    for (0..20) |_| {
        terminal.feed(
            "lrwxrwxrwx 1 iain iain 69 Dec 16 2025 " ++
                "\x1b[0m\x1b[01;36mNetHood\x1b[0m -> " ++
                "\x1b[34;42m'/mnt/c/Users/Iain/AppData/Roaming/Microsoft/Windows/Network Shortcuts'" ++
                "\x1b[0m\r\n",
        );
    }

    for (0..4) |_| {
        for ([_]struct { columns: u16, rows: u16 }{
            .{ .columns = 96, .rows = 30 },
            .{ .columns = 54, .rows = 12 },
            .{ .columns = 120, .rows = 36 },
            .{ .columns = 44, .rows = 11 },
            .{ .columns = 160, .rows = 40 },
        }) |size| {
            try terminal.resize(size.columns, size.rows, 9, 18);

            var snapshot = Terminal.RenderSnapshot{};
            defer snapshot.deinit(std.testing.allocator);
            try snapshot.capture(std.testing.allocator, &terminal);
            for (snapshot.cells.items, 0..) |cell, index| {
                if (std.meta.eql(theme.rasmus.ansi[2], cell.background)) {
                    try std.testing.expect(cell.codepoint_count != 0);
                    const row = &snapshot.rows.items[index / snapshot.columns()];
                    if (cell.codepoints(row)[0] == ' ') {
                        const x = index % snapshot.columns();
                        try std.testing.expect(x > 0 and x + 1 < snapshot.columns());
                        try std.testing.expectEqual(@as(u32, 'k'), snapshot.cells.items[index - 1].codepoints(row)[0]);
                        try std.testing.expectEqual(@as(u32, 'S'), snapshot.cells.items[index + 1].codepoints(row)[0]);
                    }
                }
            }
        }
    }
}

test "render state exposes the requested cursor style" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("\x1b[5 q");
    var renderer = TestRenderer{};
    try terminal.renderViewport(&renderer);
    try std.testing.expectEqual(Terminal.Frame.CursorStyle.bar, renderer.frame.?.cursor_style);

    terminal.feed("\x1b[3 q");
    try terminal.renderViewport(&renderer);
    try std.testing.expectEqual(Terminal.Frame.CursorStyle.underline, renderer.frame.?.cursor_style);
}

test "render state normalizes a cursor on a wide cell tail" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("中\x1b[D");
    var renderer = TestRenderer{};
    try terminal.renderViewport(&renderer);
    try std.testing.expectEqual(@as(u16, 0), renderer.frame.?.cursor_x);
    try std.testing.expectEqual(@as(u8, 2), renderer.frame.?.cursor_columns);
}

test "render state exposes text decorations and wide occupancy" {
    var terminal = try Terminal.init(8, 2, theme.rasmus);
    defer terminal.deinit();

    terminal.feed("\x1b[1;2;3;4;9;53;58;2;10;20;30mX\x1b[0m中");
    var renderer = TestRenderer{};
    try terminal.renderViewport(&renderer);

    try std.testing.expect(renderer.x_bold);
    try std.testing.expect(renderer.x_italic);
    try std.testing.expect(renderer.x_faint);
    try std.testing.expect(renderer.x_strikethrough);
    try std.testing.expect(renderer.x_overline);
    try std.testing.expectEqual(@as(u8, 1), renderer.x_underline);
    try std.testing.expectEqual(theme.Color{ .red = 10, .green = 20, .blue = 30 }, renderer.x_underline_color.?);
    try std.testing.expectEqual(@as(usize, 1), renderer.wide_cells);
    try std.testing.expectEqual(@as(usize, 1), renderer.wide_tails);
}

test "render snapshots own cell graphemes" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("X");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    terminal.feed("\rY");

    var renderer = TestRenderer{};
    snapshot.replay(&renderer);
    try std.testing.expectEqual(theme.rasmus.foreground, renderer.x_foreground.?);
}

test "render snapshots own direct Kitty PNG placements" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    try terminal.resize(4, 2, 8, 16);
    terminal.feed("\x1b_Gf=100,a=T,i=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    try std.testing.expectEqual(@as(usize, 1), snapshot.images.items.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.placements.items.len);
    const owned = snapshot.images.items[0];
    const placement = snapshot.placements.items[0];
    const image = Terminal.Image{
        .image_id = owned.image_id,
        .generation = owned.generation,
        .pixels = owned.pixels,
        .width = owned.width,
        .height = owned.height,
        .source_x = placement.source_x,
        .source_y = placement.source_y,
        .source_width = placement.source_width,
        .source_height = placement.source_height,
        .pixel_width = placement.pixel_width,
        .pixel_height = placement.pixel_height,
        .viewport_col = placement.viewport_col,
        .viewport_row = placement.viewport_row,
        .x_offset = placement.x_offset,
        .y_offset = placement.y_offset,
        .z = placement.z,
    };
    try std.testing.expectEqual(@as(u32, 1), image.image_id);
    try std.testing.expect(image.generation != 0);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqual(@as(u32, 1), image.height);
    try std.testing.expectEqual(@as(usize, 4), image.pixels.len);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, image.pixels);
    try std.testing.expectEqual(@as(i32, 0), image.viewport_col);
    try std.testing.expectEqual(@as(i32, 0), image.viewport_row);
    try std.testing.expectEqual(@as(u32, 1), image.source_width);
    try std.testing.expectEqual(@as(u32, 1), image.source_height);

    const saved_pixels = try std.testing.allocator.dupe(u8, image.pixels);
    defer std.testing.allocator.free(saved_pixels);
    const saved_generation = image.generation;
    terminal.feed("\x1b_Gf=100,a=T,i=1;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");
    try snapshot.capture(std.testing.allocator, &terminal);
    try std.testing.expect(snapshot.images.items[0].generation != saved_generation);
    try std.testing.expectEqualSlices(u8, saved_pixels, snapshot.images.items[0].pixels);
    terminal.feed("\x1b_Ga=d,d=I,i=1\x1b\\");
    try std.testing.expectEqualSlices(u8, saved_pixels, snapshot.images.items[0].pixels);
    try snapshot.capture(std.testing.allocator, &terminal);
    try std.testing.expectEqual(@as(usize, 0), snapshot.images.items.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.placements.items.len);
}

test "Kitty snapshot placements share image storage" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    try terminal.resize(4, 2, 8, 16);
    terminal.feed("\x1b_Gf=100,a=T,i=7;iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==\x1b\\");
    terminal.feed("\x1b_Ga=p,i=7,p=2\x1b\\");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    try std.testing.expectEqual(@as(usize, 1), snapshot.images.items.len);
    try std.testing.expectEqual(@as(usize, 2), snapshot.placements.items.len);
    try std.testing.expectEqual(snapshot.placements.items[0].image_index, snapshot.placements.items[1].image_index);
}

test "Kitty placements sort by z then image ID" {
    const Placement = Terminal.RenderSnapshot.Placement;
    const base: Placement = .{
        .image_index = 0,
        .image_id = 4,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .pixel_width = 1,
        .pixel_height = 1,
        .viewport_col = 0,
        .viewport_row = 0,
        .x_offset = 0,
        .y_offset = 0,
        .z = 2,
    };
    var lower_z = base;
    lower_z.z = 1;
    var lower_id = base;
    lower_id.image_id = 3;
    var placements = [_]Placement{ base, lower_id, lower_z };
    Terminal.RenderSnapshot.sortPlacements(&placements);
    try std.testing.expectEqual(@as(i32, 1), placements[0].z);
    try std.testing.expectEqual(@as(u32, 3), placements[1].image_id);
    try std.testing.expectEqual(@as(u32, 4), placements[2].image_id);
}

test "render snapshots preserve clean rows during incremental capture" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("A\r\nB");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    terminal.feed("\rC");
    try snapshot.capture(std.testing.allocator, &terminal);

    try std.testing.expect(snapshot.rows.items[1].dirty);
    try std.testing.expectEqual(@as(u32, 'A'), snapshot.cells.items[0].codepoints(&snapshot.rows.items[0])[0]);
    try std.testing.expectEqual(@as(u32, 'C'), snapshot.cells.items[4].codepoints(&snapshot.rows.items[1])[0]);
    try std.testing.expectEqual(@as(usize, 8), snapshot.cells.items.len);
}

test "incremental snapshots follow styled rows while the viewport scrolls" {
    var terminal = try Terminal.init(72, 8, theme.rasmus);
    defer terminal.deinit();

    var incremental = Terminal.RenderSnapshot{};
    defer incremental.deinit(std.testing.allocator);
    try incremental.capture(std.testing.allocator, &terminal);

    const command = "for i in {1..20}; do printf '\\033[34;42m''/mnt/c/Users/Iain/AppData/Roaming/Microsoft/Windows/Network Shortcuts''\\033[0m\\n'; done";
    for (command) |byte| {
        terminal.feed(&.{byte});
        try incremental.capture(std.testing.allocator, &terminal);
    }
    terminal.feed("\r\n");

    for (0..20) |_| {
        terminal.feed(
            "\x1b[34;42m'/mnt/c/Users/Iain/AppData/Roaming/Microsoft/Windows/Network Shortcuts'" ++
                "\x1b[0m\r\n",
        );
        try incremental.capture(std.testing.allocator, &terminal);

        var full = Terminal.RenderSnapshot{};
        defer full.deinit(std.testing.allocator);
        try full.capture(std.testing.allocator, &terminal);
        try expectSnapshotsEqual(&full, &incremental);
    }
}

test "repeated prompt reflow keeps incremental and full snapshots identical" {
    var terminal = try Terminal.init(52, 8, theme.rasmus);
    defer terminal.deinit();
    terminal.feed(
        "\x1b]133;A\x07" ++
            "\x1b[01;32miain@DESKTOP-2P0L7VP\x1b[00m:" ++
            "\x1b[01;34m/mnt/c/Users/Iain/zigonaut\x1b[00m$ " ++
            "\x1b]133;B\x07",
    );

    var incremental = Terminal.RenderSnapshot{};
    defer incremental.deinit(std.testing.allocator);
    try incremental.capture(std.testing.allocator, &terminal);

    var cycle: usize = 0;
    while (cycle < 4) : (cycle += 1) {
        for ([_]struct { columns: u16, rows: u16 }{
            .{ .columns = 13, .rows = 4 },
            .{ .columns = 52, .rows = 8 },
        }) |size| {
            try terminal.resize(size.columns, size.rows, 9, 18);
            try incremental.capture(std.testing.allocator, &terminal);

            var full = Terminal.RenderSnapshot{};
            try full.capture(std.testing.allocator, &terminal);
            defer full.deinit(std.testing.allocator);
            try expectSnapshotsEqual(&full, &incremental);
        }
    }

    var text: [512]u8 = undefined;
    const viewport = try terminal.writeViewportText(&text);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, viewport, "iain@DESKTOP-2P0L7VP"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, viewport, "/mnt/c/Users/Iain/zigonaut"));
}

test "coalesced symlink reflow keeps incremental and full snapshots identical" {
    var terminal = try Terminal.init(160, 30, theme.rasmus);
    defer terminal.deinit();
    for (0..20) |_| {
        terminal.feed(
            "lrwxrwxrwx 1 iain iain 69 Dec 16 2025 " ++
                "\x1b[0m\x1b[01;36mNetHood\x1b[0m -> " ++
                "\x1b[34;42m'/mnt/c/Users/Iain/AppData/Roaming/Microsoft/Windows/Network Shortcuts'" ++
                "\x1b[0m\r\n",
        );
    }

    var incremental = Terminal.RenderSnapshot{};
    defer incremental.deinit(std.testing.allocator);
    try incremental.capture(std.testing.allocator, &terminal);

    // Window paints are coalesced, so multiple terminal resizes can happen
    // before the next snapshot capture. Returning to the original dimensions
    // must not make the stale snapshot eligible for incremental refresh.
    for (0..8) |_| {
        try terminal.resize(96, 24, 9, 18);
        try terminal.resize(44, 11, 9, 18);
        try terminal.resize(120, 36, 9, 18);
        try terminal.resize(54, 12, 9, 18);
        try terminal.resize(160, 30, 9, 18);
    }
    try incremental.capture(std.testing.allocator, &terminal);

    var full = Terminal.RenderSnapshot{};
    defer full.deinit(std.testing.allocator);
    try full.capture(std.testing.allocator, &terminal);
    try expectSnapshotsEqual(&full, &incremental);
}

test "incremental snapshots refresh cursor-only frame changes" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("A");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    terminal.feed("\x1b[2;3H\x1b[?25l");
    try snapshot.capture(std.testing.allocator, &terminal);

    try std.testing.expect(snapshot.rows.items[0].dirty);
    try std.testing.expect(snapshot.rows.items[1].dirty);
    try std.testing.expectEqual(@as(u16, 2), snapshot.frame.?.cursor_x);
    try std.testing.expectEqual(@as(u16, 1), snapshot.frame.?.cursor_y);
    try std.testing.expect(!snapshot.frame.?.cursor_visible);
    try std.testing.expectEqual(@as(u32, 'A'), snapshot.cells.items[0].codepoints(&snapshot.rows.items[0])[0]);
}

test "incremental snapshots refresh all cells after global color changes" {
    var terminal = try Terminal.init(4, 2, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("AB");

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.testing.allocator);
    try snapshot.capture(std.testing.allocator, &terminal);
    const previous = snapshot.frame.?;
    terminal.feed("\x1b[?5h");
    try snapshot.capture(std.testing.allocator, &terminal);

    try std.testing.expectEqual(previous.foreground, snapshot.frame.?.background);
    try std.testing.expectEqual(previous.background, snapshot.frame.?.foreground);
    for (snapshot.cells.items) |*cell| {
        try std.testing.expectEqual(snapshot.frame.?.foreground, cell.foreground);
        try std.testing.expectEqual(snapshot.frame.?.background, cell.background);
    }
}

test "libghostty encodes navigation keys" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();

    var buffer: [64]u8 = undefined;
    const encoded = try terminal.encodeKey(.arrow_up, .press, 0, 0, &buffer);
    try std.testing.expectEqualStrings("\x1b[A", encoded);
}

test "libghostty encodes physical special and function keys" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b", try terminal.encodeKey(.escape, .press, 0, 0, &buffer));
    try std.testing.expectEqualStrings("\x1b[2~", try terminal.encodeKey(.insert, .press, 0, 0, &buffer));
    try std.testing.expectEqualStrings("\x1bOP", try terminal.encodeKey(.f1, .press, 0, 0, &buffer));
    try std.testing.expectEqual(@as(usize, 0), (try terminal.encodeKey(.f1, .release, 0, 0, &buffer)).len);
}

test "libghostty emits key releases when the terminal requests them" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("\x1b[>2u");

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("\x1b[97u", try terminal.encodeKey(.a, .press, 0, 'a', &buffer));
    try std.testing.expectEqualStrings("\x1b[97;1:3u", try terminal.encodeKey(.a, .release, 0, 'a', &buffer));
}

const TestRenderer = struct {
    frame: ?Terminal.Frame = null,
    x_foreground: ?theme.Color = null,
    x_underline_color: ?theme.Color = null,
    x_bold: bool = false,
    x_italic: bool = false,
    x_faint: bool = false,
    x_strikethrough: bool = false,
    x_overline: bool = false,
    x_underline: u8 = 0,
    wide_cells: usize = 0,
    wide_tails: usize = 0,

    pub fn beginFrame(self: *TestRenderer, frame: Terminal.Frame) void {
        self.frame = frame;
    }

    pub fn beginRow(_: *TestRenderer, _: u16) void {}

    pub fn drawCell(self: *TestRenderer, cell: Terminal.Cell) void {
        if (cell.codepoints.len == 1 and cell.codepoints[0] == 'X') {
            self.x_foreground = cell.foreground;
            self.x_underline_color = cell.underline_color;
            self.x_bold = cell.bold;
            self.x_italic = cell.italic;
            self.x_faint = cell.faint;
            self.x_strikethrough = cell.strikethrough;
            self.x_overline = cell.overline;
            self.x_underline = cell.underline;
        }
        if (cell.occupancy == .wide) self.wide_cells += 1;
        if (cell.occupancy == .wide_tail) self.wide_tails += 1;
    }

    pub fn endRow(_: *TestRenderer, _: u16) void {}

    pub fn drawImage(_: *TestRenderer, _: Terminal.Image) void {}

    pub fn endFrame(_: *TestRenderer, _: Terminal.Frame) void {}
};

fn expectSnapshotsEqual(expected: *const Terminal.RenderSnapshot, actual: *const Terminal.RenderSnapshot) !void {
    try std.testing.expectEqualDeep(expected.frame, actual.frame);
    try std.testing.expectEqual(expected.rows.items.len, actual.rows.items.len);
    try std.testing.expectEqual(expected.cells.items.len, actual.cells.items.len);
    const columns = expected.columns();
    for (expected.rows.items, actual.rows.items, 0..) |*expected_row, *actual_row, y| {
        for (
            expected.cells.items[y * columns ..][0..columns],
            actual.cells.items[y * columns ..][0..columns],
        ) |expected_cell, actual_cell| {
            try std.testing.expectEqual(expected_cell.codepoint_count, actual_cell.codepoint_count);
            try std.testing.expectEqualSlices(
                u32,
                expected_cell.codepoints(expected_row),
                actual_cell.codepoints(actual_row),
            );
            try std.testing.expectEqual(expected_cell.foreground, actual_cell.foreground);
            try std.testing.expectEqual(expected_cell.background, actual_cell.background);
            try std.testing.expectEqual(expected_cell.underline_color, actual_cell.underline_color);
            try std.testing.expectEqual(expected_cell.attributes, actual_cell.attributes);
        }
    }
}
