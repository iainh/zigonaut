const std = @import("std");
const app_model = @import("app.zig");
const chrome = @import("chrome_bridge.zig");
const TerminalView = @import("terminal_view.zig").View;

const win = @import("win32.zig").c;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut");
const font_name = std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");

const command_new_powershell = 1001;
const command_new_wsl = 1002;
const command_tab_base = 1100;
const command_close_tab = 1200;
const terminal_left = 16;
const terminal_top = 108;
const terminal_margin = 16;

const State = struct {
    hwnd: win.HWND,
    model: app_model.App,
    font: win.HFONT,
    terminal_view: TerminalView,
    chrome: ?chrome.Bridge = null,
};

var state: ?State = null;

pub fn main() !void {
    const instance = win.GetModuleHandleW(null);
    const arrow_cursor: win.LPCWSTR = @ptrFromInt(32512);
    const cursor = win.LoadCursorW(null, arrow_cursor);
    try TerminalView.registerClass(instance, cursor);
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
        if (state) |*current| {
            if (current.chrome) |*bridge| {
                if (bridge.pretranslate(&message)) continue;
            }
        }
        _ = win.TranslateMessage(&message);
        _ = win.DispatchMessageW(&message);
    }
    if (state) |*current| {
        if (current.chrome) |*bridge| bridge.deinit();
    }
    state = null;
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
            state = .{
                .hwnd = hwnd,
                .model = app_model.App.init(std.heap.page_allocator),
                .font = font,
                .terminal_view = undefined,
            };
            state.?.terminal_view = TerminalView.init(hwnd, &state.?.model, font);
            state.?.terminal_view.create(hwnd, win.GetModuleHandleW(null)) catch return -1;
            _ = state.?.model.addSession(.powershell) catch return -1;
            state.?.chrome = chrome.Bridge.load(hwnd, chromeCommand, null);
            layoutTerminalView(hwnd);
            state.?.terminal_view.syncSessions();
            syncChrome();
            return 0;
        },
        win.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (command == command_new_powershell) {
                _ = state.?.model.addSession(.powershell) catch return 0;
                state.?.terminal_view.syncSessions();
            } else if (command == command_new_wsl) {
                _ = state.?.model.addSession(.wsl) catch return 0;
                state.?.terminal_view.syncSessions();
            } else if (command == command_close_tab) {
                if (state.?.model.active) |active| state.?.model.closeSession(active);
            } else if (command >= command_tab_base and command < command_tab_base + 32) {
                state.?.model.activate(command - command_tab_base);
            }
            _ = win.InvalidateRect(hwnd, null, 0);
            state.?.terminal_view.invalidate();
            syncChrome();
            return 0;
        },
        win.WM_LBUTTONUP => {
            if (state.?.chrome == null) handleClick(hwnd, pointX(lparam), pointY(lparam));
            return 0;
        },
        win.WM_SIZE => {
            layoutTerminalView(hwnd);
            return 0;
        },
        win.WM_CLOSE => {
            if (state.?.chrome) |*bridge| bridge.close();
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
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

fn layoutTerminalView(hwnd: win.HWND) void {
    if (state == null) return;
    var client: win.RECT = undefined;
    if (win.GetClientRect(hwnd, &client) == 0) return;
    if (state.?.chrome) |*bridge| bridge.move(0, 0, client.right, terminal_top - 8);
    state.?.terminal_view.move(
        terminal_left,
        terminal_top,
        client.right - terminal_left - terminal_margin,
        client.bottom - terminal_top - terminal_margin,
    );
}

fn syncChrome() void {
    if (state == null) return;
    if (state.?.chrome) |*bridge| {
        var kinds: [32]u8 = undefined;
        const count = @min(state.?.model.sessions.items.len, kinds.len);
        for (state.?.model.sessions.items[0..count], 0..) |session, index| {
            kinds[index] = @intFromEnum(session.shell);
        }
        bridge.update(kinds[0..count], state.?.model.active);
    }
}

fn chromeCommand(_: ?*anyopaque, command: u32, argument: u32) callconv(.c) void {
    const hwnd = state.?.hwnd;
    const win32_command: u16 = switch (command) {
        chrome.command.new_powershell => command_new_powershell,
        chrome.command.new_wsl => command_new_wsl,
        chrome.command.close => command_close_tab,
        chrome.command.select => command_tab_base + @as(u16, @intCast(argument)),
        else => return,
    };
    sendCommand(hwnd, win32_command);
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

    if (state.?.chrome != null) return;

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
