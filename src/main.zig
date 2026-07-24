const std = @import("std");
const app_model = @import("app.zig");
const chrome = @import("chrome_bridge.zig");
const config = @import("config.zig");
const TerminalView = @import("terminal_view.zig").View;

const win32 = @import("win32.zig");
const win = win32.c;
const log = std.log.scoped(.app);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut");
const open_operation = std.unicode.utf8ToUtf16LeStringLiteral("open");
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
    chrome_titles: std.ArrayList([*]const u8) = .empty,
    chrome_title_lengths: std.ArrayList(u32) = .empty,
};

// The application currently owns exactly one window and one STA UI thread.
// Window procedures and WinUI callbacks access these values only on that thread.
var state: ?State = null;
var settings = config.Config{};
var loaded_settings: ?config.Loaded = null;

pub fn main() !void {
    loaded_settings = try config.loadOrCreate(std.heap.page_allocator);
    defer {
        if (loaded_settings) |*loaded| loaded.deinit();
        loaded_settings = null;
    }
    settings = loaded_settings.?.value;

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
        if (!repeated) addDefaultSession() catch |err| log.err("unable to open default session: {}", .{err});
        return true;
    }
    if (shift and message.wParam == 'W') {
        if (!repeated) {
            if (state.?.model.active) |active| sendChromeCommand(hwnd, .close, @intCast(active));
        }
        return true;
    }
    if (message.wParam != win.VK_TAB) return false;

    const count = state.?.model.sessions.items.len;
    const active = state.?.model.active orelse return true;
    if (count > 1) {
        const next = if (shift) (active + count - 1) % count else (active + 1) % count;
        sendChromeCommand(hwnd, .select, @intCast(next));
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
            state.?.terminal_view.create(hwnd, win.GetModuleHandleW(null)) catch |err| {
                log.err("unable to create terminal view: {}", .{err});
                return -1;
            };
            state.?.terminal_ready = true;
            state.?.chrome = chrome.Bridge.load(hwnd, chromeCommand, null) orelse return -1;
            layoutTerminalView(hwnd);
            addDefaultSession() catch |err| {
                log.err("unable to create initial session: {}", .{err});
                return -1;
            };
            return 0;
        },
        chrome_message => {
            const command = chrome.commandFromInt(@intCast(wparam)) orelse return 0;
            const argument: u32 = @intCast(lparam);
            switch (command) {
                .new_powershell => _ = state.?.model.addSession(.powershell, state.?.terminal_view.columns, state.?.terminal_view.rows) catch |err| {
                    log.err("unable to open PowerShell session: {}", .{err});
                    return 0;
                },
                .new_wsl => _ = state.?.model.addSession(.wsl, state.?.terminal_view.columns, state.?.terminal_view.rows) catch |err| {
                    log.err("unable to open WSL session: {}", .{err});
                    return 0;
                },
                .close => {
                    state.?.model.closeSession(argument);
                    if (state.?.model.sessions.items.len == 0) {
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    }
                },
                .select => state.?.model.activate(argument),
                .open_settings => {
                    openSettings(hwnd) catch |err| log.err("unable to open settings: {}", .{err});
                    return 0;
                },
                .reload_settings => {
                    reloadSettings() catch |err| log.err("unable to reload settings: {}", .{err});
                    return 0;
                },
                .quit => {
                    _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                    return 0;
                },
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
                current.chrome_titles.deinit(std.heap.page_allocator);
                current.chrome_title_lengths.deinit(std.heap.page_allocator);
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
    state.?.chrome_titles.ensureTotalCapacity(std.heap.page_allocator, count) catch |err| {
        log.err("unable to allocate chrome title pointers: {}", .{err});
        return;
    };
    state.?.chrome_title_lengths.ensureTotalCapacity(std.heap.page_allocator, count) catch |err| {
        log.err("unable to allocate chrome title lengths: {}", .{err});
        return;
    };
    state.?.chrome_titles.items.len = count;
    state.?.chrome_title_lengths.items.len = count;
    for (state.?.model.sessions.items, 0..) |session, index| {
        const title = session.displayTitle();
        state.?.chrome_titles.items[index] = title.ptr;
        state.?.chrome_title_lengths.items[index] = @intCast(title.len);
    }
    if (!bridge.update(state.?.chrome_titles.items, state.?.chrome_title_lengths.items, state.?.model.active)) {
        _ = win.PostMessageW(state.?.hwnd, win.WM_CLOSE, 0, 0);
    }
}

fn chromeCommand(_: ?*anyopaque, command: u32, argument: u32) callconv(.c) void {
    const hwnd = if (state) |current| current.hwnd else return;
    const typed = chrome.commandFromInt(command) orelse return;
    sendChromeCommand(hwnd, typed, argument);
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

fn sendChromeCommand(hwnd: win.HWND, command: chrome.Command, argument: u32) void {
    _ = win.PostMessageW(hwnd, chrome_message, @intFromEnum(command), @intCast(argument));
}

fn createFont(dpi: u32) win.HFONT {
    return createFontFor(settings, dpi);
}

fn createFontFor(value: config.Config, dpi: u32) win.HFONT {
    var wide_name = std.mem.zeroes([128]u16);
    _ = std.unicode.utf8ToUtf16Le(wide_name[0 .. wide_name.len - 1], value.font_family) catch 0;
    return win.CreateFontW(
        -scaled(value.font_size, dpi),
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

fn openSettings(hwnd: win.HWND) !void {
    const path = try config.pathAlloc(std.heap.page_allocator);
    defer std.heap.page_allocator.free(path);
    const wide_path = try std.unicode.utf8ToUtf16LeAllocZ(std.heap.page_allocator, path);
    defer std.heap.page_allocator.free(wide_path);
    const result = win.ShellExecuteW(hwnd, open_operation, wide_path.ptr, null, null, win.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) return error.OpenSettingsFailed;
}

fn reloadSettings() !void {
    if (state == null) return;
    var replacement = try config.loadOrCreate(std.heap.page_allocator);
    errdefer replacement.deinit();

    const next = replacement.value;
    const changed = config.changes(settings, next);
    const new_font = if (changed.font) createFontFor(next, state.?.dpi) else null;
    if (changed.font and new_font == null) return error.CreateFontFailed;
    errdefer {
        if (new_font != null) _ = win.DeleteObject(new_font);
    }
    if (new_font != null) {
        try state.?.terminal_view.reloadFont(new_font, next.font_family, next.font_size, state.?.dpi);
    }

    const old_font = state.?.font;
    if (new_font != null) state.?.font = new_font;
    var previous = loaded_settings;
    loaded_settings = replacement;
    settings = loaded_settings.?.value;
    if (previous) |*loaded| loaded.deinit();

    if (changed.theme) {
        state.?.model.applySettings(settings.theme.value(), settings.randomize_tab_background);
    }
    if (new_font != null) {
        _ = win.DeleteObject(old_font);
        layoutTerminalView(state.?.hwnd);
    }
    state.?.terminal_view.invalidate();
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
