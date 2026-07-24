const std = @import("std");
const App = @import("app.zig").App;
const SessionRuntime = @import("session.zig").SessionRuntime;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");

const win = @import("win32.zig").c;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautTerminalView");
const refresh_timer = 1;
const logical_padding = 24;

pub const View = struct {
    hwnd: win.HWND = null,
    model: *App,
    font: win.HFONT,
    pending_high_surrogate: ?u16 = null,
    suppressed_character: ?u16 = null,
    cell_width: u32,
    cell_height: u32,
    columns: u16 = 0,
    rows: u16 = 0,
    dark_theme: bool = true,
    high_contrast: bool = false,
    back_dc: win.HDC = null,
    back_bitmap: win.HBITMAP = null,
    back_original_bitmap: win.HGDIOBJ = null,
    back_width: i32 = 0,
    back_height: i32 = 0,
    last_runtime: ?*SessionRuntime = null,
    last_content_generation: u64 = 0,

    pub fn registerClass(instance: win.HINSTANCE, cursor: win.HCURSOR) !void {
        const window_class = win.WNDCLASSEXW{
            .cbSize = @sizeOf(win.WNDCLASSEXW),
            .style = win.CS_HREDRAW | win.CS_VREDRAW,
            .lpfnWndProc = windowProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = instance,
            .hIcon = null,
            .hCursor = cursor,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        if (win.RegisterClassExW(&window_class) == 0) return error.RegisterTerminalViewClassFailed;
    }

    pub fn init(parent: win.HWND, model: *App, font: win.HFONT) View {
        const cell_size = measureCell(parent, font);
        return .{
            .model = model,
            .font = font,
            .cell_width = cell_size.width,
            .cell_height = cell_size.height,
        };
    }

    pub fn create(self: *View, parent: win.HWND, instance: win.HINSTANCE) !void {
        self.hwnd = win.CreateWindowExW(
            0,
            class_name,
            null,
            win.WS_CHILD | win.WS_VISIBLE | win.WS_CLIPSIBLINGS | win.WS_TABSTOP,
            0,
            0,
            1,
            1,
            parent,
            null,
            instance,
            self,
        ) orelse return error.CreateTerminalViewFailed;
    }

    pub fn move(self: *View, x: i32, y: i32, width: i32, height: i32) void {
        _ = win.MoveWindow(self.hwnd, x, y, @max(width, 1), @max(height, 1), 1);
    }

    pub fn updateFont(self: *View, font: win.HFONT) void {
        self.font = font;
        const cell_size = measureCell(self.hwnd, font);
        self.cell_width = cell_size.width;
        self.cell_height = cell_size.height;
        self.columns = 0;
        self.rows = 0;
        self.resizeSessions();
        self.invalidate();
    }

    pub fn syncSessions(self: *View) void {
        if (self.columns == 0 or self.rows == 0) return;
        self.model.resizeSessions(self.columns, self.rows, self.cell_width, self.cell_height);
    }

    pub fn invalidate(self: *View) void {
        _ = win.InvalidateRect(self.hwnd, null, 0);
    }

    fn refreshIfNeeded(self: *View) void {
        const session = self.model.activeSession() orelse return;
        const runtime = session.runtime orelse return;
        const generation = runtime.contentGeneration();
        if (runtime == self.last_runtime and generation == self.last_content_generation) return;
        self.last_runtime = runtime;
        self.last_content_generation = generation;
        self.invalidate();
    }

    pub fn updateTheme(self: *View, dark_theme: bool, high_contrast: bool) void {
        self.dark_theme = dark_theme;
        self.high_contrast = high_contrast;
        self.invalidate();
    }

    fn resizeSessions(self: *View) void {
        var client: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &client) == 0) return;

        const padding = scaled(logical_padding, win.GetDpiForWindow(self.hwnd));
        const inner_width = @max(client.right - 2 * padding, 1);
        const inner_height = @max(client.bottom - 2 * padding, 1);
        const columns: u16 = @intCast(@min(@divTrunc(inner_width, @as(i32, @intCast(self.cell_width))), std.math.maxInt(u16)));
        const rows: u16 = @intCast(@min(@divTrunc(inner_height, @as(i32, @intCast(self.cell_height))), std.math.maxInt(u16)));
        const safe_columns = @max(columns, 1);
        const safe_rows = @max(rows, 1);
        if (self.columns == safe_columns and self.rows == safe_rows) return;

        self.columns = safe_columns;
        self.rows = safe_rows;
        self.syncSessions();
    }

    fn paint(self: *View) void {
        var ps: win.PAINTSTRUCT = undefined;
        const dc = win.BeginPaint(self.hwnd, &ps);
        defer _ = win.EndPaint(self.hwnd, &ps);

        var client: win.RECT = undefined;
        _ = win.GetClientRect(self.hwnd, &client);
        const width = client.right - client.left;
        const height = client.bottom - client.top;
        if (width <= 0 or height <= 0) return;

        if (self.ensureBackBuffer(dc, width, height)) {
            self.paintFrame(self.back_dc, client);
            _ = win.BitBlt(dc, 0, 0, width, height, self.back_dc, 0, 0, win.SRCCOPY);
        } else {
            self.paintFrame(dc, client);
        }
    }

    fn ensureBackBuffer(self: *View, dc: win.HDC, width: i32, height: i32) bool {
        if (self.back_bitmap != null and self.back_width == width and self.back_height == height) return true;

        if (self.back_dc == null) self.back_dc = win.CreateCompatibleDC(dc);
        if (self.back_dc == null) return false;

        const bitmap = win.CreateCompatibleBitmap(dc, width, height);
        if (bitmap == null) return false;
        const previous = win.SelectObject(self.back_dc, bitmap);
        if (previous == null) {
            _ = win.DeleteObject(bitmap);
            return false;
        }

        if (self.back_bitmap == null) {
            self.back_original_bitmap = previous;
        } else {
            _ = win.DeleteObject(self.back_bitmap);
        }
        self.back_bitmap = bitmap;
        self.back_width = width;
        self.back_height = height;
        return true;
    }

    fn releaseBackBuffer(self: *View) void {
        if (self.back_dc != null and self.back_original_bitmap != null) {
            _ = win.SelectObject(self.back_dc, self.back_original_bitmap);
        }
        if (self.back_bitmap != null) _ = win.DeleteObject(self.back_bitmap);
        if (self.back_dc != null) _ = win.DeleteDC(self.back_dc);
        self.back_dc = null;
        self.back_bitmap = null;
        self.back_original_bitmap = null;
        self.back_width = 0;
        self.back_height = 0;
    }

    fn paintFrame(self: *View, dc: win.HDC, client: win.RECT) void {
        const saved_dc = win.SaveDC(dc);
        defer {
            if (saved_dc != 0) _ = win.RestoreDC(dc, saved_dc);
        }
        const background = if (self.high_contrast)
            win.GetSysColor(win.COLOR_WINDOW)
        else
            colorRef(theme.rasmus.background);
        const foreground = if (self.high_contrast)
            win.GetSysColor(win.COLOR_WINDOWTEXT)
        else
            colorRef(theme.rasmus.foreground);
        fill(dc, client, background);

        _ = win.SelectObject(dc, self.font);
        _ = win.SetBkMode(dc, win.TRANSPARENT);
        _ = win.SetTextColor(dc, foreground);
        const padding = scaled(logical_padding, win.GetDpiForWindow(self.hwnd));

        if (self.model.activeSession()) |session| {
            var renderer = CellRenderer{
                .dc = dc,
                .view = self,
                .client = client,
                .origin_x = padding,
                .origin_y = padding,
            };
            session.runtime.?.renderViewport(&renderer) catch {
                var text_rect = paddedRect(client, padding);
                drawText(dc, "libghostty render state unavailable", &text_rect, win.DT_LEFT | win.DT_TOP);
            };
        } else {
            var text_rect = paddedRect(client, padding);
            drawText(dc, "Open a PowerShell or WSL session.", &text_rect, win.DT_LEFT | win.DT_TOP);
        }
    }

    fn handleKey(self: *View, wparam: win.WPARAM, lparam: win.LPARAM, released: bool) bool {
        if (wparam == win.VK_F4 and win.GetKeyState(win.VK_MENU) < 0) return false;
        const key: Terminal.Key = switch (wparam) {
            win.VK_ESCAPE => .escape,
            win.VK_BACK => .backspace,
            win.VK_TAB => .tab,
            win.VK_RETURN => .enter,
            win.VK_INSERT => .insert,
            win.VK_DELETE => .delete,
            win.VK_END => .end,
            win.VK_HOME => .home,
            win.VK_NEXT => .page_down,
            win.VK_PRIOR => .page_up,
            win.VK_DOWN => .arrow_down,
            win.VK_LEFT => .arrow_left,
            win.VK_RIGHT => .arrow_right,
            win.VK_UP => .arrow_up,
            win.VK_F1 => .f1,
            win.VK_F2 => .f2,
            win.VK_F3 => .f3,
            win.VK_F4 => .f4,
            win.VK_F5 => .f5,
            win.VK_F6 => .f6,
            win.VK_F7 => .f7,
            win.VK_F8 => .f8,
            win.VK_F9 => .f9,
            win.VK_F10 => .f10,
            win.VK_F11 => .f11,
            win.VK_F12 => .f12,
            else => return false,
        };
        const session = self.model.activeSession() orelse return true;
        const repeated = (@as(usize, @bitCast(lparam)) & (1 << 30)) != 0;
        const action: Terminal.KeyAction = if (released) .release else if (repeated) .repeat else .press;
        session.runtime.?.sendKey(key, action, currentModifiers()) catch {};
        if (!released) {
            self.suppressed_character = switch (wparam) {
                win.VK_ESCAPE => 0x1b,
                win.VK_BACK => 0x08,
                win.VK_TAB => 0x09,
                win.VK_RETURN => 0x0d,
                else => null,
            };
        }
        return true;
    }

    fn handleCharacter(self: *View, code_unit: u16) void {
        if (self.suppressCharacter(code_unit)) return;
        const session = self.model.activeSession() orelse return;
        var utf16: [2]u16 = undefined;
        var length: usize = 1;

        if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
            self.pending_high_surrogate = code_unit;
            return;
        } else if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
            const high = self.pending_high_surrogate orelse return;
            utf16[0] = high;
            utf16[1] = code_unit;
            length = 2;
        } else {
            utf16[0] = code_unit;
        }
        self.pending_high_surrogate = null;

        var utf8: [4]u8 = undefined;
        const utf8_length = std.unicode.utf16LeToUtf8(&utf8, utf16[0..length]) catch return;
        session.runtime.?.write(utf8[0..utf8_length]) catch {};
    }

    fn suppressCharacter(self: *View, code_unit: u16) bool {
        const suppressed = self.suppressed_character == code_unit;
        self.suppressed_character = null;
        return suppressed;
    }
};

const CellRenderer = struct {
    dc: win.HDC,
    view: *View,
    client: win.RECT,
    origin_x: i32,
    origin_y: i32,

    pub fn beginFrame(self: *CellRenderer, frame: Terminal.Frame) void {
        if (!self.view.high_contrast) fill(self.dc, self.client, colorRef(frame.background));
        _ = win.SelectObject(self.dc, self.view.font);
        _ = win.SetBkMode(self.dc, win.OPAQUE);
    }

    pub fn drawCell(self: *CellRenderer, cell: Terminal.Cell) void {
        const left = self.origin_x + @as(i32, cell.x) * @as(i32, @intCast(self.view.cell_width));
        const top = self.origin_y + @as(i32, cell.y) * @as(i32, @intCast(self.view.cell_height));
        var rect = win.RECT{
            .left = left,
            .top = top,
            .right = left + @as(i32, @intCast(self.view.cell_width)),
            .bottom = top + @as(i32, @intCast(self.view.cell_height)),
        };
        const foreground = if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(cell.foreground);
        const background = if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOW) else colorRef(cell.background);
        _ = win.SetTextColor(self.dc, foreground);
        _ = win.SetBkColor(self.dc, background);

        var wide: [32]u16 = undefined;
        var length: usize = 0;
        for (cell.codepoints) |codepoint| {
            if (codepoint <= 0xffff) {
                if (codepoint >= 0xd800 and codepoint <= 0xdfff) continue;
                wide[length] = @intCast(codepoint);
                length += 1;
            } else if (codepoint <= 0x10ffff and length + 1 < wide.len) {
                const value = codepoint - 0x10000;
                wide[length] = @intCast(0xd800 + (value >> 10));
                wide[length + 1] = @intCast(0xdc00 + (value & 0x3ff));
                length += 2;
            }
        }
        _ = win.ExtTextOutW(
            self.dc,
            left,
            top,
            win.ETO_CLIPPED | win.ETO_OPAQUE,
            &rect,
            &wide,
            @intCast(length),
            null,
        );
    }

    pub fn endFrame(self: *CellRenderer, frame: Terminal.Frame) void {
        if (!frame.cursor_visible) return;
        const left = self.origin_x + @as(i32, frame.cursor_x) * @as(i32, @intCast(self.view.cell_width));
        const top = self.origin_y + @as(i32, frame.cursor_y) * @as(i32, @intCast(self.view.cell_height));
        const rect = win.RECT{
            .left = left,
            .top = top,
            .right = left + @as(i32, @intCast(self.view.cell_width)),
            .bottom = top + @as(i32, @intCast(self.view.cell_height)),
        };
        frameRect(self.dc, rect, if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(frame.cursor));
    }
};

fn windowProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.c) win.LRESULT {
    if (message == win.WM_NCCREATE) {
        const create: *win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const view: *View = @ptrCast(@alignCast(create.lpCreateParams));
        view.hwnd = hwnd;
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @intCast(@intFromPtr(view)));
    }
    const userdata = win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA);
    const view: ?*View = if (userdata == 0) null else @ptrFromInt(@as(usize, @intCast(userdata)));

    switch (message) {
        win.WM_CREATE => {
            _ = win.SetTimer(hwnd, refresh_timer, 33, null);
            _ = win.SetFocus(hwnd);
            return 0;
        },
        win.WM_LBUTTONDOWN => {
            _ = win.SetFocus(hwnd);
            return 0;
        },
        win.WM_GETDLGCODE => return win.DLGC_WANTTAB,
        win.WM_KEYDOWN, win.WM_SYSKEYDOWN => {
            if (view) |current| {
                if (current.handleKey(wparam, lparam, false)) return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_KEYUP, win.WM_SYSKEYUP => {
            if (view) |current| {
                if (current.handleKey(wparam, lparam, true)) return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_CHAR => {
            if (view) |current| current.handleCharacter(@truncate(wparam));
            return 0;
        },
        win.WM_SYSCHAR => {
            if (view) |current| {
                if (current.suppressCharacter(@truncate(wparam))) return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_SIZE => {
            if (view) |current| current.resizeSessions();
            return 0;
        },
        win.WM_TIMER => {
            if (wparam == refresh_timer) {
                if (view) |current| current.refreshIfNeeded();
            }
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_PAINT => {
            if (view) |current| current.paint();
            return 0;
        },
        win.WM_DESTROY => {
            _ = win.KillTimer(hwnd, refresh_timer);
            if (view) |current| current.releaseBackBuffer();
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

const CellSize = struct { width: u32, height: u32 };

fn measureCell(hwnd: win.HWND, font: win.HFONT) CellSize {
    const dc = win.GetDC(hwnd);
    if (dc == null) return .{ .width = 9, .height = 18 };
    defer _ = win.ReleaseDC(hwnd, dc);

    const previous = win.SelectObject(dc, font);
    defer _ = win.SelectObject(dc, previous);
    var metrics: win.TEXTMETRICW = undefined;
    if (win.GetTextMetricsW(dc, &metrics) == 0) return .{ .width = 9, .height = 18 };
    return .{
        .width = @intCast(@max(metrics.tmAveCharWidth, 1)),
        .height = @intCast(@max(metrics.tmHeight + metrics.tmExternalLeading, 1)),
    };
}

fn scaled(value: i32, dpi: u32) i32 {
    return win.MulDiv(value, @intCast(dpi), 96);
}

fn currentModifiers() u16 {
    var modifiers: u16 = 0;
    if (win.GetKeyState(win.VK_SHIFT) < 0) modifiers |= Terminal.Modifier.shift;
    if (win.GetKeyState(win.VK_CONTROL) < 0) modifiers |= Terminal.Modifier.control;
    if (win.GetKeyState(win.VK_MENU) < 0) modifiers |= Terminal.Modifier.alt;
    if (win.GetKeyState(win.VK_LWIN) < 0 or win.GetKeyState(win.VK_RWIN) < 0) modifiers |= Terminal.Modifier.super;
    return modifiers;
}

fn drawText(dc: win.HDC, text: []const u8, rect: *win.RECT, format: win.UINT) void {
    var wide: [16 * 1024]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&wide, text) catch return;
    _ = win.DrawTextW(dc, &wide, @intCast(length), rect, format);
}

fn paddedRect(rect: win.RECT, padding: i32) win.RECT {
    return .{
        .left = rect.left + padding,
        .top = rect.top + padding,
        .right = rect.right - padding,
        .bottom = rect.bottom - padding,
    };
}

fn fill(dc: win.HDC, rect: win.RECT, color: win.COLORREF) void {
    const brush = win.CreateSolidBrush(color);
    defer _ = win.DeleteObject(brush);
    var mutable_rect = rect;
    _ = win.FillRect(dc, &mutable_rect, brush);
}

fn frameRect(dc: win.HDC, rect: win.RECT, color: win.COLORREF) void {
    const brush = win.CreateSolidBrush(color);
    defer _ = win.DeleteObject(brush);
    var mutable_rect = rect;
    _ = win.FrameRect(dc, &mutable_rect, brush);
}

fn colorRef(color: theme.Color) win.COLORREF {
    return rgb(color.red, color.green, color.blue);
}

fn rgb(red: u8, green: u8, blue: u8) win.COLORREF {
    return @as(win.COLORREF, red) | (@as(win.COLORREF, green) << 8) | (@as(win.COLORREF, blue) << 16);
}
