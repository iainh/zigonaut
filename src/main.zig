const std = @import("std");
const app_model = @import("app.zig");
const build_options = @import("build_options");
const chrome = @import("chrome_bridge.zig");
const config = @import("config.zig");
const theme = @import("theme.zig");
const TerminalView = @import("terminal_view.zig").View;

const win32 = @import("win32.zig");
const win = win32.c;
const log = std.log.scoped(.app);

const open_operation = std.unicode.utf8ToUtf16LeStringLiteral("open");
const personalize_key = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize");
const apps_use_light_theme = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");

const chrome_message = win.WM_APP + 1;
const titles_changed_message = win.WM_APP + 2;
const shell_exited_message = win.WM_APP + 3;
const scrollbar_changed_message = win.WM_APP + 4;
const progress_changed_message = win.WM_APP + 5;
const notification_changed_message = win.WM_APP + 6;
const renderer_failed_message = win.WM_APP + 7;
const taskbar_progress_timer = 1;
const taskbar_progress_timeout_ms = 15_000;
const window_subclass_id: win.UINT_PTR = 1;

const Application = struct {
    loaded: config.Loaded,
    themes: theme.Catalog,
    settings: config.Config,
    hwnd: ?win.HWND = null,
    model: app_model.App,
    font: win.HFONT = null,
    dpi: u32 = 96,
    dark_theme: bool = false,
    high_contrast: bool = false,
    zoomed_font_size: u16,
    window_subclassed: bool = false,
    taskbar_button_created_message: win.UINT = 0,
    taskbar_ready: bool = false,
    terminal_ready: bool = false,
    terminal_view: TerminalView = undefined,
    chrome: ?chrome.Bridge = null,
    chrome_titles: std.ArrayList([*]const u8) = .empty,
    chrome_title_lengths: std.ArrayList(u32) = .empty,

    fn init(loaded: config.Loaded, themes: theme.Catalog) Application {
        const dark_theme = config.useDarkTheme(loaded.value, appsUseDarkTheme());
        return .{
            .settings = loaded.value,
            .loaded = loaded,
            .themes = themes,
            .model = app_model.App.init(std.heap.page_allocator, config.terminalTheme(loaded.value, &themes, dark_theme), loaded.value.randomize_tab_background),
            .dark_theme = dark_theme,
            .zoomed_font_size = loaded.value.font_size,
        };
    }

    fn deinit(self: *Application) void {
        self.model.deinit();
        self.chrome_titles.deinit(std.heap.page_allocator);
        self.chrome_title_lengths.deinit(std.heap.page_allocator);
        if (self.font != null) _ = win.DeleteObject(self.font);
        self.loaded.deinit();
    }

    const windowMessage = windowMessageImpl;
    const initializeWindow = initializeWindowImpl;
    const shutdownWindow = shutdownWindowImpl;
    const syncChrome = syncChromeImpl;
    const syncScrollbar = syncScrollbarImpl;
    const syncTaskbarProgress = syncTaskbarProgressImpl;
    const showPendingNotifications = showPendingNotificationsImpl;
    const addDefaultSession = addDefaultSessionImpl;
    const addProfile = addProfileImpl;
    const syncProfiles = syncProfilesImpl;
    const reloadSettings = reloadSettingsImpl;
    const updateTheme = updateThemeImpl;
    const setZoomedFontSize = setZoomedFontSizeImpl;
    const attachTerminalRenderer = attachTerminalRendererImpl;
    const recoverTerminalRenderer = recoverTerminalRendererImpl;

    fn bindActivePane(self: *Application) void {
        self.terminal_view.bindPane(if (self.model.activePane()) |pane| pane.id else null);
    }
};

pub fn main() !void {
    var loaded = try config.loadOrCreate(std.heap.page_allocator);
    const themes = theme.Catalog.load(std.heap.page_allocator);
    const application = std.heap.page_allocator.create(Application) catch |err| {
        loaded.deinit();
        return err;
    };
    application.* = Application.init(loaded, themes);
    defer {
        // If synchronous window destruction fails, retain the owner until
        // process exit rather than leave a subclass callback pointing at freed memory.
        if (application.hwnd == null) {
            application.deinit();
            std.heap.page_allocator.destroy(application);
        }
    }

    const instance = win.GetModuleHandleW(null);
    const arrow_cursor: win.LPCWSTR = @ptrFromInt(32512);
    const cursor = win.LoadCursorW(null, arrow_cursor);
    try TerminalView.registerClass(instance, cursor);
    application.chrome = chrome.Bridge.load() orelse return error.LoadWinUIFailed;
    const result = application.chrome.?.run(
        windowStarted,
        chromeCommand,
        application,
        build_options.version,
        build_options.git_hash,
    );
    if (!chrome.succeeded(result)) {
        std.debug.print("WinUI window exited with HRESULT 0x{x}\n", .{@as(u32, @bitCast(result))});
        return error.RunWinUIFailed;
    }
}

fn windowStarted(context: ?*anyopaque, native_bridge: ?*anyopaque, hwnd: win.HWND) callconv(.c) win.BOOL {
    const self: *Application = @ptrCast(@alignCast(context orelse return 0));
    const bridge = if (self.chrome) |*value| value else return 0;
    if (!bridge.setInstance(native_bridge)) return 0;
    self.hwnd = hwnd;
    if (win.SetWindowSubclass(hwnd, windowSubclassProc, window_subclass_id, @intFromPtr(self)) == 0) {
        self.hwnd = null;
        return 0;
    }
    self.window_subclassed = true;
    win.DragAcceptFiles(hwnd, 1);
    setWindowIcons(hwnd);
    self.initializeWindow() catch |err| {
        log.err("unable to initialize application window: {}", .{err});
        return 0;
    };
    return 1;
}

fn initializeWindowImpl(self: *Application) !void {
    const hwnd = self.hwnd orelse return error.WindowUnavailable;
    self.taskbar_button_created_message = win.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarButtonCreated"));
    const dpi = win.GetDpiForWindow(hwnd);
    const font = createFontFor(self.settings, dpi);
    if (font == null) return error.CreateFontFailed;
    self.font = font;
    self.dpi = dpi;
    self.terminal_view = TerminalView.init(
        hwnd,
        &self.model,
        font,
        self.settings.font_family,
        self.settings.font_size,
        dpi,
        self.settings.padding_horizontal,
        self.settings.padding_vertical,
        self.settings.background_opacity,
        titles_changed_message,
        shell_exited_message,
        scrollbar_changed_message,
        progress_changed_message,
        notification_changed_message,
        renderer_failed_message,
        chrome_message,
    );
    try self.terminal_view.create(hwnd, win.GetModuleHandleW(null));
    self.terminal_ready = true;
    if (!self.attachTerminalRenderer()) return error.AttachTerminalFailed;
    try self.syncProfiles(&self.settings);
    try self.addDefaultSession();
    self.updateTheme();
}

fn setWindowIcons(hwnd: win.HWND) void {
    const instance = win.GetModuleHandleW(null);
    const resource = win32.handleFromInt(win.LPCWSTR, 1);
    const large = win.LoadImageW(instance, resource, win.IMAGE_ICON, win.GetSystemMetrics(win.SM_CXICON), win.GetSystemMetrics(win.SM_CYICON), win.LR_SHARED);
    const small = win.LoadImageW(instance, resource, win.IMAGE_ICON, win.GetSystemMetrics(win.SM_CXSMICON), win.GetSystemMetrics(win.SM_CYSMICON), win.LR_SHARED);
    if (large) |icon| _ = win.SendMessageW(hwnd, win.WM_SETICON, win.ICON_BIG, @intCast(@intFromPtr(icon)));
    if (small) |icon| _ = win.SendMessageW(hwnd, win.WM_SETICON, win.ICON_SMALL, @intCast(@intFromPtr(icon)));
}

fn windowSubclassProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM, _: win.UINT_PTR, reference: win.DWORD_PTR) callconv(.c) win.LRESULT {
    const self: *Application = @ptrFromInt(reference);
    const result = self.windowMessage(message, wparam, lparam);
    if (message == win.WM_NCDESTROY) {
        _ = win.RemoveWindowSubclass(hwnd, windowSubclassProc, window_subclass_id);
        self.window_subclassed = false;
        self.hwnd = null;
        if (self.chrome) |*bridge| bridge.detach();
    }
    return result;
}

fn shutdownWindowImpl(self: *Application) void {
    const hwnd = self.hwnd orelse return;
    if (self.terminal_ready) self.terminal_view.resetInteraction();
    _ = win.KillTimer(hwnd, taskbar_progress_timer);
    if (self.taskbar_ready) {
        if (self.chrome) |*bridge| _ = bridge.updateTaskbarProgress(win.ZIGONAUT_TASKBAR_PROGRESS_NONE, 0);
    }
    if (self.window_subclassed) {
        _ = win.RemoveWindowSubclass(hwnd, windowSubclassProc, window_subclass_id);
        self.window_subclassed = false;
    }
    self.hwnd = null;
    if (self.chrome) |*bridge| bridge.detach();
}

fn windowMessageImpl(self: *Application, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) win.LRESULT {
    const hwnd = self.hwnd.?;
    if (self.taskbar_button_created_message != 0 and message == self.taskbar_button_created_message) {
        self.taskbar_ready = true;
        self.syncTaskbarProgress();
        return 0;
    }
    switch (message) {
        chrome_message => {
            const command = chrome.commandFromInt(@intCast(wparam)) orelse return 0;
            const argument: u32 = @intCast(lparam);
            switch (command) {
                .new_profile => {
                    if (argument >= @as(u32, @intCast(self.settings.profile_count))) return 0;
                    self.addProfile(self.settings.profiles[argument]) catch |err| log.err("unable to open profile: {}", .{err});
                },
                .new_default => {
                    self.addDefaultSession() catch |err| log.err("unable to open default shell session: {}", .{err});
                    return 0;
                },
                .close => {
                    self.terminal_view.bindPane(null);
                    self.model.closeTab(argument);
                    if (self.model.tabCount() == 0) {
                        self.terminal_view.bindPane(null);
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    }
                    self.bindActivePane();
                },
                .select => {
                    self.terminal_view.resetInteraction();
                    self.model.activateTab(argument);
                    self.bindActivePane();
                },
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
                    self.terminal_view.resetInteraction();
                    if (!self.model.activateSessionId(argument)) return 0;
                    self.bindActivePane();
                    self.terminal_view.syncSessions();
                    self.terminal_view.invalidate();
                    self.syncChrome();
                    _ = win.ShowWindow(hwnd, win.SW_RESTORE);
                    _ = win.SetForegroundWindow(hwnd);
                    if (self.chrome) |*bridge| _ = bridge.focusTerminal();
                    return 0;
                },
                .zoom_in => {
                    self.setZoomedFontSize(config.clampZoom(self.zoomed_font_size, 1));
                    return 0;
                },
                .zoom_out => {
                    self.setZoomedFontSize(config.clampZoom(self.zoomed_font_size, -1));
                    return 0;
                },
                .zoom_reset => {
                    self.setZoomedFontSize(self.settings.font_size);
                    return 0;
                },
                .select_next, .select_previous => {
                    const count = self.model.tabCount();
                    const active = self.model.activeTabIndex() orelse return 0;
                    if (count <= 1) return 0;
                    self.terminal_view.resetInteraction();
                    const next = if (command == .select_previous) (active + count - 1) % count else (active + 1) % count;
                    self.model.activateTab(next);
                    self.bindActivePane();
                },
                .shutdown => return 0,
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
            self.terminal_view.bindPane(null);
            if (!self.model.closeCleanlyExitedSessions()) {
                self.bindActivePane();
                return 0;
            }
            if (self.model.tabCount() == 0) {
                self.terminal_view.bindPane(null);
                _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                return 0;
            }
            self.bindActivePane();
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
        renderer_failed_message => {
            self.recoverTerminalRenderer();
            return 0;
        },
        win.WM_TIMER => {
            if (wparam == taskbar_progress_timer) {
                self.syncTaskbarProgress();
                return 0;
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        win.WM_DPICHANGED => {
            const new_dpi: u32 = @intCast(wparam & 0xffff);
            const new_font = createFont(self.settings.font_family, self.zoomed_font_size, new_dpi);
            if (new_font != null) {
                self.terminal_view.updateFont(new_font, new_dpi);
                _ = win.DeleteObject(self.font);
                self.font = new_font;
                self.dpi = new_dpi;
                _ = win.InvalidateRect(hwnd, null, 0);
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        win.WM_SETTINGCHANGE => {
            self.terminal_view.refreshTextRenderingSettings();
            self.updateTheme();
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        win.WM_DROPFILES => {
            if (self.terminal_ready) return win.SendMessageW(self.terminal_view.hwnd, message, wparam, lparam);
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        win.WM_THEMECHANGED, win.WM_SYSCOLORCHANGE => {
            self.updateTheme();
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        else => return win.DefSubclassProc(hwnd, message, wparam, lparam),
    }
}

fn syncChromeImpl(self: *Application) void {
    const bridge = if (self.chrome) |*value| value else return;
    const count = self.model.tabCount();
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
    for (self.model.tabs.items, 0..) |*tab, index| {
        const title = tab.displayTitle();
        self.chrome_titles.items[index] = title.ptr;
        self.chrome_title_lengths.items[index] = @intCast(title.len);
    }
    if (!bridge.update(self.chrome_titles.items, self.chrome_title_lengths.items, self.model.activeTabIndex())) {
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
    for (self.model.tabs.items) |*tab| for (tab.panes.items) |*pane| {
        const session = &pane.session;
        const runtime = session.runtime orelse continue;
        while (runtime.takeNotification()) |notification| {
            defer runtime.freeNotification(notification);
            const title = if (notification.title.len > 0) notification.title else session.displayTitle();
            if (!std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(notification.body)) continue;
            _ = bridge.showNotification(session.id, title, notification.body);
        }
    };
}

fn chromeCommand(context: ?*anyopaque, command: u32, argument: u32) callconv(.c) void {
    const self: *Application = @ptrCast(@alignCast(context orelse return));
    const typed = chrome.commandFromInt(command) orelse return;
    if (typed == .shutdown) {
        self.shutdownWindow();
        return;
    }
    const hwnd = self.hwnd orelse return;
    sendChromeCommand(hwnd, typed, argument);
}

fn addDefaultSessionImpl(self: *Application) !void {
    try self.addProfile(self.settings.defaultProfile());
    self.terminal_view.syncSessions();
    self.terminal_view.invalidate();
    self.syncChrome();
}

fn addProfileImpl(self: *Application, profile: config.Profile) !void {
    self.terminal_view.resetInteraction();
    const shell: app_model.Shell = switch (profile.shell) {
        .powershell => .powershell,
        .windows => .windows,
        .wsl => .wsl,
    };
    _ = try self.model.addSession(shell, profile.name, profile.command, self.settings.working_directory, self.settings.hold_on_exit, self.terminal_view.columns, self.terminal_view.rows);
    self.bindActivePane();
}

fn syncProfilesImpl(self: *Application, settings: *const config.Config) !void {
    const bridge = if (self.chrome) |*value| value else return;
    var names: [config.max_profiles][*]const u8 = undefined;
    var lengths: [config.max_profiles]u32 = undefined;
    for (settings.profileSlice(), 0..) |profile, index| {
        names[index] = profile.name.ptr;
        lengths[index] = @intCast(profile.name.len);
    }
    if (!bridge.updateProfiles(names[0..settings.profile_count], lengths[0..settings.profile_count])) return error.UpdateProfilesFailed;
}

fn sendChromeCommand(hwnd: win.HWND, command: chrome.Command, argument: u32) void {
    _ = win.PostMessageW(hwnd, chrome_message, @intFromEnum(command), @intCast(argument));
}

fn createFontFor(value: config.Config, dpi: u32) win.HFONT {
    return createFont(value.font_family, value.font_size, dpi);
}

fn createFont(font_family: []const u8, font_size: u16, dpi: u32) win.HFONT {
    var wide_name = std.mem.zeroes([128]u16);
    _ = std.unicode.utf8ToUtf16Le(wide_name[0 .. wide_name.len - 1], font_family) catch 0;
    return win.CreateFontW(
        -scaled(font_size, dpi),
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
        win.DEFAULT_QUALITY,
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
    errdefer self.syncProfiles(&self.settings) catch {
        if (self.hwnd) |hwnd| _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
    };
    try self.syncProfiles(&next);
    if (new_font != null) {
        try self.terminal_view.reloadFont(new_font, next.font_family, next.font_size, self.dpi);
        if (!self.attachTerminalRenderer()) {
            log.err("unable to attach the reloaded terminal renderer", .{});
            if (self.hwnd) |hwnd| _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
        }
        self.zoomed_font_size = next.font_size;
    }

    const old_font = self.font;
    if (new_font != null) self.font = new_font;
    var previous = self.loaded;
    self.loaded = replacement;
    self.settings = self.loaded.value;
    previous.deinit();

    if (changed.theme) {
        self.dark_theme = config.useDarkTheme(self.settings, appsUseDarkTheme());
        self.model.applySettings(config.terminalTheme(self.settings, &self.themes, self.dark_theme), self.settings.randomize_tab_background);
    }
    self.terminal_view.updatePadding(self.settings.padding_horizontal, self.settings.padding_vertical);
    self.updateTheme();
    if (new_font != null) _ = win.DeleteObject(old_font);
    self.terminal_view.invalidate();
}

fn scaled(value: anytype, dpi: u32) i32 {
    return win.MulDiv(@intCast(value), @intCast(dpi), 96);
}

fn updateThemeImpl(self: *Application) void {
    const hwnd = self.hwnd orelse return;
    const previous_dark_theme = self.dark_theme;
    self.dark_theme = config.useDarkTheme(self.settings, appsUseDarkTheme());
    self.high_contrast = highContrastEnabled();
    if (self.terminal_ready and previous_dark_theme != self.dark_theme) self.model.applySettings(config.terminalTheme(self.settings, &self.themes, self.dark_theme), self.settings.randomize_tab_background);
    if (self.terminal_ready) self.terminal_view.updateTheme(self.dark_theme, self.high_contrast, self.settings.background_opacity);
    if (self.chrome) |*bridge| _ = bridge.updateAppearance(@intFromEnum(self.settings.backdrop), self.high_contrast, self.dark_theme);
    var dark_mode: win.BOOL = @intFromBool(self.dark_theme and !self.high_contrast);
    _ = win.DwmSetWindowAttribute(hwnd, 20, &dark_mode, @sizeOf(win.BOOL));
    _ = win.InvalidateRect(hwnd, null, 0);
}

fn setZoomedFontSizeImpl(self: *Application, size: u16) void {
    if (size == self.zoomed_font_size) return;
    const new_font = createFont(self.settings.font_family, size, self.dpi);
    if (new_font == null) return;
    self.terminal_view.reloadFont(new_font, self.settings.font_family, size, self.dpi) catch {
        _ = win.DeleteObject(new_font);
        return;
    };
    if (!self.attachTerminalRenderer()) {
        log.err("unable to attach the zoomed terminal renderer", .{});
        if (self.hwnd) |hwnd| _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
    }
    _ = win.DeleteObject(self.font);
    self.font = new_font;
    self.zoomed_font_size = size;
}

fn attachTerminalRendererImpl(self: *Application) bool {
    const bridge = if (self.chrome) |*value| value else return false;
    return bridge.attachTerminal(self.terminal_view.hwnd, self.terminal_view.swapChain());
}

fn recoverTerminalRendererImpl(self: *Application) void {
    const new_font = createFont(self.settings.font_family, self.zoomed_font_size, self.dpi);
    if (new_font == null) {
        log.err("unable to recreate the terminal font after a renderer failure", .{});
        return;
    }
    self.terminal_view.reloadFont(new_font, self.settings.font_family, self.zoomed_font_size, self.dpi) catch |err| {
        _ = win.DeleteObject(new_font);
        log.err("unable to recover the terminal renderer: {}", .{err});
        return;
    };
    if (!self.attachTerminalRenderer()) {
        log.err("unable to reattach the recovered terminal renderer", .{});
        if (self.hwnd) |hwnd| _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
    }
    _ = win.DeleteObject(self.font);
    self.font = new_font;
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
