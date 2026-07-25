const std = @import("std");
const SessionRuntime = @import("session.zig").SessionRuntime;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");
const win = @import("win32.zig").c;

pub const Context = struct {
    font: win.HFONT,
    foreground: theme.Color,
    background: theme.Color,
    runtime: ?*SessionRuntime,
    cell_width: u32,
    cell_height: u32,
    focused: bool,
    high_contrast: bool,
    origin_x: i32,
    origin_y: i32,
    hover_row: ?u16 = null,
    hover_start: u16 = 0,
    hover_end: u16 = 0,
};

pub const Owner = struct {
    dc: win.HDC = null,
    bitmap: win.HBITMAP = null,
    original_bitmap: win.HGDIOBJ = null,
    width: i32 = 0,
    height: i32 = 0,

    pub fn present(self: *Owner, target: win.HDC, client: win.RECT, context: Context) void {
        const width = client.right - client.left;
        const height = client.bottom - client.top;
        if (self.resize(target, width, height)) {
            paintFrame(self.dc, client, context);
            _ = win.BitBlt(target, 0, 0, width, height, self.dc, 0, 0, win.SRCCOPY);
        } else paintFrame(target, client, context);
    }

    pub fn resize(self: *Owner, target: win.HDC, width: i32, height: i32) bool {
        if (self.bitmap != null and self.width == width and self.height == height) return true;
        if (self.dc == null) self.dc = win.CreateCompatibleDC(target);
        if (self.dc == null) return false;
        const bitmap = win.CreateCompatibleBitmap(target, width, height);
        if (bitmap == null) return false;
        const previous = win.SelectObject(self.dc, bitmap);
        if (previous == null) {
            _ = win.DeleteObject(bitmap);
            return false;
        }
        if (self.bitmap == null) self.original_bitmap = previous else _ = win.DeleteObject(self.bitmap);
        self.bitmap = bitmap;
        self.width = width;
        self.height = height;
        return true;
    }

    pub fn release(self: *Owner) void {
        if (self.dc != null and self.original_bitmap != null) _ = win.SelectObject(self.dc, self.original_bitmap);
        if (self.bitmap != null) _ = win.DeleteObject(self.bitmap);
        if (self.dc != null) _ = win.DeleteDC(self.dc);
        self.* = .{};
    }
};

fn paintFrame(dc: win.HDC, client: win.RECT, context: Context) void {
    const saved_dc = win.SaveDC(dc);
    defer {
        if (saved_dc != 0) _ = win.RestoreDC(dc, saved_dc);
    }
    const background = if (context.high_contrast) win.GetSysColor(win.COLOR_WINDOW) else colorRef(context.background);
    const foreground = if (context.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(context.foreground);
    fill(dc, client, background);
    _ = win.SelectObject(dc, context.font);
    _ = win.SetBkMode(dc, win.TRANSPARENT);
    _ = win.SetTextColor(dc, foreground);
    if (context.runtime) |runtime| {
        var renderer = CellRenderer{ .dc = dc, .context = context, .client = client };
        runtime.renderViewport(&renderer) catch {
            var rect = paddedRect(client, context.origin_x, context.origin_y);
            drawText(dc, "libghostty render state unavailable", &rect);
        };
    } else {
        var rect = paddedRect(client, context.origin_x, context.origin_y);
        drawText(dc, "Open a PowerShell or WSL session.", &rect);
    }
}

const CellRenderer = struct {
    dc: win.HDC,
    context: Context,
    client: win.RECT,
    frame: ?Terminal.Frame = null,

    pub fn beginFrame(self: *CellRenderer, frame: Terminal.Frame) void {
        self.frame = frame;
        if (!self.context.high_contrast) fill(self.dc, self.client, colorRef(frame.background));
        _ = win.SelectObject(self.dc, self.context.font);
        _ = win.SetBkMode(self.dc, win.OPAQUE);
    }
    pub fn beginRow(_: *CellRenderer, _: u16) void {}
    pub fn endRow(_: *CellRenderer, _: u16) void {}

    pub fn drawCell(self: *CellRenderer, cell: Terminal.Cell) void {
        if (cell.occupancy == .wide_tail) return;
        const left = self.context.origin_x + @as(i32, cell.x) * @as(i32, @intCast(self.context.cell_width));
        const top = self.context.origin_y + @as(i32, cell.y) * @as(i32, @intCast(self.context.cell_height));
        const span: i32 = if (cell.occupancy == .wide) 2 else 1;
        const rect = win.RECT{ .left = left, .top = top, .right = left + span * @as(i32, @intCast(self.context.cell_width)), .bottom = top + @as(i32, @intCast(self.context.cell_height)) };
        const solid_cursor = self.context.focused and self.frame.?.cursor_visible and self.frame.?.cursor_style == .block and cell.x >= self.frame.?.cursor_x and cell.x < self.frame.?.cursor_x + self.frame.?.cursor_columns and cell.y == self.frame.?.cursor_y;
        const normal_foreground = if (self.context.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(cell.foreground);
        const normal_background = if (self.context.high_contrast) win.GetSysColor(win.COLOR_WINDOW) else colorRef(cell.background);
        const foreground = if (cell.selected) win.GetSysColor(win.COLOR_HIGHLIGHTTEXT) else if (solid_cursor) normal_background else normal_foreground;
        const background = if (cell.selected)
            win.GetSysColor(win.COLOR_HIGHLIGHT)
        else if (solid_cursor)
            (if (self.context.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(self.frame.?.cursor))
        else
            normal_background;
        const text_foreground = if (cell.faint and !self.context.high_contrast) blend(foreground, background) else foreground;
        const underline = if (self.context.high_contrast) foreground else colorRef(cell.underline_color);
        const decoration = if (cell.faint and !self.context.high_contrast) blend(underline, background) else underline;
        _ = win.SetTextColor(self.dc, text_foreground);
        _ = win.SetBkColor(self.dc, background);
        var wide: [32]u16 = undefined;
        const length = encodeUtf16(cell.codepoints, &wide);
        _ = win.ExtTextOutW(self.dc, left, top, win.ETO_CLIPPED | win.ETO_OPAQUE, &rect, &wide, @intCast(length), null);
        const hovered = self.context.hover_row == cell.y and cell.x >= self.context.hover_start and cell.x < self.context.hover_end;
        if (cell.underline != 0 or hovered) {
            fill(self.dc, .{ .left = rect.left, .top = rect.bottom - 2, .right = rect.right, .bottom = rect.bottom - 1 }, decoration);
            if (cell.underline == 2) fill(self.dc, .{ .left = rect.left, .top = rect.bottom - 4, .right = rect.right, .bottom = rect.bottom - 3 }, decoration);
        }
        if (cell.strikethrough) {
            const middle = rect.top + @divTrunc(rect.bottom - rect.top, 2);
            fill(self.dc, .{ .left = rect.left, .top = middle, .right = rect.right, .bottom = middle + 1 }, text_foreground);
        }
        if (cell.overline) fill(self.dc, .{ .left = rect.left, .top = rect.top, .right = rect.right, .bottom = rect.top + 1 }, text_foreground);
    }

    pub fn endFrame(self: *CellRenderer, frame: Terminal.Frame) void {
        if (!frame.cursor_visible) return;
        const left = self.context.origin_x + @as(i32, frame.cursor_x) * @as(i32, @intCast(self.context.cell_width));
        const top = self.context.origin_y + @as(i32, frame.cursor_y) * @as(i32, @intCast(self.context.cell_height));
        var rect = win.RECT{ .left = left, .top = top, .right = left + @as(i32, @intCast(frame.cursor_columns)) * @as(i32, @intCast(self.context.cell_width)), .bottom = top + @as(i32, @intCast(self.context.cell_height)) };
        const color = if (self.context.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(frame.cursor);
        if (!self.context.focused or frame.cursor_style == .hollow) frameRect(self.dc, rect, color) else switch (frame.cursor_style) {
            .block => {},
            .bar => {
                rect.right = rect.left + @max(@divTrunc(@as(i32, @intCast(self.context.cell_width)), 8), 2);
                fill(self.dc, rect, color);
            },
            .underline => {
                rect.top = rect.bottom - 2;
                fill(self.dc, rect, color);
            },
            .hollow => unreachable,
        }
    }
};

fn encodeUtf16(codepoints: []const u32, output: *[32]u16) usize {
    var length: usize = 0;
    for (codepoints) |codepoint| if (codepoint <= 0xffff) {
        if (codepoint >= 0xd800 and codepoint <= 0xdfff) continue;
        output[length] = @intCast(codepoint);
        length += 1;
    } else if (codepoint <= 0x10ffff and length + 1 < output.len) {
        const value = codepoint - 0x10000;
        output[length] = @intCast(0xd800 + (value >> 10));
        output[length + 1] = @intCast(0xdc00 + (value & 0x3ff));
        length += 2;
    };
    return length;
}
fn drawText(dc: win.HDC, text: []const u8, rect: *win.RECT) void {
    var wide: [16 * 1024]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&wide, text) catch return;
    _ = win.DrawTextW(dc, &wide, @intCast(length), rect, win.DT_LEFT | win.DT_TOP);
}
fn paddedRect(rect: win.RECT, x: i32, y: i32) win.RECT {
    return .{ .left = rect.left + x, .top = rect.top + y, .right = rect.right - x, .bottom = rect.bottom - y };
}
fn fill(dc: win.HDC, rect: win.RECT, color: win.COLORREF) void {
    _ = win.SetDCBrushColor(dc, color);
    const brush: win.HBRUSH = @ptrCast(@alignCast(win.GetStockObject(win.DC_BRUSH)));
    var mutable = rect;
    _ = win.FillRect(dc, &mutable, brush);
}
fn frameRect(dc: win.HDC, rect: win.RECT, color: win.COLORREF) void {
    _ = win.SetDCBrushColor(dc, color);
    const brush: win.HBRUSH = @ptrCast(@alignCast(win.GetStockObject(win.DC_BRUSH)));
    var mutable = rect;
    _ = win.FrameRect(dc, &mutable, brush);
}
fn colorRef(color: theme.Color) win.COLORREF {
    return rgb(color.red, color.green, color.blue);
}
fn rgb(r: u8, g: u8, b: u8) win.COLORREF {
    return @as(win.COLORREF, r) | (@as(win.COLORREF, g) << 8) | (@as(win.COLORREF, b) << 16);
}
fn blend(foreground: win.COLORREF, background: win.COLORREF) win.COLORREF {
    return rgb(@intCast(((foreground & 0xff) + (background & 0xff)) / 2), @intCast((((foreground >> 8) & 0xff) + ((background >> 8) & 0xff)) / 2), @intCast((((foreground >> 16) & 0xff) + ((background >> 16) & 0xff)) / 2));
}
