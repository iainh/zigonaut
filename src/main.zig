const std = @import("std");
const app_model = @import("app.zig");
const chrome = @import("chrome_bridge.zig");
const TerminalView = @import("terminal_view.zig").View;

const win = @import("win32.zig").c;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut");
const font_name = std.unicode.utf8ToUtf16LeStringLiteral("Cascadia Mono");
const button_class = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
const tab_class = std.unicode.utf8ToUtf16LeStringLiteral("SysTabControl32");
const powershell_label = std.unicode.utf8ToUtf16LeStringLiteral("PowerShell");
const wsl_label = std.unicode.utf8ToUtf16LeStringLiteral("WSL");
const close_label = std.unicode.utf8ToUtf16LeStringLiteral("Close tab");
const personalize_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
const apps_use_light_theme = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

const command_new_powershell = 1001;
const command_new_wsl = 1002;
const command_close_tab = 1200;
const chrome_message = win.WM_APP + 1;
const tab_selection_changed: win.UINT = @bitCast(@as(i32, -551));
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
    terminal_ready: bool = false,
    terminal_view: TerminalView,
    chrome: ?chrome.Bridge = null,
    fallback_powershell: win.HWND = null,
    fallback_wsl: win.HWND = null,
    fallback_close: win.HWND = null,
    fallback_tabs: win.HWND = null,
};

var state: ?State = null;

pub fn main() !void {
    const instance = win.GetModuleHandleW(null);
    const arrow_cursor: win.LPCWSTR = @ptrFromInt(32512);
    const cursor = win.LoadCursorW(null, arrow_cursor);
    var controls = win.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(win.INITCOMMONCONTROLSEX), .dwICC = win.ICC_TAB_CLASSES };
    if (win.InitCommonControlsEx(&controls) == 0) return error.InitializeCommonControlsFailed;
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
        win.WS_EX_CONTROLPARENT,
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
            } else if (win.IsDialogMessageW(current.hwnd, &message) != 0) {
                continue;
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
            state.?.terminal_ready = true;
            _ = state.?.model.addSession(.powershell) catch return -1;
            state.?.chrome = chrome.Bridge.load(hwnd, chromeCommand, null);
            if (state.?.chrome == null) createFallbackControls(hwnd, win.GetModuleHandleW(null)) catch return -1;
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
        win.WM_NOTIFY => {
            const header: *const win.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (state.?.fallback_tabs != null and header.hwndFrom == state.?.fallback_tabs and header.code == tab_selection_changed) {
                const selected = win.SendMessageW(state.?.fallback_tabs, win.TCM_GETCURSEL, 0, 0);
                if (selected >= 0) state.?.model.activate(@intCast(selected));
                state.?.terminal_view.invalidate();
            }
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
                setFallbackFont(current, new_font);
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
    layoutFallbackControls(client.right, dpi);
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
    } else syncFallbackTabs();
}

fn disableChrome(hwnd: win.HWND) void {
    if (state.?.chrome) |*bridge| bridge.deinit();
    state.?.chrome = null;
    createFallbackControls(hwnd, win.GetModuleHandleW(null)) catch {};
    layoutTerminalView(hwnd);
    _ = win.InvalidateRect(hwnd, null, 0);
}

fn createFallbackControls(parent: win.HWND, instance: win.HINSTANCE) !void {
    if (state.?.fallback_tabs != null) return;
    state.?.fallback_powershell = try createFallbackControl(parent, instance, button_class, powershell_label, win.BS_PUSHBUTTON | win.WS_GROUP, command_new_powershell);
    state.?.fallback_wsl = try createFallbackControl(parent, instance, button_class, wsl_label, win.BS_PUSHBUTTON, command_new_wsl);
    state.?.fallback_close = try createFallbackControl(parent, instance, button_class, close_label, win.BS_PUSHBUTTON, command_close_tab);
    state.?.fallback_tabs = win.CreateWindowExW(
        0,
        tab_class,
        null,
        win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.WS_CLIPSIBLINGS,
        0,
        0,
        1,
        1,
        parent,
        null,
        instance,
        null,
    ) orelse return error.CreateFallbackTabsFailed;
    setFallbackFont(&state.?, state.?.font);
    syncFallbackTabs();
}

fn createFallbackControl(parent: win.HWND, instance: win.HINSTANCE, class: win.LPCWSTR, label: win.LPCWSTR, style: win.DWORD, command: u16) !win.HWND {
    const control = win.CreateWindowExW(
        0,
        class,
        label,
        @as(win.DWORD, @bitCast(win.WS_CHILD)) | @as(win.DWORD, @bitCast(win.WS_VISIBLE)) | @as(win.DWORD, @bitCast(win.WS_TABSTOP)) | style,
        0,
        0,
        1,
        1,
        parent,
        null,
        instance,
        null,
    ) orelse return error.CreateFallbackControlFailed;
    _ = win.SetWindowLongPtrW(control, win.GWLP_ID, command);
    return control;
}

fn layoutFallbackControls(width: i32, dpi: u32) void {
    if (state.?.fallback_tabs == null) return;
    _ = win.MoveWindow(state.?.fallback_powershell, scaled(16, dpi), scaled(12, dpi), scaled(120, dpi), scaled(32, dpi), 1);
    _ = win.MoveWindow(state.?.fallback_wsl, scaled(144, dpi), scaled(12, dpi), scaled(76, dpi), scaled(32, dpi), 1);
    _ = win.MoveWindow(state.?.fallback_close, scaled(228, dpi), scaled(12, dpi), scaled(92, dpi), scaled(32, dpi), 1);
    _ = win.MoveWindow(state.?.fallback_tabs, scaled(16, dpi), scaled(52, dpi), @max(width - scaled(32, dpi), 1), scaled(48, dpi), 1);
}

fn setFallbackFont(current: *State, font: win.HFONT) void {
    const font_value: win.WPARAM = @intFromPtr(font);
    if (current.fallback_powershell != null) _ = win.SendMessageW(current.fallback_powershell, win.WM_SETFONT, font_value, 1);
    if (current.fallback_wsl != null) _ = win.SendMessageW(current.fallback_wsl, win.WM_SETFONT, font_value, 1);
    if (current.fallback_close != null) _ = win.SendMessageW(current.fallback_close, win.WM_SETFONT, font_value, 1);
    if (current.fallback_tabs != null) _ = win.SendMessageW(current.fallback_tabs, win.WM_SETFONT, font_value, 1);
}

fn syncFallbackTabs() void {
    const tabs = state.?.fallback_tabs;
    if (tabs == null) return;
    _ = win.SendMessageW(tabs, win.TCM_DELETEALLITEMS, 0, 0);
    for (state.?.model.sessions.items, 0..) |session, index| {
        var item = std.mem.zeroes(win.TCITEMW);
        item.mask = win.TCIF_TEXT;
        item.pszText = @constCast(if (session.shell == .powershell) powershell_label else wsl_label);
        _ = win.SendMessageW(tabs, win.TCM_INSERTITEMW, index, @intCast(@intFromPtr(&item)));
    }
    if (state.?.model.active) |active| _ = win.SendMessageW(tabs, win.TCM_SETCURSEL, active, 0);
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
    fill(dc, client, fallbackBackground());
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

fn fallbackBackground() win.COLORREF {
    if (state.?.high_contrast) return win.GetSysColor(win.COLOR_WINDOW);
    return if (state.?.dark_theme) rgb(15, 17, 21) else rgb(243, 243, 243);
}

fn updateTheme(hwnd: win.HWND) void {
    if (state == null) return;
    state.?.dark_theme = appsUseDarkTheme();
    state.?.high_contrast = highContrastEnabled();
    if (state.?.terminal_ready) state.?.terminal_view.updateTheme(state.?.dark_theme, state.?.high_contrast);
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
