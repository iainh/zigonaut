const std = @import("std");
const app_model = @import("app.zig");
const chrome = @import("chrome_bridge.zig");
const TerminalView = @import("terminal_view.zig").View;

const win = @import("win32.zig").c;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut");
const font_name = std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");
const personalize_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
const apps_use_light_theme = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

const command_new_powershell = 1001;
const command_new_wsl = 1002;
const command_close_tab = 1200;
const chrome_message = win.WM_APP + 1;
const terminal_left = 16;
const terminal_margin = 16;
const fallback_terminal_top: i32 = 108;
const winui_terminal_top: i32 = 52;

const State = struct {
    hwnd: win.HWND,
    model: app_model.App,
    font: win.HFONT,
    dpi: u32,
    dark_theme: bool,
    high_contrast: bool,
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

    updateTheme(hwnd);

    var message: win.MSG = undefined;
    while (win.GetMessageW(&message, null, 0, 0) > 0) {
        if (handleShortcut(&message)) continue;
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

fn handleShortcut(message: *const win.MSG) bool {
    if (message.message != win.WM_KEYDOWN and message.message != win.WM_SYSKEYDOWN) return false;
    if (win.GetKeyState(win.VK_CONTROL) >= 0 or win.GetKeyState(win.VK_MENU) < 0) return false;

    const shift = win.GetKeyState(win.VK_SHIFT) < 0;
    const repeated = (message.lParam & (@as(win.LPARAM, 1) << 30)) != 0;
    const hwnd = state.?.hwnd;
    if (shift and message.wParam == 'T') {
        if (!repeated) sendCommand(hwnd, command_new_powershell);
        return true;
    }
    if (shift and message.wParam == 'W') {
        if (!repeated) sendCommand(hwnd, command_close_tab);
        return true;
    }
    if (message.wParam != win.VK_TAB) return false;

    const count = state.?.model.sessions.items.len;
    const active = state.?.model.active orelse return true;
    if (count > 1) {
        const next = if (shift) (active + count - 1) % count else (active + 1) % count;
        sendChromeCommand(hwnd, chrome.command.select, @intCast(next));
    }
    return true;
}

fn windowProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.c) win.LRESULT {
    switch (message) {
        win.WM_CREATE => {
            const dpi = win.GetDpiForWindow(hwnd);
            const font = createFont(dpi);
            state = .{
                .hwnd = hwnd,
                .model = app_model.App.init(std.heap.page_allocator),
                .font = font,
                .dpi = dpi,
                .dark_theme = false,
                .high_contrast = false,
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
            }
            _ = win.InvalidateRect(hwnd, null, 0);
            state.?.terminal_view.invalidate();
            syncChrome();
            return 0;
        },
        chrome_message => {
            const command: u32 = @intCast(wparam);
            const argument: u32 = @intCast(lparam);
            switch (command) {
                chrome.command.new_powershell => _ = state.?.model.addSession(.powershell) catch return 0,
                chrome.command.new_wsl => _ = state.?.model.addSession(.wsl) catch return 0,
                chrome.command.close => state.?.model.closeSession(argument),
                chrome.command.select => state.?.model.activate(argument),
                else => return 0,
            }
            state.?.terminal_view.syncSessions();
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
        win.WM_DPICHANGED => {
            const suggested: *const win.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            _ = win.SetWindowPos(
                hwnd,
                null,
                suggested.left,
                suggested.top,
                suggested.right - suggested.left,
                suggested.bottom - suggested.top,
                win.SWP_NOACTIVATE | win.SWP_NOZORDER,
            );
            if (state) |*current| {
                const new_dpi: u32 = @truncate(wparam);
                const new_font = createFont(new_dpi);
                current.terminal_view.updateFont(new_font);
                _ = win.DeleteObject(current.font);
                current.font = new_font;
                current.dpi = new_dpi;
                layoutTerminalView(hwnd);
                _ = win.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        win.WM_SETTINGCHANGE, win.WM_THEMECHANGED => {
            updateTheme(hwnd);
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
    const dpi = state.?.dpi;
    if (y < scaled(52, dpi)) {
        if (x >= scaled(16, dpi) and x < scaled(136, dpi)) {
            sendCommand(hwnd, command_new_powershell);
        } else if (x >= scaled(144, dpi) and x < scaled(220, dpi)) {
            sendCommand(hwnd, command_new_wsl);
        } else if (x >= scaled(228, dpi) and x < scaled(266, dpi)) {
            sendCommand(hwnd, command_close_tab);
        }
        return;
    }
    if (y >= scaled(56, dpi) and y < scaled(96, dpi) and x >= scaled(16, dpi)) {
        const index: u32 = @intCast(@divTrunc(x - scaled(16, dpi), scaled(168, dpi)));
        sendChromeCommand(hwnd, chrome.command.select, index);
    }
}

fn layoutTerminalView(hwnd: win.HWND) void {
    if (state == null) return;
    var client: win.RECT = undefined;
    if (win.GetClientRect(hwnd, &client) == 0) return;
    const dpi = state.?.dpi;
    const terminal_top = scaled(if (state.?.chrome != null) winui_terminal_top else fallback_terminal_top, dpi);
    var chrome_failed = false;
    if (state.?.chrome) |*bridge| chrome_failed = !bridge.move(0, 0, client.right, terminal_top);
    if (chrome_failed) {
        disableChrome(hwnd);
        return;
    }
    state.?.terminal_view.move(
        scaled(terminal_left, dpi),
        terminal_top,
        client.right - scaled(terminal_left + terminal_margin, dpi),
        client.bottom - terminal_top - scaled(terminal_margin, dpi),
    );
}

fn syncChrome() void {
    if (state == null) return;
    if (state.?.chrome) |*bridge| {
        const count = state.?.model.sessions.items.len;
        const kinds = std.heap.page_allocator.alloc(u8, count) catch return;
        defer std.heap.page_allocator.free(kinds);
        for (state.?.model.sessions.items, 0..) |session, index| {
            kinds[index] = @intFromEnum(session.shell);
        }
        if (!bridge.update(kinds, state.?.model.active)) disableChrome(state.?.hwnd);
    }
}

fn disableChrome(hwnd: win.HWND) void {
    if (state.?.chrome) |*bridge| bridge.deinit();
    state.?.chrome = null;
    layoutTerminalView(hwnd);
    _ = win.InvalidateRect(hwnd, null, 0);
}

fn chromeCommand(_: ?*anyopaque, command: u32, argument: u32) callconv(.c) void {
    const hwnd = if (state) |current| current.hwnd else return;
    sendChromeCommand(hwnd, command, argument);
}

fn sendCommand(hwnd: win.HWND, command: u16) void {
    _ = win.SendMessageW(hwnd, win.WM_COMMAND, command, 0);
}

fn sendChromeCommand(hwnd: win.HWND, command: u32, argument: u32) void {
    _ = win.PostMessageW(hwnd, chrome_message, command, @intCast(argument));
}

fn paint(hwnd: win.HWND) void {
    var ps: win.PAINTSTRUCT = undefined;
    const dc = win.BeginPaint(hwnd, &ps);
    defer _ = win.EndPaint(hwnd, &ps);

    var client: win.RECT = undefined;
    _ = win.GetClientRect(hwnd, &client);
    const colors = palette();
    fill(dc, client, colors.background);

    if (state.?.chrome != null) return;

    _ = win.SelectObject(dc, state.?.font);
    _ = win.SetBkMode(dc, win.TRANSPARENT);
    const dpi = state.?.dpi;

    drawButton(dc, scaledRect(.{ .left = 16, .top = 12, .right = 136, .bottom = 44 }, dpi), "PowerShell", colors.button, colors.text);
    drawButton(dc, scaledRect(.{ .left = 144, .top = 12, .right = 220, .bottom = 44 }, dpi), "+ WSL", colors.button, colors.text);
    drawButton(dc, scaledRect(.{ .left = 228, .top = 12, .right = 266, .bottom = 44 }, dpi), "x", colors.close, colors.text);

    const model = &state.?.model;
    for (model.sessions.items, 0..) |session, index| {
        const left: i32 = 16 + @as(i32, @intCast(index)) * 168;
        const active = model.active != null and model.active.? == index;
        drawButton(
            dc,
            scaledRect(.{ .left = left, .top = 56, .right = left + 160, .bottom = 94 }, dpi),
            session.shell.title(),
            if (active) colors.active else colors.button,
            colors.text,
        );
    }
}

fn drawButton(dc: win.HDC, rect: win.RECT, text: []const u8, color: win.COLORREF, text_color: win.COLORREF) void {
    fill(dc, rect, color);
    var text_rect = rect;
    _ = win.SetTextColor(dc, text_color);
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

fn createFont(dpi: u32) win.HFONT {
    return win.CreateFontW(
        -scaled(18, dpi),
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
}

fn scaled(value: i32, dpi: u32) i32 {
    return win.MulDiv(value, @intCast(dpi), 96);
}

fn scaledRect(rect: win.RECT, dpi: u32) win.RECT {
    return .{
        .left = scaled(rect.left, dpi),
        .top = scaled(rect.top, dpi),
        .right = scaled(rect.right, dpi),
        .bottom = scaled(rect.bottom, dpi),
    };
}

const Palette = struct {
    background: win.COLORREF,
    text: win.COLORREF,
    button: win.COLORREF,
    active: win.COLORREF,
    close: win.COLORREF,
};

fn palette() Palette {
    if (state.?.high_contrast) return .{
        .background = win.GetSysColor(win.COLOR_WINDOW),
        .text = win.GetSysColor(win.COLOR_WINDOWTEXT),
        .button = win.GetSysColor(win.COLOR_BTNFACE),
        .active = win.GetSysColor(win.COLOR_HIGHLIGHT),
        .close = win.GetSysColor(win.COLOR_BTNFACE),
    };
    if (state.?.dark_theme) return .{
        .background = rgb(15, 17, 21),
        .text = rgb(238, 241, 247),
        .button = rgb(51, 58, 72),
        .active = rgb(70, 83, 111),
        .close = rgb(83, 43, 50),
    };
    return .{
        .background = rgb(243, 243, 243),
        .text = rgb(28, 28, 28),
        .button = rgb(225, 225, 225),
        .active = rgb(196, 213, 243),
        .close = rgb(244, 204, 204),
    };
}

fn updateTheme(hwnd: win.HWND) void {
    if (state == null) return;
    state.?.dark_theme = appsUseDarkTheme();
    state.?.high_contrast = highContrastEnabled();
    var dark_mode: win.BOOL = @intFromBool(state.?.dark_theme and !state.?.high_contrast);
    _ = win.DwmSetWindowAttribute(hwnd, 20, &dark_mode, @sizeOf(win.BOOL));
    _ = win.InvalidateRect(hwnd, null, 0);
}

fn appsUseDarkTheme() bool {
    var current_user: win.HKEY = null;
    if (win.RegOpenCurrentUser(win.KEY_QUERY_VALUE, &current_user) != win.ERROR_SUCCESS) return false;
    defer _ = win.RegCloseKey(current_user);

    var light_theme: win.DWORD = 1;
    var size: win.DWORD = @sizeOf(win.DWORD);
    const result = win.RegGetValueW(
        current_user,
        personalize_key,
        apps_use_light_theme,
        win.RRF_RT_REG_DWORD,
        null,
        &light_theme,
        &size,
    );
    return result == win.ERROR_SUCCESS and light_theme == 0;
}

fn highContrastEnabled() bool {
    var contrast = win.HIGHCONTRASTW{
        .cbSize = @sizeOf(win.HIGHCONTRASTW),
        .dwFlags = 0,
        .lpszDefaultScheme = null,
    };
    return win.SystemParametersInfoW(win.SPI_GETHIGHCONTRAST, contrast.cbSize, &contrast, 0) != 0 and
        (contrast.dwFlags & win.HCF_HIGHCONTRASTON) != 0;
}
