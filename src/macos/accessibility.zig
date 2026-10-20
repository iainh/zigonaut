const std = @import("std");

pub const maximum_length = 100_000;
pub const Range = extern struct { location: u32 = 0, length: u32 = 0 };
pub const Span = extern struct { range: Range, column: u16, row: u16, columns: u16, reserved: u16 = 0 };
pub const Rect = extern struct { x: u32 = 0, y: u32 = 0, width: u32 = 0, height: u32 = 0 };
pub const View = extern struct {
    text: [*]const u16,
    lines: [*]const Range,
    selections: [*]const Range,
    spans: [*]const Span,
    text_count: u32,
    line_count: u32,
    selection_count: u32,
    span_count: u32,
    cursor: Range,
};

/// A single allocation owns the UTF-16 text and all POD tables. No terminal or
/// caller pointers survive construction; readers need neither locks nor a core.
pub const Layout = struct {
    allocation: []u64,
    text: []u16,
    lines: []Range,
    selections: []Range,
    spans: []Span,
    text_count: u32 = 0,
    line_count: u32 = 0,
    selection_count: u32 = 0,
    span_count: u32 = 0,
    cursor: Range = .{},

    pub fn create(allocator: std.mem.Allocator, columns: u16, rows: u16, limit: u32) !*Layout {
        const length: usize = @min(limit, maximum_length);
        const spans: usize = @min(@as(usize, columns) * rows, length);
        const lines: usize = @min(@as(usize, rows), length + 1);
        // Reserve padding for each region's natural alignment (at most eight).
        // The allocation is not zeroed; only initialized prefixes are exposed.
        const bytes = @sizeOf(Layout) + length * 2 + spans * (@sizeOf(Span) + @sizeOf(Range)) + lines * @sizeOf(Range) + 5 * 8;
        const allocation = try allocator.alloc(u64, std.math.divCeil(usize, bytes, 8) catch unreachable);
        errdefer allocator.free(allocation);
        var arena = std.heap.FixedBufferAllocator.init(std.mem.sliceAsBytes(allocation));
        const a = arena.allocator();
        const self = try a.create(Layout);
        self.* = .{
            .allocation = allocation,
            .text = try a.alloc(u16, length),
            .lines = try a.alloc(Range, lines),
            .selections = try a.alloc(Range, spans),
            .spans = try a.alloc(Span, spans),
        };
        return self;
    }

    pub fn destroy(self: *Layout, allocator: std.mem.Allocator) void {
        allocator.free(self.allocation);
    }

    pub fn view(self: *const Layout) View {
        return .{ .text = self.text.ptr, .lines = self.lines.ptr, .selections = self.selections.ptr, .spans = self.spans.ptr, .text_count = self.text_count, .line_count = self.line_count, .selection_count = self.selection_count, .span_count = self.span_count, .cursor = self.cursor };
    }

    pub fn valid(self: *const Layout, range: Range) bool {
        return range.location <= self.text_count and range.length <= self.text_count - range.location;
    }

    pub fn line(self: *const Layout, index: u32) ?u32 {
        if (index > self.text_count) return null;
        // Lower bound preserves the native layout's newline and end affinity.
        var low: u32 = 0;
        var high = self.line_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const range = self.lines[middle];
            if (index <= range.location + range.length) high = middle else low = middle + 1;
        }
        return if (low < self.line_count) low else self.line_count -| 1;
    }

    pub fn rect(self: *const Layout, range: Range) Rect {
        if (!self.valid(range)) return .{};
        var low: u32 = 0;
        var high = self.span_count;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const span = self.spans[middle];
            const end = span.range.location + span.range.length;
            const before = if (range.length == 0) end < range.location else end <= range.location;
            if (before) low = middle + 1 else high = middle;
        }
        var result: Rect = .{};
        for (self.spans[low..self.span_count]) |span| {
            if (range.length == 0) {
                // Preserve the existing leading/previous-cell caret affinity,
                // including a caret at the end of the buffer.
                return .{ .x = span.column, .y = span.row, .width = span.columns, .height = 1 };
            }
            if (span.range.location >= range.location + range.length) break;
            if (result.height == 0) {
                result = .{ .x = span.column, .y = span.row, .width = span.columns, .height = 1 };
            } else {
                const right = @max(result.x + result.width, @as(u32, span.column) + span.columns);
                const bottom = @max(result.y + result.height, @as(u32, span.row) + 1);
                result.x = @min(result.x, span.column);
                result.y = @min(result.y, span.row);
                result.width = right - result.x;
                result.height = bottom - result.y;
            }
        }
        return result;
    }
};

/// The snapshot is already dense and row-major. Like the Windows AX writer,
/// emit UTF-16 and one run per leading cell; do not sort, hash, or stringify.
pub const Writer = struct {
    layout: *Layout,
    columns: u16,
    rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    row: u16 = 0,
    column: u32 = 0,
    line_start: u32 = 0,
    stopped: bool = false,
    cursor_set: bool = false,

    pub fn beginFrame(_: *Writer, _: anytype) void {}
    pub fn drawImage(_: *Writer, _: anytype) void {}
    pub fn beginRow(self: *Writer, row: u16) void {
        if (self.stopped or row >= self.rows) return;
        self.row = row;
        self.column = 0;
        if (row > 0 and !self.scalar('\n')) {
            self.stopped = true;
            return;
        }
        self.line_start = self.layout.text_count;
    }

    fn scalar(self: *Writer, cp: u32) bool {
        const count: u32 = if (cp > 0xffff) 2 else 1;
        const layout = self.layout;
        if (count > layout.text.len - layout.text_count) return false;
        if (count == 1) {
            layout.text[layout.text_count] = @intCast(cp);
        } else {
            const v = cp - 0x10000;
            layout.text[layout.text_count] = @intCast(0xd800 + (v >> 10));
            layout.text[layout.text_count + 1] = @intCast(0xdc00 + (v & 0x3ff));
        }
        layout.text_count += count;
        return true;
    }

    fn startCell(self: *Writer, x: u16, width: u16) u32 {
        const start = self.layout.text_count;
        if (self.row == self.cursor_y and self.cursor_x >= x and self.cursor_x < @as(u32, x) + width) {
            self.layout.cursor = .{ .location = start };
            self.cursor_set = true;
        }
        return start;
    }

    fn finishCell(self: *Writer, start: u32, x: u16, width: u16, selected: bool) void {
        const layout = self.layout;
        if (layout.text_count == start) {
            self.stopped = true;
            return;
        }
        const range: Range = .{ .location = start, .length = layout.text_count - start };
        layout.spans[layout.span_count] = .{ .range = range, .column = x, .row = self.row, .columns = width };
        layout.span_count += 1;
        if (selected) {
            if (layout.selection_count > 0 and layout.selections[layout.selection_count - 1].location + layout.selections[layout.selection_count - 1].length == start) {
                layout.selections[layout.selection_count - 1].length += range.length;
            } else {
                layout.selections[layout.selection_count] = range;
                layout.selection_count += 1;
            }
        }
        self.column = @as(u32, x) + width;
    }

    fn fillTo(self: *Writer, x: u32) void {
        while (!self.stopped and self.column < x) {
            const column: u16 = @intCast(self.column);
            const start = self.startCell(column, 1);
            _ = self.scalar(' ');
            self.finishCell(start, column, 1, false);
        }
    }

    pub fn drawCell(self: *Writer, cell: anytype) void {
        if (self.stopped or cell.y >= self.rows or cell.x >= self.columns or cell.occupancy == .wide_tail or cell.x < self.column) return;
        self.fillTo(cell.x);
        if (self.stopped) return;
        const width: u16 = @min(if (cell.occupancy == .wide) @as(u16, 2) else 1, self.columns - cell.x);
        const start = self.startCell(cell.x, width);
        if (cell.codepoints.len == 0) {
            _ = self.scalar(' ');
        } else for (cell.codepoints) |cp| {
            if (!self.scalar(cp)) break;
        }
        self.finishCell(start, cell.x, width, cell.selected);
    }

    /// Batched render-record input uses the same writer as prepared snapshots.
    pub fn utf8Cell(self: *Writer, x: u16, width: u16, selected: bool, utf8: []const u8) void {
        if (self.stopped or x >= self.columns or x < self.column) return;
        self.fillTo(x);
        if (self.stopped) return;
        const start = self.startCell(x, width);
        var iterator = (std.unicode.Utf8View.init(utf8) catch unreachable).iterator();
        if (utf8.len == 0) {
            _ = self.scalar(' ');
        } else while (iterator.nextCodepoint()) |cp| {
            if (!self.scalar(cp)) break;
        }
        self.finishCell(start, x, width, selected);
    }

    pub fn endRow(self: *Writer, row: u16) void {
        if (self.stopped or row >= self.rows) return;
        self.fillTo(self.columns);
        if (self.stopped) return;
        const layout = self.layout;
        layout.lines[layout.line_count] = .{ .location = self.line_start, .length = layout.text_count - self.line_start };
        layout.line_count += 1;
    }
    pub fn endFrame(self: *Writer, _: anytype) void {
        if (!self.cursor_set) self.layout.cursor = .{ .location = self.layout.text_count };
    }
};

export fn zigonaut_accessibility_release(layout: ?*Layout) void {
    if (layout) |value| value.destroy(std.heap.c_allocator);
}

export fn zigonaut_accessibility_get_view(layout: *const Layout, output: *View) void {
    output.* = layout.view();
}

export fn zigonaut_accessibility_line(layout: *const Layout, index: u32) i64 {
    return if (layout.line(index)) |value| value else -1;
}

export fn zigonaut_accessibility_grid_rect(layout: *const Layout, range: Range) Rect {
    return layout.rect(range);
}

const abi = @cImport({
    @cInclude("zigonaut_core.h");
});

export fn zigonaut_accessibility_build(columns: u16, rows: u16, cells: ?[*]const abi.zigonaut_render_cell_v1, cell_count: u32, text: ?[*]const u8, text_count: u32, cursor_column: u16, cursor_row: u16, limit: u32) ?*Layout {
    const records = if (cells) |p| p[0..cell_count] else if (cell_count == 0) &.{} else return null;
    const bytes = if (text) |p| p[0..text_count] else if (text_count == 0) &.{} else return null;
    var previous: u32 = 0;
    for (records, 0..) |cell, index| {
        const position = @as(u32, cell.y) * 65536 + cell.x;
        if (index != 0 and position <= previous) return null;
        previous = position;
        if (cell.x >= columns or cell.y >= rows or cell.text_offset > bytes.len or cell.text_length > bytes.len - cell.text_offset) return null;
        if (!std.unicode.utf8ValidateSlice(bytes[cell.text_offset..][0..cell.text_length])) return null;
    }
    const layout = Layout.create(std.heap.c_allocator, columns, rows, limit) catch return null;
    var writer = Writer{ .layout = layout, .columns = columns, .rows = rows, .cursor_x = cursor_column, .cursor_y = cursor_row };
    var index: usize = 0;
    for (0..rows) |row| {
        writer.beginRow(@intCast(row));
        while (index < records.len and records[index].y == row) : (index += 1) {
            const cell = records[index];
            if (cell.occupancy == 2) continue;
            writer.utf8Cell(cell.x, @min(if (cell.occupancy == 1) @as(u16, 2) else 1, columns - cell.x), cell.selected != 0, bytes[cell.text_offset..][0..cell.text_length]);
        }
        writer.endRow(@intCast(row));
        if (writer.stopped) break;
    }
    writer.endFrame({});
    return layout;
}
