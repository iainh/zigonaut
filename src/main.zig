const std = @import("std");
const app_model = @import("app.zig");
const chrome = @import("chrome_bridge.zig");
const config = @import("config.zig");
const TerminalView = @import("terminal_view.zig").View;

const win32 = @import("win32.zig");
const win = win32.c;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut");
const personalize_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
const apps_use_light_theme = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

const chrome_message = win.WM_APP + 1;
const titles_changed_message = win.WM_APP + 2;
const shell_exited_message = win.WM_APP + 3;
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
    if (!control or alt) return false;

    if (shift and message.wParam == 'T') {
        if (!repeated) addDefaultSession() catch {};
        return true;
    }
    if (shift and message.wParam == 'W') {
        if (!repeated) {
            if (state.?.model.active) |active| sendChromeCommand(hwnd, chrome.command.close, @intCast(active));
        }
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
                .model = app_model.App.init(
                    std.heap.page_allocator,
                    settings.theme.value(),
                    settings.randomize_tab_background,
                ),
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
                titles_changed_message,
                shell_exited_message,
            );
            state.?.terminal_view.create(hwnd, win.GetModuleHandleW(null)) catch return -1;
            state.?.terminal_ready = true;
            state.?.chrome = chrome.Bridge.load(hwnd, chromeCommand, null) orelse return -1;
            layoutTerminalView(hwnd);
            addDefaultSession() catch return -1;
            return 0;
        },
        chrome_message => {
            const command: u32 = @intCast(wparam);
            const argument: u32 = @intCast(lparam);
            switch (command) {
                chrome.command.new_powershell => _ = state.?.model.addSession(.powershell, state.?.terminal_view.columns, state.?.terminal_view.rows) catch return 0,
                chrome.command.new_wsl => _ = state.?.model.addSession(.wsl, state.?.terminal_view.columns, state.?.terminal_view.rows) catch return 0,
                chrome.command.close => {
                    state.?.model.closeSession(argument);
                    if (state.?.model.sessions.items.len == 0) {
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    }
                },
                chrome.command.select => state.?.model.activate(argument),
                else => return 0,
            }
            state.?.terminal_view.syncSessions();
            _ = win.InvalidateRect(hwnd, null, 0);
            state.?.terminal_view.invalidate();
            syncChrome();
            return 0;
        },
        titles_changed_message => {
            if (state.?.model.syncTitles()) syncChrome();
            return 0;
        },
        shell_exited_message => {
            if (!state.?.model.closeCleanlyExitedSessions()) return 0;
            if (state.?.model.sessions.items.len == 0) {
                _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                return 0;
            }
            state.?.terminal_view.syncSessions();
            state.?.terminal_view.invalidate();
            syncChrome();
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
    const terminal_top = scaled(winui_terminal_top, dpi);
    const bridge = if (state.?.chrome) |*value| value else return;
    if (!bridge.move(0, 0, client.right, terminal_top)) {
        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
        return;
    }
    state.?.terminal_view.move(
        0,
        terminal_top,
        client.right,
        client.bottom - terminal_top,
    );
}

fn syncChrome() void {
    if (state == null) return;
    const bridge = if (state.?.chrome) |*value| value else return;
    const count = state.?.model.sessions.items.len;
    const titles = std.heap.page_allocator.alloc([*]const u8, count) catch return;
    defer std.heap.page_allocator.free(titles);
    const title_lengths = std.heap.page_allocator.alloc(u32, count) catch return;
    defer std.heap.page_allocator.free(title_lengths);
    for (state.?.model.sessions.items, 0..) |session, index| {
        const title = session.displayTitle();
        titles[index] = title.ptr;
        title_lengths[index] = @intCast(title.len);
    }
    if (!bridge.update(titles, title_lengths, state.?.model.active)) {
        _ = win.PostMessageW(state.?.hwnd, win.WM_CLOSE, 0, 0);
    }
}

fn chromeCommand(_: ?*anyopaque, command: u32, argument: u32) callconv(.c) void {
    const hwnd = if (state) |current| current.hwnd else return;
    sendChromeCommand(hwnd, command, argument);
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
