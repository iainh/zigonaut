const std = @import("std");
const shared = @import("shared");
const Terminal = shared.terminal.Terminal;
const allocator = std.heap.c_allocator;
const native = @import("images.zig").c;

pub extern fn main(c_int, [*][*:0]u8) c_int;

const PaneLayout = struct {
    tree: shared.pane_tree.Tree,
    next_id: u64 = 2,
};
const PaneNode = extern struct {
    id: u64,
    subtree_size: u32,
    ratio: u16,
    split: bool,
    vertical: bool,
};

export fn zgtk_layout_create() ?*PaneLayout {
    const layout = allocator.create(PaneLayout) catch return null;
    layout.* = .{ .tree = shared.pane_tree.Tree.init(allocator, 1) catch {
        allocator.destroy(layout);
        return null;
    } };
    return layout;
}

export fn zgtk_layout_destroy(layout: *PaneLayout) void {
    layout.tree.deinit();
    allocator.destroy(layout);
}

export fn zgtk_layout_split(layout: *PaneLayout, vertical: bool) u64 {
    const id = layout.next_id;
    layout.tree.split(layout.tree.focused orelse return 0, id, id + 1, if (vertical) .top_bottom else .left_right) catch return 0;
    layout.next_id += 2;
    _ = layout.tree.focus(id);
    return id;
}

export fn zgtk_layout_close(layout: *PaneLayout, id: u64) bool {
    return layout.tree.close(id);
}
export fn zgtk_layout_focus(layout: *PaneLayout, id: u64) bool {
    return layout.tree.focus(id);
}
export fn zgtk_layout_focused(layout: *PaneLayout) u64 {
    return layout.tree.focused orelse 0;
}
export fn zgtk_layout_zoomed(layout: *PaneLayout) bool {
    return layout.tree.zoomed != null;
}
export fn zgtk_layout_action(layout: *PaneLayout, action: c_int) bool {
    return switch (action) {
        0...3 => layout.tree.focusDirection(@enumFromInt(action)),
        4, 5 => layout.tree.focusCycle(action == 5),
        6...9 => layout.tree.resizeFocused(@enumFromInt(action - 6), 3277),
        10 => layout.tree.equalize(),
        11 => layout.tree.toggleZoom(),
        else => false,
    };
}
export fn zgtk_layout_ratio(layout: *PaneLayout, id: u64, ratio: u16) bool {
    layout.tree.setRatio(id, ratio) catch return false;
    return true;
}
export fn zgtk_layout_nodes(layout: *PaneLayout, nodes: [*]PaneNode, capacity: usize) usize {
    const count = layout.tree.presentationNodeCount();
    if (capacity < count) return count;
    const Writer = struct {
        output: []PaneNode,
        index: usize = 0,
        pub fn leaf(self: *@This(), id: u64) !void {
            self.output[self.index] = .{ .id = id, .subtree_size = 1, .ratio = 0, .split = false, .vertical = false };
            self.index += 1;
        }
        pub fn split(self: *@This(), id: u64, axis: shared.pane_tree.Axis, ratio: u16) usize {
            const index = self.index;
            self.output[index] = .{ .id = id, .subtree_size = 0, .ratio = ratio, .split = true, .vertical = axis == .top_bottom };
            self.index += 1;
            return index;
        }
        pub fn finishSplit(self: *@This(), index: usize, size: u32) void {
            self.output[index].subtree_size = size;
        }
    };
    var writer = Writer{ .output = nodes[0..capacity] };
    layout.tree.writePresentation(&writer) catch unreachable;
    return count;
}

extern fn zgtk_write(?*anyopaque, [*]const u8, usize) void;
extern fn zgtk_title(?*anyopaque, [*]const u8, usize) void;
extern fn zgtk_clipboard(?*anyopaque, [*]const u8, usize) void;
extern fn zgtk_begin_frame(?*anyopaque, u32, f32, bool) void;
extern fn zgtk_draw_background(?*anyopaque, u16, u16, u16, u32) void;
extern fn zgtk_draw_cell(?*anyopaque, u16, u16, u8, [*]const u8, usize, u32, u32, u32, u16) void;
extern fn zgtk_draw_cursor(?*anyopaque, u16, u16, u8, u8, u32) void;

const Core = struct {
    terminal: Terminal,
    snapshot: Terminal.RenderSnapshot = .{},
    host: ?*anyopaque,
    search: shared.search.State = .{},
    search_cache: Terminal.SearchCache = .{},
    search_failed: bool = false,
    viewport_offset: u64 = 0,
    search_cursor: shared.search.RowCursor = .{ .matches = &.{} },
    search_row: shared.search.RowMatches = .{ .matches = &.{}, .start_index = 0 },
    clipboard_enabled: bool = false,
    clipboard_limit: u32 = 1048576,
    hover: ?Terminal.Link = null,
    link_cache: Terminal.LinkCache = .{},
    visual_dirty: bool = true,
    clear_scene: bool = true,

    fn clipboard(context: ?*anyopaque, operation: Terminal.ClipboardWriteOperation) Terminal.ClipboardWriteResult {
        const self: *Core = @ptrCast(@alignCast(context.?));
        if (!self.clipboard_enabled) return .denied;
        const bytes = switch (operation) {
            .clear => "",
            .text => |text| text,
        };
        Terminal.validateClipboardPayload(bytes, self.clipboard_limit) catch |err| return switch (err) {
            error.TooLarge => .denied,
            error.InvalidData => .invalid_data,
        };
        zgtk_clipboard(self.host, bytes.ptr, bytes.len);
        return .success;
    }

    fn invalidateSearch(self: *Core) void {
        self.search_cache.clear(allocator);
        self.search.reset();
    }

    fn searchStatus(self: *Core) SearchStatus {
        return .{
            .matches = @intCast(self.search.matches.items.len),
            .active = if (self.search.active) |active| @intCast(active) else -1,
            .scanning = self.search.scanning,
            .failed = self.search_failed,
        };
    }

    fn scrollTo(self: *Core, target: u64) void {
        const state = self.terminal.scrollbar() catch return;
        const offset = @min(target, state.total -| state.len);
        const delta: isize = if (offset >= state.offset) @intCast(offset - state.offset) else -@as(isize, @intCast(state.offset - offset));
        self.terminal.scrollViewport(delta);
    }

    fn write(context: ?*anyopaque, bytes: []const u8) void {
        const self: *Core = @ptrCast(@alignCast(context.?));
        zgtk_write(self.host, bytes.ptr, bytes.len);
    }

    fn title(context: ?*anyopaque, bytes: []const u8) void {
        const self: *Core = @ptrCast(@alignCast(context.?));
        zgtk_title(self.host, bytes.ptr, bytes.len);
    }

    pub fn beginFrame(self: *Core, frame: Terminal.Frame) void {
        self.viewport_offset = if (self.terminal.scrollbar()) |state| state.offset else |_| 0;
        self.search_cursor = shared.search.RowCursor.init(self.search.matches.items, self.viewport_offset);
        zgtk_begin_frame(self.host, colour(frame.background), frame.scroll_offset, self.clear_scene);
    }

    pub fn beginRow(self: *Core, y: u16) void {
        self.search_row = self.search_cursor.next(self.viewport_offset + y);
        // Paint the ordinary layer before any glyphs or highlights. This is
        // called only for replayed rows, including default-colour dirty rows.
        const count = self.snapshot.cells.items.len / self.snapshot.rows.items.len;
        var pending: ?shared.background_span.Span = null;
        for (self.snapshot.cells.items[@as(usize, y) * count ..][0..count], 0..) |cell, x| {
            const occupancy: Terminal.Cell.Occupancy = @enumFromInt(cell.attributes.occupancy);
            if (occupancy == .wide_tail) continue;
            const next = shared.background_span.Span{
                .left = @floatFromInt(x),
                .right = @floatFromInt(x + @as(usize, if (occupancy == .wide) 2 else 1)),
                .top = @floatFromInt(y),
                .bottom = @floatFromInt(@as(u32, y) + 1),
                .colour = colour(cell.background),
            };
            if (pending) |*span| {
                if (shared.background_span.zigonaut_background_span_extend(span, &next) != 0) continue;
                zgtk_draw_background(self.host, @intFromFloat(span.left), y, @intFromFloat(span.right - span.left), span.colour);
            }
            pending = next;
        }
        if (pending) |span| zgtk_draw_background(self.host, @intFromFloat(span.left), y, @intFromFloat(span.right - span.left), span.colour);
    }
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
        const highlight = shared.search.highlightRow(self.search_row, self.search.active, cell.x);
        const hovered = if (self.hover) |link| cell.y == link.row and cell.x >= link.start_column and cell.x < link.end_column else false;
        const flags: u16 = @as(u16, @intFromBool(cell.bold)) |
            (@as(u16, @intFromBool(cell.italic)) << 1) |
            (@as(u16, @intFromBool(cell.underline != 0 or hovered)) << 2) |
            (@as(u16, @intFromBool(cell.strikethrough)) << 3) |
            (@as(u16, @intFromBool(cell.faint)) << 4) |
            (@as(u16, @intFromBool(cell.selected)) << 5) |
            (@as(u16, @intFromBool(cell.overline)) << 6) |
            (@as(u16, highlight) << 7);
        zgtk_draw_cell(self.host, cell.x, cell.y, if (cell.occupancy == .wide) 2 else 1, &buffer, length, colour(cell.foreground), colour(cell.background), colour(cell.underline_color), flags);
    }

    pub fn drawImage(self: *Core, image: Terminal.Image) void {
        const borrowed: native.TerminalImage = .{
            .generation = image.generation,
            .pixels = image.pixels.ptr,
            .length = image.pixels.len,
            .image_id = image.image_id,
            .width = image.width,
            .height = image.height,
            .source_x = image.source_x,
            .source_y = image.source_y,
            .source_width = image.source_width,
            .source_height = image.source_height,
            .pixel_width = image.pixel_width,
            .pixel_height = image.pixel_height,
            .viewport_col = image.viewport_col,
            .viewport_row = image.viewport_row,
            .x_offset = image.x_offset,
            .y_offset = image.y_offset,
        };
        native.zgtk_draw_image(self.host, &borrowed);
    }

    pub fn endFrame(self: *Core, frame: Terminal.Frame) void {
        if (frame.cursor_visible) zgtk_draw_cursor(self.host, frame.cursor_x, frame.cursor_y, frame.cursor_columns, @intFromEnum(frame.cursor_style), colour(frame.cursor));
    }
};

fn colour(value: shared.theme.Color) u32 {
    return @as(u32, value.red) << 16 | @as(u32, value.green) << 8 | value.blue;
}

export fn zgtk_create(host: ?*anyopaque) ?*Core {
    if (!native.zgtk_install_png_decoder()) return null;
    const core = allocator.create(Core) catch return null;
    core.* = .{ .terminal = Terminal.init(80, 24, shared.theme.rasmus) catch {
        allocator.destroy(core);
        return null;
    }, .host = host };
    core.terminal.setFractionalScrolling(true) catch {
        zgtk_destroy(core);
        return null;
    };
    core.terminal.setWritePty(Core.write, core) catch {
        zgtk_destroy(core);
        return null;
    };
    core.terminal.setTitleChanged(Core.title, core) catch {
        zgtk_destroy(core);
        return null;
    };
    core.terminal.setClipboardWrite(Core.clipboard, core) catch {
        zgtk_destroy(core);
        return null;
    };
    return core;
}

export fn zgtk_configure(core: *Core, theme: u8, scrollback: u32, intense: u8, clipboard: bool, limit: u32) bool {
    zgtk_clear_hover(core);
    core.visual_dirty = true;
    const palette = switch (theme) {
        1 => shared.theme.parseJson(allocator, @embedFile("fluent-light")) catch return false,
        2 => shared.theme.parseJson(allocator, @embedFile("fluent-dark")) catch return false,
        else => shared.theme.rasmus,
    };
    core.terminal.setTheme(palette) catch return false;
    core.terminal.setScrollbackSize(scrollback) catch return false;
    core.terminal.setIntenseTextStyle(switch (intense) {
        1 => .bold,
        2 => .bright,
        else => .all,
    });
    core.clipboard_enabled = clipboard;
    core.clipboard_limit = limit;
    if (core.search.enabled) core.invalidateSearch();
    return true;
}

export fn zgtk_destroy(core: *Core) void {
    zgtk_clear_hover(core);
    core.link_cache.deinit(allocator);
    core.search.deinit(allocator);
    core.search_cache.deinit(allocator);
    core.snapshot.deinit(allocator);
    core.terminal.deinit();
    allocator.destroy(core);
}

export fn zgtk_feed(core: *Core, bytes: [*]const u8, length: usize) void {
    zgtk_clear_hover(core);
    core.terminal.feed(bytes[0..length]);
    if (core.search.enabled) core.invalidateSearch();
}

export fn zgtk_resize(core: *Core, columns: u16, rows: u16, cell_width: u32, cell_height: u32) bool {
    zgtk_clear_hover(core);
    core.terminal.resize(columns, rows, cell_width, cell_height) catch return false;
    if (core.search.enabled) core.invalidateSearch();
    return true;
}

export fn zgtk_render(core: *Core) bool {
    core.snapshot.capture(allocator, &core.terminal) catch return false;
    core.clear_scene = true;
    core.snapshot.replay(core);
    return true;
}

export fn zgtk_render_retained(core: *Core, force: bool) bool {
    const previous_images = core.snapshot.image_generation;
    const had_images = core.snapshot.images.items.len != 0;
    core.snapshot.capture(allocator, &core.terminal) catch return false;
    core.clear_scene = force or core.visual_dirty;
    core.visual_dirty = false;
    var changed = core.clear_scene or previous_images != core.snapshot.image_generation;
    for (core.snapshot.rows.items) |row| changed = changed or row.dirty;
    if (!changed) {
        // Update presentation without touching retained pixels, including images.
        if (core.snapshot.frame) |frame| core.beginFrame(frame);
        return true;
    }
    core.clear_scene = core.clear_scene or had_images or core.snapshot.images.items.len != 0;
    if (core.clear_scene) core.snapshot.replay(core) else core.snapshot.replayDirty(core);
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
    zgtk_clear_hover(core);
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
    zgtk_clear_hover(core);
    const mutable = allocator.dupe(u8, text[0..length]) catch return false;
    defer allocator.free(mutable);
    const bytes = core.terminal.encodePasteAlloc(allocator, mutable) catch return false;
    defer allocator.free(bytes);
    _ = core.terminal.scrollToBottom() catch return false;
    zgtk_write(core.host, bytes.ptr, bytes.len);
    return true;
}

export fn zgtk_scroll(core: *Core, lines: c_int) void {
    zgtk_clear_hover(core);
    core.terminal.scrollViewport(lines);
}

export fn zgtk_scroll_fractional(core: *Core, rows: f64) bool {
    if (!std.math.isFinite(rows)) return false;
    zgtk_clear_hover(core);
    return core.terminal.scrollViewportFractional(rows) catch false;
}

export fn zgtk_mouse_tracking(core: *Core) bool {
    return core.terminal.mouseTracking();
}

export fn zgtk_mouse(core: *Core, action: u8, button: u8, x: i32, y: i32, width: u32, height: u32, cell_width: u32, cell_height: u32, padding: u32, modifiers: u16, any_pressed: bool) bool {
    if (action > 2 or button > 7 or !core.terminal.mouseTracking()) return false;
    var buffer: [128]u8 = undefined;
    const bytes = core.terminal.encodeMouse(@enumFromInt(action), @enumFromInt(button), .{ .x = x, .y = y }, modifiers, .{
        .screen_width = width,
        .screen_height = height,
        .cell_width = cell_width,
        .cell_height = cell_height,
        .padding_top = padding,
        .padding_bottom = padding,
        .padding_left = padding,
        .padding_right = padding,
    }, any_pressed, &buffer) catch return true;
    zgtk_write(core.host, bytes.ptr, bytes.len);
    return true;
}

export fn zgtk_clear_hover(core: *Core) void {
    core.visual_dirty = core.visual_dirty or core.hover != null;
    core.hover = null;
    core.link_cache.invalidate();
}

export fn zgtk_link_at(core: *Core, x: u16, y: u16, length: *usize) ?[*]const u8 {
    length.* = 0;
    const revision = core.link_cache.revision;
    const was_hovered = core.hover != null;
    core.hover = core.link_cache.lookup(allocator, &core.terminal, .{ .x = x, .y = y }) catch null;
    if (core.link_cache.revision != revision and (was_hovered or core.hover != null)) core.visual_dirty = true;
    const link = core.hover orelse return null;
    length.* = link.uri.len;
    return link.uri.ptr;
}

export fn zgtk_focus(core: *Core, focused: bool) void {
    core.visual_dirty = true;
    core.terminal.setFocused(focused);
}

export fn zgtk_select(core: *Core, x: u16, y: u16, begin: bool, rectangle: bool) bool {
    const last_row = core.terminal.rows - @as(u16, @intFromBool(core.terminal.scroll_fraction == 0));
    const point: Terminal.Point = .{ .x = @min(x, core.terminal.columns - 1), .y = @min(y, last_row) };
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

export fn zgtk_copy_last_command(core: *Core) bool {
    const text = (core.terminal.lastCommandOutputAlloc(allocator) catch return false) orelse return false;
    defer allocator.free(text);
    zgtk_clipboard(core.host, text.ptr, text.len);
    return true;
}

const SearchStatus = extern struct {
    matches: u32,
    active: i32,
    scanning: bool,
    failed: bool,
};

export fn zgtk_search_set(core: *Core, query: [*]const u8, length: usize) bool {
    core.visual_dirty = true;
    if (!core.search.enabled) {
        core.search.saved_offset = if (core.terminal.scrollbar()) |state| state.offset else |_| null;
        core.search.enabled = true;
    }
    core.search.query.clearRetainingCapacity();
    core.search_failed = length > 256 or !std.unicode.utf8ValidateSlice(query[0..length]);
    if (!core.search_failed) core.search.query.appendSlice(allocator, query[0..length]) catch {
        core.search_failed = true;
    };
    core.search.reset();
    return !core.search_failed;
}

// Scan a bounded batch per GTK idle callback, leaving PTY I/O and input live.
export fn zgtk_search_tick(core: *Core) SearchStatus {
    if (!core.search.scanning or core.search_failed) return core.searchStatus();
    core.visual_dirty = true;
    const total = core.terminal.totalRows() catch {
        core.search.scanning = false;
        core.search_failed = true;
        return core.searchStatus();
    };
    const limit = @min(total, @as(u64, core.search.next_row) + 32);
    while (core.search.next_row < limit) : (core.search.next_row += 1) {
        core.terminal.searchRowCached(allocator, &core.search_cache, core.search.next_row, core.search.query.items, &core.search.matches) catch {
            core.search.scanning = false;
            core.search_failed = true;
            break;
        };
    }
    core.search.scanning = !core.search_failed and core.search.next_row < total;
    return core.searchStatus();
}

export fn zgtk_search_navigate(core: *Core, forward: bool) SearchStatus {
    zgtk_clear_hover(core);
    core.visual_dirty = true;
    if (core.search.navigate(forward)) |match| core.scrollTo(match.row);
    return core.searchStatus();
}

export fn zgtk_search_clear(core: *Core) void {
    zgtk_clear_hover(core);
    core.visual_dirty = true;
    if (core.search.saved_offset) |offset| core.scrollTo(offset);
    core.search.deinit(allocator);
    core.search = .{};
    core.search_cache.deinit(allocator);
    core.search_failed = false;
}

export fn zgtk_navigate_prompt(core: *Core, forward: bool) bool {
    zgtk_clear_hover(core);
    core.terminal.setSelection(null) catch return false;
    return core.terminal.navigatePrompt(forward) catch false;
}
