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

const State = struct {
    model: app_model.App,
    font: win.HFONT,
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
            state = .{ .model = app_model.App.init(std.heap.page_allocator), .font = font };
            _ = state.?.model.addSession(.powershell) catch return -1;
            return 0;
        },
        win.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (command == command_new_powershell) {
                _ = state.?.model.addSession(.powershell) catch return 0;
            } else if (command == command_new_wsl) {
                _ = state.?.model.addSession(.wsl) catch return 0;
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
        win.WM_ERASEBKGND => return 1,
        win.WM_PAINT => {
            paint(hwnd);
            return 0;
        },
        win.WM_DESTROY => {
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

    var terminal_rect = win.RECT{ .left = 16, .top = 108, .right = client.right - 16, .bottom = client.bottom - 16 };
    fill(dc, terminal_rect, rgb(9, 10, 13));
    terminal_rect.left += 24;
    terminal_rect.top += 24;
    _ = win.SetTextColor(dc, rgb(198, 206, 220));

    if (model.activeSession()) |session| {
        var text_buffer: [16 * 1024]u8 = undefined;
        const text = session.terminal.writeViewportText(&text_buffer) catch "libghostty render state unavailable";
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
    var wide: [512]u16 = undefined;
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
