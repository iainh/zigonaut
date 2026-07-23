const std = @import("std");
const app_model = @import("app.zig");

const win = @cImport({
    @cDefine("UNICODE", "1");
    @cDefine("_UNICODE", "1");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("dwmapi.h");
});

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut");
const font_name = std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");

const command_new_powershell = 1001;
const command_new_wsl = 1002;
const command_tab_base = 1100;
const command_close_tab = 1200;
const refresh_timer = 1;
const terminal_left = 16;
const terminal_top = 108;
const terminal_margin = 16;
const terminal_padding = 24;

const State = struct {
    model: app_model.App,
    font: win.HFONT,
    pending_high_surrogate: ?u16 = null,
    cell_width: u32,
    cell_height: u32,
    columns: u16 = 0,
    rows: u16 = 0,
};

var state: ?State = null;

pub fn main() !void {
    const instance = win.GetModuleHandleW(null);
    const arrow_cursor: win.LPCWSTR = @ptrFromInt(32512);
    const cursor = win.LoadCursorW(null, arrow_cursor);
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
    if (win.RegisterClassExW(&window_class) == 0) return error.RegisterWindowClassFailed;

    const hwnd = win.CreateWindowExW(
        0,
        class_name,
        window_title,
        win.WS_OVERLAPPEDWINDOW | win.WS_VISIBLE,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        1100,
        700,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;

    var dark_mode: win.BOOL = 1;
    _ = win.DwmSetWindowAttribute(hwnd, 20, &dark_mode, @sizeOf(win.BOOL));

    var message: win.MSG = undefined;
    while (win.GetMessageW(&message, null, 0, 0) > 0) {
        _ = win.TranslateMessage(&message);
        _ = win.DispatchMessageW(&message);
    }
}

fn windowProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.c) win.LRESULT {
    switch (message) {
        win.WM_CREATE => {
            const font = win.CreateFontW(
                -18,
                0,
                0,
                0,
                win.FW_NORMAL,
                0,
                0,
                0,
                win.DEFAULT_CHARSET,
                win.OUT_DEFAULT_PRECIS,
                win.CLIP_DEFAULT_PRECIS,
                win.CLEARTYPE_QUALITY,
                win.FIXED_PITCH | win.FF_MODERN,
                font_name,
            );
            const cell_size = measureCell(hwnd, font);
            state = .{
                .model = app_model.App.init(std.heap.page_allocator),
                .font = font,
                .cell_width = cell_size.width,
                .cell_height = cell_size.height,
            };
            _ = state.?.model.addSession(.powershell) catch return -1;
            resizeSessions(hwnd);
            _ = win.SetTimer(hwnd, refresh_timer, 33, null);
            return 0;
        },
        win.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (command == command_new_powershell) {
                _ = state.?.model.addSession(.powershell) catch return 0;
                resizeSessions(hwnd);
            } else if (command == command_new_wsl) {
                _ = state.?.model.addSession(.wsl) catch return 0;
                resizeSessions(hwnd);
            } else if (command == command_close_tab) {
                if (state.?.model.active) |active| state.?.model.closeSession(active);
            } else if (command >= command_tab_base and command < command_tab_base + 32) {
                state.?.model.activate(command - command_tab_base);
            }
            _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_LBUTTONUP => {
            handleClick(hwnd, pointX(lparam), pointY(lparam));
            return 0;
        },
        win.WM_KEYDOWN, win.WM_SYSKEYDOWN => {
            if (handleKey(wparam, lparam)) return 0;
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_CHAR => {
            handleCharacter(@truncate(wparam));
            return 0;
        },
        win.WM_SIZE => {
            resizeSessions(hwnd);
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_TIMER => {
            if (wparam == refresh_timer) _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        win.WM_DESTROY => {
            _ = win.KillTimer(hwnd, refresh_timer);
            if (state) |*current| {
                current.model.deinit();
                _ = win.DeleteObject(current.font);
            }
            state = null;
            win.PostQuitMessage(0);
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn pointX(value: win.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(value))))));
}

fn pointY(value: win.LPARAM) i32 {
    return @as(i16, @bitCast(@as(u16, @truncate(@as(usize, @bitCast(value)) >> 16))));
}

fn handleClick(hwnd: win.HWND, x: i32, y: i32) void {
    if (y < 52) {
        if (x >= 16 and x < 136) {
            sendCommand(hwnd, command_new_powershell);
        } else if (x >= 144 and x < 220) {
            sendCommand(hwnd, command_new_wsl);
        } else if (x >= 228 and x < 266) {
            sendCommand(hwnd, command_close_tab);
        }
        return;
    }
    if (y >= 56 and y < 96 and x >= 16) {
        const index: u16 = @intCast(@divTrunc(x - 16, 168));
        sendCommand(hwnd, command_tab_base + index);
    }
}

fn handleKey(wparam: win.WPARAM, lparam: win.LPARAM) bool {
    const key: @import("terminal.zig").Terminal.Key = switch (wparam) {
        win.VK_DELETE => .delete,
        win.VK_END => .end,
        win.VK_HOME => .home,
        win.VK_NEXT => .page_down,
        win.VK_PRIOR => .page_up,
        win.VK_DOWN => .arrow_down,
        win.VK_LEFT => .arrow_left,
        win.VK_RIGHT => .arrow_right,
        win.VK_UP => .arrow_up,
        else => return false,
    };
    const session = state.?.model.activeSession() orelse return true;
    const repeat = (@as(usize, @bitCast(lparam)) & (1 << 30)) != 0;
    session.runtime.?.sendKey(key, repeat, currentModifiers()) catch {};
    return true;
}

fn handleCharacter(code_unit: u16) void {
    const session = state.?.model.activeSession() orelse return;
    var utf16: [2]u16 = undefined;
    var length: usize = 1;

    if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
        state.?.pending_high_surrogate = code_unit;
        return;
    } else if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
        const high = state.?.pending_high_surrogate orelse return;
        utf16[0] = high;
        utf16[1] = code_unit;
        length = 2;
    } else {
        utf16[0] = code_unit;
    }
    state.?.pending_high_surrogate = null;

    var utf8: [4]u8 = undefined;
    const utf8_length = std.unicode.utf16LeToUtf8(&utf8, utf16[0..length]) catch return;
    session.runtime.?.write(utf8[0..utf8_length]) catch {};
}

fn currentModifiers() u16 {
    const Modifier = @import("terminal.zig").Terminal.Modifier;
    var modifiers: u16 = 0;
    if (win.GetKeyState(win.VK_SHIFT) < 0) modifiers |= Modifier.shift;
    if (win.GetKeyState(win.VK_CONTROL) < 0) modifiers |= Modifier.control;
    if (win.GetKeyState(win.VK_MENU) < 0) modifiers |= Modifier.alt;
    if (win.GetKeyState(win.VK_LWIN) < 0 or win.GetKeyState(win.VK_RWIN) < 0) modifiers |= Modifier.super;
    return modifiers;
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

fn resizeSessions(hwnd: win.HWND) void {
    if (state == null) return;
    var client: win.RECT = undefined;
    if (win.GetClientRect(hwnd, &client) == 0) return;

    const inner_width = @max(client.right - terminal_left - terminal_margin - 2 * terminal_padding, 1);
    const inner_height = @max(client.bottom - terminal_top - terminal_margin - 2 * terminal_padding, 1);
    const columns: u16 = @intCast(@min(@divTrunc(inner_width, @as(i32, @intCast(state.?.cell_width))), std.math.maxInt(u16)));
    const rows: u16 = @intCast(@min(@divTrunc(inner_height, @as(i32, @intCast(state.?.cell_height))), std.math.maxInt(u16)));
    const safe_columns = @max(columns, 1);
    const safe_rows = @max(rows, 1);
    if (state.?.columns == safe_columns and state.?.rows == safe_rows) return;

    state.?.columns = safe_columns;
    state.?.rows = safe_rows;
    state.?.model.resizeSessions(safe_columns, safe_rows, state.?.cell_width, state.?.cell_height);
}

fn sendCommand(hwnd: win.HWND, command: u16) void {
    _ = win.SendMessageW(hwnd, win.WM_COMMAND, command, 0);
}

fn paint(hwnd: win.HWND) void {
    var ps: win.PAINTSTRUCT = undefined;
    const dc = win.BeginPaint(hwnd, &ps);
    defer _ = win.EndPaint(hwnd, &ps);

    var client: win.RECT = undefined;
    _ = win.GetClientRect(hwnd, &client);
    fill(dc, client, rgb(15, 17, 21));

    _ = win.SelectObject(dc, state.?.font);
    _ = win.SetBkMode(dc, win.TRANSPARENT);

    drawButton(dc, .{ .left = 16, .top = 12, .right = 136, .bottom = 44 }, "PowerShell", rgb(51, 58, 72));
    drawButton(dc, .{ .left = 144, .top = 12, .right = 220, .bottom = 44 }, "+ WSL", rgb(51, 58, 72));
    drawButton(dc, .{ .left = 228, .top = 12, .right = 266, .bottom = 44 }, "x", rgb(83, 43, 50));

    const model = &state.?.model;
    for (model.sessions.items, 0..) |session, index| {
        const left: i32 = 16 + @as(i32, @intCast(index)) * 168;
        const active = model.active != null and model.active.? == index;
        drawButton(
            dc,
            .{ .left = left, .top = 56, .right = left + 160, .bottom = 94 },
            session.shell.title(),
            if (active) rgb(70, 83, 111) else rgb(31, 35, 43),
        );
    }

    var terminal_rect = win.RECT{
        .left = terminal_left,
        .top = terminal_top,
        .right = client.right - terminal_margin,
        .bottom = client.bottom - terminal_margin,
    };
    fill(dc, terminal_rect, rgb(9, 10, 13));
    terminal_rect.left += terminal_padding;
    terminal_rect.top += terminal_padding;
    terminal_rect.right -= terminal_padding;
    terminal_rect.bottom -= terminal_padding;
    _ = win.SetTextColor(dc, rgb(198, 206, 220));

    if (model.activeSession()) |session| {
        var text_buffer: [16 * 1024]u8 = undefined;
        const text = session.runtime.?.writeViewportText(&text_buffer) catch "libghostty render state unavailable";
        drawText(dc, text, &terminal_rect, win.DT_LEFT | win.DT_TOP | win.DT_NOPREFIX);
    } else {
        drawText(dc, "Open a PowerShell or WSL session.", &terminal_rect, win.DT_LEFT | win.DT_TOP);
    }
}

fn drawButton(dc: win.HDC, rect: win.RECT, text: []const u8, color: win.COLORREF) void {
    fill(dc, rect, color);
    var text_rect = rect;
    _ = win.SetTextColor(dc, rgb(238, 241, 247));
    drawText(dc, text, &text_rect, win.DT_CENTER | win.DT_VCENTER | win.DT_SINGLELINE | win.DT_NOPREFIX);
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
