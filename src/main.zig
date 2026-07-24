const std = @import("std");
const app_model = @import("app.zig");
const chrome = @import("chrome_bridge.zig");
const config = @import("config.zig");
const TerminalView = @import("terminal_view.zig").View;

const win32 = @import("win32.zig");
const win = win32.c;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut");
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
const fallback_terminal_top: i32 = 108;
const winui_terminal_top: i32 = 48;

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
var settings = config.Config{};

pub fn main() !void {
    var loaded_config = try config.loadOrCreate(std.heap.page_allocator);
    defer loaded_config.deinit();
    settings = loaded_config.value;

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
        if (current.chrome) |*bridge| _ = bridge.deinit();
    }
    state = null;
}

fn handleShortcut(message: *const win.MSG) bool {
    if (message.message != win.WM_KEYDOWN and message.message != win.WM_SYSKEYDOWN) return false;
    const control = win.GetKeyState(win.VK_CONTROL) < 0;
    const alt = win.GetKeyState(win.VK_MENU) < 0;
    const shift = win.GetKeyState(win.VK_SHIFT) < 0;
    const repeated = (message.lParam & (@as(win.LPARAM, 1) << 30)) != 0;
    const hwnd = state.?.hwnd;
    if (!control and !alt and message.wParam == win.VK_F6 and state.?.fallback_tabs != null) {
        if (!repeated) {
            const terminal = state.?.terminal_view.hwnd;
            const target = if (win.GetFocus() == terminal)
                (if (shift) state.?.fallback_tabs else state.?.fallback_powershell)
            else
                terminal;
            _ = win.SetFocus(target);
        }
        return true;
    }
    if (!control or alt) return false;

    if (shift and message.wParam == 'T') {
        if (!repeated) addDefaultSession() catch {};
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
                .model = app_model.App.init(std.heap.page_allocator, settings.theme.value()),
                .font = font,
                .dpi = dpi,
                .dark_theme = false,
                .high_contrast = false,
                .terminal_view = undefined,
            };
            state.?.terminal_view = TerminalView.init(
                hwnd,
                &state.?.model,
                font,
                settings.font_family,
                settings.font_size,
                dpi,
            );
            state.?.terminal_view.create(hwnd, win.GetModuleHandleW(null)) catch return -1;
            state.?.terminal_ready = true;
            state.?.chrome = chrome.Bridge.load(hwnd, chromeCommand, null);
            if (state.?.chrome == null) createFallbackControls(hwnd, win.GetModuleHandleW(null)) catch return -1;
            layoutTerminalView(hwnd);
            addDefaultSession() catch return -1;
            return 0;
        },
        win.WM_COMMAND => {
            const command: u16 = @truncate(wparam);
            if (command == command_new_powershell) {
                _ = state.?.model.addSession(.powershell, state.?.terminal_view.columns, state.?.terminal_view.rows) catch return 0;
                state.?.terminal_view.syncSessions();
            } else if (command == command_new_wsl) {
                _ = state.?.model.addSession(.wsl, state.?.terminal_view.columns, state.?.terminal_view.rows) catch return 0;
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
                chrome.command.new_powershell => _ = state.?.model.addSession(.powershell, state.?.terminal_view.columns, state.?.terminal_view.rows) catch return 0,
                chrome.command.new_wsl => _ = state.?.model.addSession(.wsl, state.?.terminal_view.columns, state.?.terminal_view.rows) catch return 0,
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
            if (state.?.fallback_tabs != null and header.hwndFrom == state.?.fallback_tabs) {
                if (header.code == tab_selection_changed) {
                    const selected = win.SendMessageW(state.?.fallback_tabs, win.TCM_GETCURSEL, 0, 0);
                    if (selected >= 0) state.?.model.activate(@intCast(selected));
                    state.?.terminal_view.invalidate();
                }
            }
            return 0;
        },
        win.WM_DRAWITEM => {
            const draw: *const win.DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (draw.hwndItem == state.?.fallback_tabs) {
                paintFallbackTab(draw);
                return 1;
            } else if (draw.hwndItem == state.?.fallback_powershell or draw.hwndItem == state.?.fallback_wsl or draw.hwndItem == state.?.fallback_close) {
                paintFallbackButton(draw);
                return 1;
            }
            return 0;
        },
        win.WM_MEASUREITEM => {
            const measure: *win.MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (measure.CtlType == win.ODT_TAB) {
                measure.itemWidth = @intCast(scaled(120, state.?.dpi));
                measure.itemHeight = @intCast(scaled(32, state.?.dpi));
                return 1;
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
                const new_dpi: u32 = @intCast(wparam & 0xffff);
                const new_font = createFont(new_dpi);
                current.terminal_view.updateFont(new_font, new_dpi);
                _ = win.DeleteObject(current.font);
                current.font = new_font;
                current.dpi = new_dpi;
                setFallbackFont(current, new_font);
                layoutTerminalView(hwnd);
                _ = win.InvalidateRect(hwnd, null, 0);
            }
            return 0;
        },
        win.WM_SETTINGCHANGE, win.WM_THEMECHANGED, win.WM_SYSCOLORCHANGE => {
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
        0,
        terminal_top,
        client.right,
        client.bottom - terminal_top,
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
    if (state.?.chrome) |*bridge| {
        if (!bridge.deinit()) return;
    }
    state.?.chrome = null;
    createFallbackControls(hwnd, win.GetModuleHandleW(null)) catch {};
    layoutTerminalView(hwnd);
    _ = win.InvalidateRect(hwnd, null, 0);
}

fn createFallbackControls(parent: win.HWND, instance: win.HINSTANCE) !void {
    if (state.?.fallback_tabs != null) return;
    state.?.fallback_powershell = try createFallbackControl(parent, instance, button_class, powershell_label, win.BS_OWNERDRAW | win.WS_GROUP, command_new_powershell);
    state.?.fallback_wsl = try createFallbackControl(parent, instance, button_class, wsl_label, win.BS_OWNERDRAW, command_new_wsl);
    state.?.fallback_close = try createFallbackControl(parent, instance, button_class, close_label, win.BS_OWNERDRAW, command_close_tab);
    state.?.fallback_tabs = win.CreateWindowExW(
        0,
        tab_class,
        null,
        win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.WS_CLIPSIBLINGS | win.TCS_BUTTONS | win.TCS_FLATBUTTONS | win.TCS_HOTTRACK | win.TCS_OWNERDRAWFIXED,
        0,
        0,
        1,
        1,
        parent,
        null,
        instance,
        null,
    ) orelse return error.CreateFallbackTabsFailed;
    if (win.SetWindowSubclass(state.?.fallback_tabs, fallbackTabProc, 1, 0) == 0) return error.SubclassFallbackTabsFailed;
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
    _ = win.MoveWindow(state.?.fallback_close, scaled(228, dpi), scaled(12, dpi), scaled(108, dpi), scaled(32, dpi), 1);
    _ = win.MoveWindow(state.?.fallback_tabs, scaled(16, dpi), scaled(52, dpi), @max(width - scaled(32, dpi), 1), scaled(48, dpi), 1);
}

fn setFallbackFont(current: *State, font: win.HFONT) void {
    const font_value: win.WPARAM = @intFromPtr(font);
    if (current.fallback_powershell != null) _ = win.SendMessageW(current.fallback_powershell, win.WM_SETFONT, font_value, 1);
    if (current.fallback_wsl != null) _ = win.SendMessageW(current.fallback_wsl, win.WM_SETFONT, font_value, 1);
    if (current.fallback_close != null) _ = win.SendMessageW(current.fallback_close, win.WM_SETFONT, font_value, 1);
    if (current.fallback_tabs != null) {
        _ = win.SendMessageW(current.fallback_tabs, win.WM_SETFONT, font_value, 1);
        const width: u32 = @intCast(scaled(120, current.dpi));
        const height: u32 = @intCast(scaled(32, current.dpi));
        _ = win.SendMessageW(current.fallback_tabs, win.TCM_SETITEMSIZE, 0, @intCast(width | (height << 16)));
    }
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

fn addDefaultSession() !void {
    if (state == null) return;
    const shell: app_model.Shell = switch (settings.default_shell) {
        .powershell => .powershell,
        .wsl => .wsl,
    };
    _ = try state.?.model.addSession(shell, state.?.terminal_view.columns, state.?.terminal_view.rows);
    state.?.terminal_view.syncSessions();
    state.?.terminal_view.invalidate();
    syncChrome();
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

fn frame(dc: win.HDC, rect: win.RECT, color: win.COLORREF) void {
    const brush = win.CreateSolidBrush(color);
    defer _ = win.DeleteObject(brush);
    var mutable_rect = rect;
    _ = win.FrameRect(dc, &mutable_rect, brush);
}

fn paintFallbackButton(draw: *const win.DRAWITEMSTRUCT) void {
    const saved_dc = win.SaveDC(draw.hDC);
    defer {
        if (saved_dc != 0) _ = win.RestoreDC(draw.hDC, saved_dc);
    }
    const pressed = (draw.itemState & win.ODS_SELECTED) != 0;
    const hot = (draw.itemState & win.ODS_HOTLIGHT) != 0;
    const disabled = (draw.itemState & win.ODS_DISABLED) != 0;
    const background = if (state.?.high_contrast)
        (if (pressed) win.GetSysColor(win.COLOR_HIGHLIGHT) else win.GetSysColor(win.COLOR_BTNFACE))
    else if (state.?.dark_theme)
        (if (pressed) rgb(71, 76, 87) else if (hot) rgb(55, 60, 70) else rgb(39, 43, 51))
    else
        (if (pressed) rgb(210, 210, 210) else if (hot) rgb(229, 229, 229) else rgb(255, 255, 255));
    const foreground = if (disabled)
        win.GetSysColor(win.COLOR_GRAYTEXT)
    else if (state.?.high_contrast and pressed)
        win.GetSysColor(win.COLOR_HIGHLIGHTTEXT)
    else if (state.?.high_contrast)
        win.GetSysColor(win.COLOR_BTNTEXT)
    else if (state.?.dark_theme)
        rgb(245, 245, 245)
    else
        rgb(32, 32, 32);
    const border = if (state.?.high_contrast) foreground else if (state.?.dark_theme) rgb(92, 98, 112) else rgb(173, 173, 173);

    fill(draw.hDC, draw.rcItem, background);
    frame(draw.hDC, draw.rcItem, border);
    _ = win.SelectObject(draw.hDC, state.?.font);
    _ = win.SetBkMode(draw.hDC, win.TRANSPARENT);
    _ = win.SetTextColor(draw.hDC, foreground);
    var text: [64]u16 = std.mem.zeroes([64]u16);
    _ = win.GetWindowTextW(draw.hwndItem, &text, text.len);
    var text_rect = draw.rcItem;
    if (pressed) _ = win.OffsetRect(&text_rect, 1, 1);
    _ = win.DrawTextW(draw.hDC, &text, -1, &text_rect, win.DT_CENTER | win.DT_VCENTER | win.DT_SINGLELINE);
    if ((draw.itemState & win.ODS_FOCUS) != 0 and (draw.itemState & win.ODS_NOFOCUSRECT) == 0) {
        var focus_rect = draw.rcItem;
        _ = win.InflateRect(&focus_rect, -3, -3);
        _ = win.DrawFocusRect(draw.hDC, &focus_rect);
    }
}

fn paintFallbackTab(draw: *const win.DRAWITEMSTRUCT) void {
    if (draw.itemID >= state.?.model.sessions.items.len) return;
    const saved_dc = win.SaveDC(draw.hDC);
    defer {
        if (saved_dc != 0) _ = win.RestoreDC(draw.hDC, saved_dc);
    }
    const selected = (draw.itemState & win.ODS_SELECTED) != 0;
    const hot = (draw.itemState & win.ODS_HOTLIGHT) != 0;
    const background = if (state.?.high_contrast)
        (if (selected) win.GetSysColor(win.COLOR_HIGHLIGHT) else win.GetSysColor(win.COLOR_BTNFACE))
    else if (state.?.dark_theme)
        (if (selected) rgb(55, 60, 70) else if (hot) rgb(45, 49, 58) else rgb(31, 34, 41))
    else
        (if (selected) rgb(255, 255, 255) else if (hot) rgb(220, 220, 220) else rgb(232, 232, 232));
    const foreground = if (state.?.high_contrast)
        (if (selected) win.GetSysColor(win.COLOR_HIGHLIGHTTEXT) else win.GetSysColor(win.COLOR_BTNTEXT))
    else if (state.?.dark_theme)
        rgb(245, 245, 245)
    else
        rgb(32, 32, 32);
    const border = if (state.?.high_contrast) foreground else if (state.?.dark_theme) rgb(92, 98, 112) else rgb(173, 173, 173);
    fill(draw.hDC, draw.rcItem, background);
    frame(draw.hDC, draw.rcItem, border);
    _ = win.SelectObject(draw.hDC, state.?.font);
    _ = win.SetBkMode(draw.hDC, win.TRANSPARENT);
    _ = win.SetTextColor(draw.hDC, foreground);
    var text_rect = draw.rcItem;
    const session = state.?.model.sessions.items[draw.itemID];
    const label = if (session.shell == .powershell) powershell_label else wsl_label;
    _ = win.DrawTextW(draw.hDC, label, -1, &text_rect, win.DT_CENTER | win.DT_VCENTER | win.DT_SINGLELINE);
    if ((draw.itemState & win.ODS_FOCUS) != 0 and (draw.itemState & win.ODS_NOFOCUSRECT) == 0) {
        var focus_rect = draw.rcItem;
        _ = win.InflateRect(&focus_rect, -3, -3);
        _ = win.DrawFocusRect(draw.hDC, &focus_rect);
    }
}

fn fallbackTabProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, _: win.DWORD_PTR) callconv(.c) win.LRESULT {
    if (message == win.WM_ERASEBKGND and state != null) {
        const dc = win32.handleFromInt(win.HDC, wparam);
        var client: win.RECT = undefined;
        if (win.GetClientRect(hwnd, &client) != 0) fill(dc, client, fallbackBackground());
        return 1;
    }
    if (message == win.WM_NCDESTROY) _ = win.RemoveWindowSubclass(hwnd, fallbackTabProc, 1);
    return win.DefSubclassProc(hwnd, message, wparam, lparam);
}

fn rgb(red: u8, green: u8, blue: u8) win.COLORREF {
    return @as(win.COLORREF, red) | (@as(win.COLORREF, green) << 8) | (@as(win.COLORREF, blue) << 16);
}

fn createFont(dpi: u32) win.HFONT {
    var wide_name = std.mem.zeroes([128]u16);
    _ = std.unicode.utf8ToUtf16Le(wide_name[0 .. wide_name.len - 1], settings.font_family) catch 0;
    return win.CreateFontW(
        -scaled(settings.font_size, dpi),
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
        &wide_name,
    );
}

fn scaled(value: anytype, dpi: u32) i32 {
    return win.MulDiv(@intCast(value), @intCast(dpi), 96);
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
    if (state.?.fallback_powershell != null) _ = win.InvalidateRect(state.?.fallback_powershell, null, 0);
    if (state.?.fallback_wsl != null) _ = win.InvalidateRect(state.?.fallback_wsl, null, 0);
    if (state.?.fallback_close != null) _ = win.InvalidateRect(state.?.fallback_close, null, 0);
    if (state.?.fallback_tabs != null) _ = win.InvalidateRect(state.?.fallback_tabs, null, 1);
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
