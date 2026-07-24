const std = @import("std");
const App = @import("app.zig").App;
const Terminal = @import("terminal.zig").Terminal;

const win = @import("win32.zig").c;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautTerminalView");
const refresh_timer = 1;
const padding = 24;

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

    pub fn syncSessions(self: *View) void {
        if (self.columns == 0 or self.rows == 0) return;
        self.model.resizeSessions(self.columns, self.rows, self.cell_width, self.cell_height);
    }

    pub fn invalidate(self: *View) void {
        _ = win.InvalidateRect(self.hwnd, null, 0);
    }

    fn resizeSessions(self: *View) void {
        var client: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &client) == 0) return;

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
        fill(dc, client, rgb(9, 10, 13));

        _ = win.SelectObject(dc, self.font);
        _ = win.SetBkMode(dc, win.TRANSPARENT);
        _ = win.SetTextColor(dc, rgb(198, 206, 220));
        var text_rect = client;
        text_rect.left += padding;
        text_rect.top += padding;
        text_rect.right -= padding;
        text_rect.bottom -= padding;

        if (self.model.activeSession()) |session| {
            var text_buffer: [16 * 1024]u8 = undefined;
            const text = session.runtime.?.writeViewportText(&text_buffer) catch "libghostty render state unavailable";
            drawText(dc, text, &text_rect, win.DT_LEFT | win.DT_TOP | win.DT_NOPREFIX);
        } else {
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
            if (wparam == refresh_timer) _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_PAINT => {
            if (view) |current| current.paint();
            return 0;
        },
        win.WM_DESTROY => {
            _ = win.KillTimer(hwnd, refresh_timer);
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

fn fill(dc: win.HDC, rect: win.RECT, color: win.COLORREF) void {
    const brush = win.CreateSolidBrush(color);
    defer _ = win.DeleteObject(brush);
    var mutable_rect = rect;
    _ = win.FillRect(dc, &mutable_rect, brush);
}

fn rgb(red: u8, green: u8, blue: u8) win.COLORREF {
    return @as(win.COLORREF, red) | (@as(win.COLORREF, green) << 8) | (@as(win.COLORREF, blue) << 16);
}
