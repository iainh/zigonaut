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
const scrollbar_changed_message = win.WM_APP + 4;
const progress_changed_message = win.WM_APP + 5;
const notification_changed_message = win.WM_APP + 6;
const winui_terminal_top: i32 = 48;
const taskbar_progress_timer = 1;
const taskbar_progress_timeout_ms = 15_000;

const Application = struct {
    loaded: config.Loaded,
    settings: config.Config,
    hwnd: ?win.HWND = null,
    model: app_model.App,
    font: win.HFONT = null,
    dpi: u32 = 96,
    dark_theme: bool = false,
    high_contrast: bool = false,
    taskbar_button_created_message: win.UINT = 0,
    taskbar_ready: bool = false,
    terminal_ready: bool = false,
    terminal_view: TerminalView = undefined,
    chrome: ?chrome.Bridge = null,
    chrome_titles: std.ArrayList([*]const u8) = .empty,
    chrome_title_lengths: std.ArrayList(u32) = .empty,

    fn init(loaded: config.Loaded) Application {
        return .{
            .settings = loaded.value,
            .loaded = loaded,
            .model = app_model.App.init(std.heap.page_allocator, loaded.value.theme.value(), loaded.value.randomize_tab_background),
        };
    }

    fn deinit(self: *Application) void {
        if (self.chrome) |*bridge| _ = bridge.deinit();
        self.model.deinit();
        self.chrome_titles.deinit(std.heap.page_allocator);
        self.chrome_title_lengths.deinit(std.heap.page_allocator);
        if (self.font != null) _ = win.DeleteObject(self.font);
        self.loaded.deinit();
    }

    const handleShortcut = handleShortcutImpl;
    const windowMessage = windowMessageImpl;
    const layoutTerminalView = layoutTerminalViewImpl;
    const syncChrome = syncChromeImpl;
    const syncScrollbar = syncScrollbarImpl;
    const syncTaskbarProgress = syncTaskbarProgressImpl;
    const showPendingNotifications = showPendingNotificationsImpl;
    const addDefaultSession = addDefaultSessionImpl;
    const addProfile = addProfileImpl;
    const reloadSettings = reloadSettingsImpl;
    const updateTheme = updateThemeImpl;
};

pub fn main() !void {
    var loaded = try config.loadOrCreate(std.heap.page_allocator);
    const application = std.heap.page_allocator.create(Application) catch |err| {
        loaded.deinit();
        return err;
    };
    application.* = Application.init(loaded);
    defer {
        // If synchronous window destruction fails, retain the owner until
        // process exit rather than leave GWLP_USERDATA pointing at freed memory.
        if (application.hwnd == null) {
            application.deinit();
            std.heap.page_allocator.destroy(application);
        }
    }

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

    _ = win.CreateWindowExW(
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
        application,
    ) orelse return error.CreateWindowFailed;

    application.updateTheme();

    var message: win.MSG = undefined;
    while (true) {
        const status = win.GetMessageW(&message, null, 0, 0);
        if (status <= 0) {
            if (application.hwnd) |hwnd| {
                if (win.DestroyWindow(hwnd) == 0) return error.DestroyWindowFailed;
            }
            if (status < 0) return error.GetMessageFailed;
            break;
        }
        if (application.handleShortcut(&message)) continue;
        if (application.chrome) |*bridge| if (bridge.pretranslate(&message)) continue;
        _ = win.TranslateMessage(&message);
        _ = win.DispatchMessageW(&message);
    }
}

fn handleShortcutImpl(self: *Application, message: *const win.MSG) bool {
    if (message.message != win.WM_KEYDOWN and message.message != win.WM_SYSKEYDOWN) return false;
    const control = win.GetKeyState(win.VK_CONTROL) < 0;
    const alt = win.GetKeyState(win.VK_MENU) < 0;
    const shift = win.GetKeyState(win.VK_SHIFT) < 0;
    const repeated = (message.lParam & (@as(win.LPARAM, 1) << 30)) != 0;
    const hwnd = self.hwnd.?;
    if (!control or alt) return false;

    if (shift and message.wParam == 'T') {
        if (!repeated) self.addDefaultSession() catch |err| log.err("unable to open default session: {}", .{err});
        return true;
    }
    if (shift and message.wParam == 'W') {
        if (!repeated) {
            if (self.model.active) |active| sendChromeCommand(hwnd, .close, @intCast(active));
        }
        return true;
    }
    if (message.wParam != win.VK_TAB) return false;

    const count = self.model.sessions.items.len;
    const active = self.model.active orelse return true;
    if (count > 1) {
        const next = if (shift) (active + count - 1) % count else (active + 1) % count;
        sendChromeCommand(hwnd, .select, @intCast(next));
    }
    return true;
}

fn windowProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.c) win.LRESULT {
    var application: ?*Application = null;
    if (message == win.WM_NCCREATE) {
        const create: *const win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        application = @ptrCast(@alignCast(create.lpCreateParams orelse return 0));
        application.?.hwnd = hwnd;
        const userdata: win.LONG_PTR = @bitCast(@intFromPtr(application.?));
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, userdata);
        if (win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA) != userdata) {
            application.?.hwnd = null;
            return 0;
        }
    } else {
        const value = win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA);
        if (value != 0) application = @ptrFromInt(@as(usize, @bitCast(value)));
    }
    const self = application orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    const result = self.windowMessage(message, wparam, lparam);
    if (message == win.WM_NCDESTROY) {
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, 0);
        self.hwnd = null;
    }
    return result;
}

fn windowMessageImpl(self: *Application, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) win.LRESULT {
    const hwnd = self.hwnd.?;
    if (self.taskbar_button_created_message != 0 and message == self.taskbar_button_created_message) {
        self.taskbar_ready = true;
        self.syncTaskbarProgress();
        return 0;
    }
    switch (message) {
        win.WM_CREATE => {
            self.taskbar_button_created_message = win.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarButtonCreated"));
            const dpi = win.GetDpiForWindow(hwnd);
            const font = createFontFor(self.settings, dpi);
            self.font = font;
            self.dpi = dpi;
            self.terminal_view = TerminalView.init(
                hwnd,
                &self.model,
                font,
                self.settings.font_family,
                self.settings.font_size,
                dpi,
                titles_changed_message,
                shell_exited_message,
                scrollbar_changed_message,
                progress_changed_message,
                notification_changed_message,
            );
            self.terminal_view.create(hwnd, win.GetModuleHandleW(null)) catch |err| {
                log.err("unable to create terminal view: {}", .{err});
                return -1;
            };
            self.terminal_ready = true;
            self.chrome = chrome.Bridge.load(hwnd, chromeCommand, self) orelse return -1;
            self.layoutTerminalView();
            self.addDefaultSession() catch |err| {
                log.err("unable to create initial session: {}", .{err});
                return -1;
            };
            return 0;
        },
        chrome_message => {
            const command = chrome.commandFromInt(@intCast(wparam)) orelse return 0;
            const argument: u32 = @intCast(lparam);
            switch (command) {
                .new_powershell => self.addProfile(.powershell) catch |err| {
                    log.err("unable to open PowerShell session: {}", .{err});
                    return 0;
                },
                .new_wsl => self.addProfile(.wsl) catch |err| {
                    log.err("unable to open WSL session: {}", .{err});
                    return 0;
                },
                .new_pwsh => self.addProfile(.pwsh) catch |err| log.err("unable to open PowerShell 7 session: {}", .{err}),
                .new_cmd => self.addProfile(.cmd) catch |err| log.err("unable to open Command Prompt session: {}", .{err}),
                .new_custom => self.addProfile(.custom) catch |err| log.err("unable to open custom session: {}", .{err}),
                .close => {
                    self.model.closeSession(argument);
                    if (self.model.sessions.items.len == 0) {
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    }
                },
                .select => self.model.activate(argument),
                .open_settings => {
                    openSettings(hwnd) catch |err| log.err("unable to open settings: {}", .{err});
                    return 0;
                },
                .reload_settings => {
                    self.reloadSettings() catch |err| log.err("unable to reload settings: {}", .{err});
                    return 0;
                },
                .quit => {
                    _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                    return 0;
                },
                .scroll => {
                    self.terminal_view.scrollTo(argument);
                    return 0;
                },
                .scroll_wheel => {
                    self.terminal_view.handleMouseWheelDelta(@bitCast(argument));
                    return 0;
                },
                .notification_activate => {
                    if (!self.model.activateSessionId(argument)) return 0;
                    self.terminal_view.syncSessions();
                    self.terminal_view.invalidate();
                    self.syncChrome();
                    _ = win.ShowWindow(hwnd, win.SW_RESTORE);
                    _ = win.SetForegroundWindow(hwnd);
                    _ = win.SetFocus(self.terminal_view.hwnd);
                    return 0;
                },
            }
            self.terminal_view.syncSessions();
            _ = win.InvalidateRect(hwnd, null, 0);
            self.terminal_view.invalidate();
            self.syncChrome();
            return 0;
        },
        titles_changed_message => {
            if (self.model.syncTitles()) self.syncChrome();
            return 0;
        },
        shell_exited_message => {
            if (!self.model.closeCleanlyExitedSessions()) return 0;
            if (self.model.sessions.items.len == 0) {
                _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                return 0;
            }
            self.terminal_view.syncSessions();
            self.terminal_view.invalidate();
            self.syncChrome();
            return 0;
        },
        scrollbar_changed_message => {
            self.syncScrollbar(wparam != 0);
            return 0;
        },
        progress_changed_message => {
            self.syncTaskbarProgress();
            return 0;
        },
        notification_changed_message => {
            self.showPendingNotifications();
            return 0;
        },
        win.WM_TIMER => {
            if (wparam == taskbar_progress_timer) {
                self.syncTaskbarProgress();
                return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_SIZE => {
            self.layoutTerminalView();
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
            const new_dpi: u32 = @intCast(wparam & 0xffff);
            const new_font = createFontFor(self.settings, new_dpi);
            self.terminal_view.updateFont(new_font, new_dpi);
            _ = win.DeleteObject(self.font);
            self.font = new_font;
            self.dpi = new_dpi;
            self.layoutTerminalView();
            _ = win.InvalidateRect(hwnd, null, 0);
            return 0;
        },
        win.WM_SETTINGCHANGE, win.WM_THEMECHANGED, win.WM_SYSCOLORCHANGE => {
            self.updateTheme();
            return 0;
        },
        win.WM_CLOSE => {
            _ = win.KillTimer(hwnd, taskbar_progress_timer);
            if (self.taskbar_ready) {
                if (self.chrome) |*bridge| _ = bridge.updateTaskbarProgress(win.ZIGONAUT_TASKBAR_PROGRESS_NONE, 0);
            }
            if (self.chrome) |*bridge| bridge.close();
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_DESTROY => {
            win.PostQuitMessage(0);
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn layoutTerminalViewImpl(self: *Application) void {
    const hwnd = self.hwnd orelse return;
    var client: win.RECT = undefined;
    if (win.GetClientRect(hwnd, &client) == 0) return;
    const dpi = self.dpi;
    const terminal_top = scaled(winui_terminal_top, dpi);
    const bridge = if (self.chrome) |*value| value else return;
    if (!bridge.move(0, 0, client.right, terminal_top)) {
        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
        return;
    }
    self.terminal_view.move(
        0,
        terminal_top,
        client.right,
        client.bottom - terminal_top,
    );
}

fn syncChromeImpl(self: *Application) void {
    const bridge = if (self.chrome) |*value| value else return;
    const count = self.model.sessions.items.len;
    self.chrome_titles.ensureTotalCapacity(std.heap.page_allocator, count) catch |err| {
        log.err("unable to allocate chrome title pointers: {}", .{err});
        return;
    };
    self.chrome_title_lengths.ensureTotalCapacity(std.heap.page_allocator, count) catch |err| {
        log.err("unable to allocate chrome title lengths: {}", .{err});
        return;
    };
    self.chrome_titles.items.len = count;
    self.chrome_title_lengths.items.len = count;
    for (self.model.sessions.items, 0..) |session, index| {
        const title = session.displayTitle();
        self.chrome_titles.items[index] = title.ptr;
        self.chrome_title_lengths.items[index] = @intCast(title.len);
    }
    if (!bridge.update(self.chrome_titles.items, self.chrome_title_lengths.items, self.model.active)) {
        _ = win.PostMessageW(self.hwnd.?, win.WM_CLOSE, 0, 0);
        return;
    }
    self.syncScrollbar(false);
    self.syncTaskbarProgress();
}

fn syncScrollbarImpl(self: *Application, show: bool) void {
    const bridge = if (self.chrome) |*value| value else return;
    const state = self.terminal_view.scrollbar();
    const limit = std.math.maxInt(u32);
    if (!bridge.updateScrollbar(
        @intCast(@min(state.total, limit)),
        @intCast(@min(state.len, limit)),
        @intCast(@min(state.offset, limit)),
        show,
    )) {
        _ = win.PostMessageW(self.hwnd.?, win.WM_CLOSE, 0, 0);
    }
}

fn syncTaskbarProgressImpl(self: *Application) void {
    const hwnd = self.hwnd orelse return;
    const bridge = if (self.chrome) |*value| value else return;
    if (!self.taskbar_ready) return;
    const current = if (self.model.activeSession()) |session|
        if (session.runtime) |runtime| runtime.taskbarProgress() else null
    else
        null;
    _ = win.KillTimer(hwnd, taskbar_progress_timer);
    const value = current orelse {
        _ = bridge.updateTaskbarProgress(win.ZIGONAUT_TASKBAR_PROGRESS_NONE, 0);
        return;
    };
    const now = win.GetTickCount64();
    const age = now -| value.updated_tick;
    if (age >= taskbar_progress_timeout_ms) {
        _ = bridge.updateTaskbarProgress(win.ZIGONAUT_TASKBAR_PROGRESS_NONE, 0);
        return;
    }
    const state: u32 = switch (value.state) {
        .normal => win.ZIGONAUT_TASKBAR_PROGRESS_NORMAL,
        .error_state => win.ZIGONAUT_TASKBAR_PROGRESS_ERROR,
        .indeterminate => win.ZIGONAUT_TASKBAR_PROGRESS_INDETERMINATE,
        .paused => win.ZIGONAUT_TASKBAR_PROGRESS_PAUSED,
    };
    _ = bridge.updateTaskbarProgress(state, value.value);
    _ = win.SetTimer(hwnd, taskbar_progress_timer, @intCast(taskbar_progress_timeout_ms - age), null);
}

fn showPendingNotificationsImpl(self: *Application) void {
    const bridge = if (self.chrome) |*value| value else return;
    for (self.model.sessions.items) |*session| {
        const runtime = session.runtime orelse continue;
        while (runtime.takeNotification()) |notification| {
            defer runtime.freeNotification(notification);
            const title = if (notification.title.len > 0) notification.title else session.displayTitle();
            if (!std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(notification.body)) continue;
            _ = bridge.showNotification(session.id, title, notification.body);
        }
    }
}

fn chromeCommand(context: ?*anyopaque, command: u32, argument: u32) callconv(.c) void {
    const self: *Application = @ptrCast(@alignCast(context orelse return));
    const hwnd = self.hwnd orelse return;
    const typed = chrome.commandFromInt(command) orelse return;
    sendChromeCommand(hwnd, typed, argument);
}

fn addDefaultSessionImpl(self: *Application) !void {
    const shell: app_model.Shell = switch (self.settings.default_shell) {
        .powershell => .powershell,
        .pwsh => .pwsh,
        .cmd => .cmd,
        .wsl => .wsl,
        .custom => if (self.settings.custom_command.len > 0) .custom else .powershell,
    };
    try self.addProfile(shell);
    self.terminal_view.syncSessions();
    self.terminal_view.invalidate();
    self.syncChrome();
}

fn addProfileImpl(self: *Application, shell: app_model.Shell) !void {
    const command = if (shell == .custom) self.settings.custom_command else shell.command();
    const title = if (shell == .custom) self.settings.custom_profile_name else shell.title();
    _ = try self.model.addSession(shell, title, command, self.settings.working_directory, self.settings.hold_on_exit, self.terminal_view.columns, self.terminal_view.rows);
}

fn sendChromeCommand(hwnd: win.HWND, command: chrome.Command, argument: u32) void {
    _ = win.PostMessageW(hwnd, chrome_message, @intFromEnum(command), @intCast(argument));
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

fn reloadSettingsImpl(self: *Application) !void {
    var replacement = try config.loadOrCreate(std.heap.page_allocator);
    errdefer replacement.deinit();

    const next = replacement.value;
    const changed = config.changes(self.settings, next);
    const new_font = if (changed.font) createFontFor(next, self.dpi) else null;
    if (changed.font and new_font == null) return error.CreateFontFailed;
    errdefer {
        if (new_font != null) _ = win.DeleteObject(new_font);
    }
    if (new_font != null) {
        try self.terminal_view.reloadFont(new_font, next.font_family, next.font_size, self.dpi);
    }

    const old_font = self.font;
    if (new_font != null) self.font = new_font;
    var previous = self.loaded;
    self.loaded = replacement;
    self.settings = self.loaded.value;
    previous.deinit();

    if (changed.theme) {
        self.model.applySettings(self.settings.theme.value(), self.settings.randomize_tab_background);
    }
    if (new_font != null) {
        _ = win.DeleteObject(old_font);
        self.layoutTerminalView();
    }
    self.terminal_view.invalidate();
}

fn scaled(value: anytype, dpi: u32) i32 {
    return win.MulDiv(@intCast(value), @intCast(dpi), 96);
}

fn updateThemeImpl(self: *Application) void {
    const hwnd = self.hwnd orelse return;
    self.dark_theme = appsUseDarkTheme();
    self.high_contrast = highContrastEnabled();
    if (self.terminal_ready) self.terminal_view.updateTheme(self.dark_theme, self.high_contrast);
    var dark_mode: win.BOOL = @intFromBool(self.dark_theme and !self.high_contrast);
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
