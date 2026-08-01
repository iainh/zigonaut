const std = @import("std");
const app_model = @import("app.zig");
const build_options = @import("build_options");
const chrome = @import("chrome_bridge.zig");
const config = @import("config.zig");
const pane_tree = @import("pane_tree.zig");
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
const pane_event_message = win.WM_APP + 8;
const runtime_refresh_message = win.WM_APP + 9;
const ime_bounds_changed_message = win.WM_APP + 10;
const search_status_changed_message = win.WM_APP + 11;
const initial_chrome_message = win.WM_APP + 12;
const pane_event_release_threshold = 1024;
const taskbar_progress_timer = 1;
const taskbar_progress_timeout_ms = 15_000;
const window_subclass_id: win.UINT_PTR = 1;
// Serialize process creation while temporary inheritable handles are open.
// Without this lock, an unrelated child can inherit a pipe or NUL handle.
var process_spawn_mutex: @import("win32.zig").Mutex = .{};

const LaunchKind = enum { new_tab, split_right, split_down };

const LaunchAction = struct {
    kind: LaunchKind = .new_tab,
    profile: ?[]u8 = null,
    working_directory: ?[]u8 = null,

    fn deinit(self: *LaunchAction, allocator: std.mem.Allocator) void {
        if (self.profile) |value| allocator.free(value);
        if (self.working_directory) |value| allocator.free(value);
    }
};

const LaunchPlan = struct {
    allocator: std.mem.Allocator,
    actions: std.ArrayList(LaunchAction) = .empty,

    fn deinit(self: *LaunchPlan) void {
        for (self.actions.items) |*action| action.deinit(self.allocator);
        self.actions.deinit(self.allocator);
    }
};

const Application = struct {
    const ViewEntry = struct { pane_id: u64, view: *TerminalView };
    io: std.Io,
    loaded: config.Loaded,
    themes: theme.Catalog,
    settings: config.Config,
    launch_plan: LaunchPlan,
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
    views: std.ArrayList(ViewEntry) = .empty,
    refresh_hwnd: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    refresh_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    chrome: ?chrome.Bridge = null,
    attached_panes: std.ArrayList(u64) = .empty,
    pane_events_mutex: @import("win32.zig").Mutex = .{},
    pane_events: std.ArrayList(chrome.PaneEvent) = .empty,
    pane_events_head: usize = 0,
    chrome_titles: std.ArrayList([*]const u8) = .empty,
    chrome_title_lengths: std.ArrayList(u32) = .empty,
    chrome_colors: std.ArrayList(u32) = .empty,
    chrome_activity: std.ArrayList(u8) = .empty,

    fn init(io: std.Io, loaded: config.Loaded, themes: theme.Catalog, launch_plan: LaunchPlan) Application {
        const dark_theme = config.useDarkTheme(loaded.value, appsUseDarkTheme());
        var result = Application{
            .io = io,
            .settings = loaded.value,
            .loaded = loaded,
            .themes = themes,
            .launch_plan = launch_plan,
            .model = app_model.App.init(std.heap.page_allocator, io, config.terminalTheme(loaded.value, &themes, dark_theme), loaded.value.randomize_tab_background),
            .dark_theme = dark_theme,
            .zoomed_font_size = loaded.value.font_size,
        };
        result.model.applyClipboardWriteSettings(loaded.value.osc52_clipboard_write, loaded.value.osc52_clipboard_max_bytes);
        result.model.setDefaultScrollbackSize(loaded.value.scrollback_size);
        return result;
    }

    fn deinit(self: *Application) void {
        self.destroyAllViews();
        self.model.deinit();
        self.views.deinit(std.heap.page_allocator);
        self.attached_panes.deinit(std.heap.page_allocator);
        self.chrome_titles.deinit(std.heap.page_allocator);
        self.chrome_title_lengths.deinit(std.heap.page_allocator);
        self.chrome_colors.deinit(std.heap.page_allocator);
        self.chrome_activity.deinit(std.heap.page_allocator);
        self.pane_events.deinit(std.heap.page_allocator);
        self.launch_plan.deinit();
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
    const applyLaunchPlan = applyLaunchPlanImpl;
    const addDefaultSession = addDefaultSessionImpl;
    const addProfile = addProfileImpl;
    const addProfileAt = addProfileAtImpl;
    const profileNamed = profileNamedImpl;
    const spawnNewWindow = spawnNewWindowImpl;
    const pipeCommandOutput = pipeCommandOutputImpl;
    const syncProfiles = syncProfilesImpl;
    const openSettingsPage = openSettingsPageImpl;
    const reloadSettings = reloadSettingsImpl;
    const updateTheme = updateThemeImpl;
    const setZoomedFontSize = setZoomedFontSizeImpl;
    const attachTerminalRenderer = attachTerminalRendererImpl;
    const detachTerminalRenderer = detachTerminalRendererImpl;
    const recoverTerminalRenderer = recoverTerminalRendererImpl;
    const openFallbackProfile = openFallbackProfileImpl;
    const showProfileFallback = showProfileFallbackImpl;
    const showProfileLaunchError = showProfileLaunchErrorImpl;

    fn implicitDefaultLaunch(self: *const Application) bool {
        if (self.launch_plan.actions.items.len != 1) return false;
        const action = self.launch_plan.actions.items[0];
        return action.kind == .new_tab and action.profile == null and action.working_directory == null;
    }

    fn launchFailureProfile(self: *Application) config.Profile {
        for (self.launch_plan.actions.items) |action| {
            if (self.profileNamed(action.profile)) |profile| return profile;
        }
        return self.settings.defaultProfile();
    }

    fn takePaneEvent(self: *Application) ?chrome.PaneEvent {
        self.pane_events_mutex.lock();
        defer self.pane_events_mutex.unlock();
        if (self.pane_events_head == self.pane_events.items.len) return null;
        const event = self.pane_events.items[self.pane_events_head];
        self.pane_events_head += 1;
        if (self.pane_events_head == self.pane_events.items.len) {
            self.pane_events_head = 0;
            if (self.pane_events.capacity > pane_event_release_threshold) {
                self.pane_events.deinit(std.heap.page_allocator);
                self.pane_events = .empty;
            } else {
                self.pane_events.clearRetainingCapacity();
            }
        }
        return event;
    }

    fn viewFor(self: *Application, id: u64) ?*TerminalView {
        for (self.views.items) |entry| if (entry.pane_id == id) return entry.view;
        return null;
    }

    fn activeView(self: *Application) ?*TerminalView {
        return self.viewFor((self.model.activePane() orelse return null).id);
    }

    fn ensureView(self: *Application, id: u64) !*TerminalView {
        if (self.viewFor(id)) |view| return view;
        const hwnd = self.hwnd orelse return error.WindowUnavailable;
        const view = try std.heap.page_allocator.create(TerminalView);
        var may_free = true;
        errdefer if (may_free) std.heap.page_allocator.destroy(view);
        view.* = TerminalView.init(hwnd, &self.model, self.font, self.settings.font_family, self.zoomed_font_size, @intFromEnum(self.settings.font_weight), @intFromEnum(self.settings.intense_font_weight), self.dpi, self.settings.padding_horizontal, self.settings.padding_vertical, self.settings.background_opacity, titles_changed_message, shell_exited_message, scrollbar_changed_message, progress_changed_message, notification_changed_message, renderer_failed_message, ime_bounds_changed_message, search_status_changed_message, chrome_message);
        view.pane_id = id;
        view.create(hwnd, win.GetModuleHandleW(null)) catch |err| {
            if (!view.destroy()) may_free = false;
            return err;
        };
        if (view.swapChain() == null) {
            if (!view.destroy()) {
                may_free = false;
                return error.DestroyTerminalViewFailed;
            }
            return error.SwapChainUnavailable;
        }
        view.syncSessions();
        self.views.append(std.heap.page_allocator, .{ .pane_id = id, .view = view }) catch |err| {
            if (!view.destroy()) may_free = false;
            return err;
        };
        return view;
    }

    fn detachPresentation(self: *Application) !void {
        const bridge = if (self.chrome) |*value| value else return error.ChromeUnavailable;
        for (self.attached_panes.items) |id| if (!bridge.detachPane(id)) return error.DetachPaneFailed;
        self.attached_panes.clearRetainingCapacity();
    }

    fn isAttached(self: *const Application, id: u64) bool {
        return std.mem.indexOfScalar(u64, self.attached_panes.items, id) != null;
    }

    const PresentationWriter = struct {
        application: *Application,
        bridge: *chrome.Bridge,
        output: []chrome.LayoutNode,
        index: usize = 0,

        pub fn leaf(self: *PresentationWriter, id: u64) !void {
            const view = try self.application.ensureView(id);
            if (!self.application.isAttached(id)) {
                if (!self.bridge.attachPane(
                    id,
                    view.hwnd,
                    view.swapChain(),
                    view.cellWidth(),
                    view.cellHeight(),
                    view.minimumWidth(),
                    view.minimumHeight(),
                    view.widthForColumns(self.application.settings.initial_columns),
                    view.heightForRows(self.application.settings.initial_rows),
                )) return error.AttachPaneFailed;
                self.application.attached_panes.appendAssumeCapacity(id);
            }
            self.output[self.index] = .{
                .size = @sizeOf(chrome.LayoutNode),
                .kind = chrome.layout_leaf,
                .id = id,
                .axis = 0,
                .ratio = 0,
                .subtree_size = 1,
                .reserved = 0,
            };
            self.index += 1;
        }

        pub fn split(self: *PresentationWriter, id: u64, axis: pane_tree.Axis, ratio: u16) usize {
            const index = self.index;
            self.output[index] = .{
                .size = @sizeOf(chrome.LayoutNode),
                .kind = chrome.layout_split,
                .id = id,
                .axis = switch (axis) {
                    .left_right => chrome.axis_left_right,
                    .top_bottom => chrome.axis_top_bottom,
                },
                .ratio = ratio,
                .subtree_size = 0,
                .reserved = 0,
            };
            self.index += 1;
            return index;
        }

        pub fn finishSplit(self: *PresentationWriter, index: usize, subtree_size: u32) void {
            self.output[index].subtree_size = subtree_size;
        }
    };

    fn syncPresentation(self: *Application) !void {
        const bridge = if (self.chrome) |*value| value else return error.ChromeUnavailable;
        const tab = self.model.activeTab() orelse return;
        const node_count = tab.tree.nodeCount();
        const layout = try std.heap.page_allocator.alloc(chrome.LayoutNode, node_count);
        defer std.heap.page_allocator.free(layout);
        try self.attached_panes.ensureUnusedCapacity(std.heap.page_allocator, node_count);
        errdefer self.detachPresentation() catch {};
        var writer = PresentationWriter{ .application = self, .bridge = bridge, .output = layout };
        try tab.tree.writePreorder(&writer);
        const focused = (self.model.activePane() orelse return).id;
        if (!bridge.updateLayout(layout, focused)) return error.UpdateLayoutFailed;
        var attached_index = self.attached_panes.items.len;
        while (attached_index != 0) {
            attached_index -= 1;
            const id = self.attached_panes.items[attached_index];
            var present = false;
            for (layout) |item| {
                if (item.kind == chrome.layout_leaf and item.id == id) {
                    present = true;
                    break;
                }
            }
            if (!present) {
                if (!bridge.detachPane(id)) return error.DetachPaneFailed;
                _ = self.attached_panes.swapRemove(attached_index);
            }
        }
        _ = bridge.focusPane(focused);
    }

    fn destroyView(self: *Application, id: u64) bool {
        for (self.views.items, 0..) |entry, index| if (entry.pane_id == id) {
            entry.view.resetInteraction();
            if (!entry.view.destroy()) return false;
            std.heap.page_allocator.destroy(entry.view);
            _ = self.views.swapRemove(index);
            return true;
        };
        return true;
    }

    fn destroyAllViews(self: *Application) void {
        while (self.views.items.len != 0) {
            if (!self.destroyView(self.views.items[self.views.items.len - 1].pane_id)) return;
        }
    }

    fn reloadViews(self: *Application, font: win.HFONT, settings: config.Config, size: u16, dpi: u32) !void {
        const prepared = try std.heap.page_allocator.alloc(TerminalView.PreparedReload, self.views.items.len);
        defer std.heap.page_allocator.free(prepared);
        var count: usize = 0;
        errdefer for (prepared[0..count]) |*value| value.deinit();
        for (self.views.items, 0..) |entry, index| {
            prepared[index] = try entry.view.prepareReload(font, settings.font_family, size, @intFromEnum(settings.font_weight), @intFromEnum(settings.intense_font_weight), dpi);
            count += 1;
        }
        try self.detachPresentation();
        for (self.views.items, prepared) |entry, value| entry.view.commitReload(value);
    }

    fn publishReloadedViews(self: *Application, operation: []const u8) void {
        self.syncPresentation() catch |err| {
            if (self.hwnd) |hwnd| _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
            log.err("unable to republish {s}: {}", .{ operation, err });
        };
    }
};

pub fn main(init: std.process.Init) !void {
    var launch_plan = try launchPlanFromArgsAlloc(std.heap.page_allocator, init.minimal.args);
    errdefer launch_plan.deinit();
    var loaded = try config.loadOrCreate(std.heap.page_allocator, init.io);
    const themes = theme.Catalog.load(std.heap.page_allocator, init.io);
    const application = std.heap.page_allocator.create(Application) catch |err| {
        loaded.deinit();
        return err;
    };
    application.* = Application.init(init.io, loaded, themes, launch_plan);
    launch_plan.actions = .empty;
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
        paneEvent,
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
    self.refresh_hwnd.store(@intFromPtr(hwnd), .release);
    self.model.setRefresh(.{ .callback = requestRuntimeRefresh, .context = self });
    self.terminal_ready = true;
    try self.syncProfiles(&self.settings);
    self.applyLaunchPlan() catch |err| {
        const profile = self.launchFailureProfile();
        if (!self.implicitDefaultLaunch() or !self.openFallbackProfile(profile, err)) {
            self.showProfileLaunchError(profile, err);
        }
    };
    if (win.PostMessageW(hwnd, initial_chrome_message, 0, 0) == 0) return error.PostInitialChromeUpdateFailed;
    self.updateTheme(false);
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
        self.refresh_hwnd.store(0, .release);
        self.model.setRefresh(.{});
        _ = win.RemoveWindowSubclass(hwnd, windowSubclassProc, window_subclass_id);
        self.window_subclassed = false;
        self.hwnd = null;
        if (self.chrome) |*bridge| bridge.detach();
    }
    return result;
}

fn shutdownWindowImpl(self: *Application) void {
    const hwnd = self.hwnd orelse return;
    self.refresh_hwnd.store(0, .release);
    self.model.setRefresh(.{});
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
        runtime_refresh_message => {
            self.refresh_pending.store(false, .release);
            const activity_changed = self.model.refreshTabActivity();
            for (self.views.items) |entry| entry.view.refresh();
            if (activity_changed) self.syncChrome();
            return 0;
        },
        ime_bounds_changed_message => {
            const pane_id: u64 = @intCast(wparam);
            const view = self.viewFor(pane_id) orelse return 0;
            const bounds = view.imeBounds() orelse return 0;
            if (self.chrome) |*bridge| _ = bridge.updateImeBounds(pane_id, bounds);
            return 0;
        },
        search_status_changed_message => {
            const pane_id = std.math.cast(u64, wparam) orelse return 0;
            const view = self.viewFor(pane_id) orelse return 0;
            const status = view.searchStatus() orelse return 0;
            if (self.chrome) |*bridge| _ = bridge.updateFind(pane_id, status.matches, status.active, status.scanning);
            return 0;
        },
        pane_event_message => {
            while (self.takePaneEvent()) |current| {
                if (current.size != @sizeOf(chrome.PaneEvent) or current.reserved != 0) continue;
                switch (current.kind) {
                    chrome.pane_scroll => if (self.isAttached(current.target_id)) if (self.viewFor(current.target_id)) |view| view.scrollTo(current.value),
                    chrome.pane_scroll_wheel => if (self.isAttached(current.target_id)) if (self.viewFor(current.target_id)) |view| view.handleMouseWheelDelta(@bitCast(current.value)),
                    chrome.pane_focus => {
                        if (!self.isAttached(current.target_id)) continue;
                        const active = self.model.activePane() orelse continue;
                        const tab = self.model.activeTab() orelse continue;
                        if (active.id != current.target_id and tab.tree.focus(current.target_id)) {
                            self.syncChrome();
                            self.syncScrollbar(false);
                            self.syncTaskbarProgress();
                        }
                    },
                    chrome.pane_committed_ratio => {
                        if (current.value == 0 or current.value >= 65535) continue;
                        _ = self.model.setSplitRatio(current.target_id, @truncate(current.value));
                    },
                    chrome.pane_find_next => if (self.viewFor(current.target_id)) |view| view.navigateSearch(true),
                    chrome.pane_find_previous => if (self.viewFor(current.target_id)) |view| view.navigateSearch(false),
                    chrome.pane_find_close => if (self.viewFor(current.target_id)) |view| view.cancelSearch(),
                    else => {},
                }
            }
            return 0;
        },
        chrome_message => {
            const command_value = std.math.cast(u32, wparam) orelse return 0;
            const command = chrome.commandFromInt(command_value) orelse return 0;
            const argument = std.math.cast(u32, lparam) orelse return 0;
            switch (command) {
                .new_profile => {
                    if (argument >= @as(u32, @intCast(self.settings.profile_count))) return 0;
                    const profile = self.settings.profiles[argument];
                    self.addProfile(profile) catch |err| self.showProfileLaunchError(profile, err);
                },
                .new_default => {
                    const profile = self.settings.defaultProfile();
                    self.addDefaultSession() catch |err| self.showProfileLaunchError(profile, err);
                    return 0;
                },
                .new_window => {
                    self.spawnNewWindow() catch |err| log.err("unable to open new window: {}", .{err});
                    return 0;
                },
                .pipe_command_output => {
                    self.pipeCommandOutput() catch |err| log.err("unable to process last command output: {}", .{err});
                    return 0;
                },
                .find => {
                    const pane = self.model.activePane() orelse return 0;
                    const view = self.viewFor(pane.id) orelse return 0;
                    if (self.chrome) |*bridge| if (bridge.showFind(pane.id)) view.beginSearch();
                    return 0;
                },
                .close => {
                    self.detachPresentation() catch |err| {
                        log.err("unable to detach panes before close: {}", .{err});
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    };
                    if (argument < self.model.tabs.items.len) {
                        for (self.model.tabs.items[argument].panes.items) |pane| if (!self.destroyView(pane.id)) {
                            _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                            return 0;
                        };
                    }
                    self.model.closeTab(argument);
                    if (self.model.tabCount() == 0) {
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    }
                    self.syncPresentation() catch |err| log.err("unable to present active panes: {}", .{err});
                },
                .duplicate_tab => {
                    if (argument >= self.model.tabs.items.len) return 0;
                    const pane = self.model.tabs.items[argument].focusedPane() orelse return 0;
                    const session = &pane.session;
                    const reported_directory = if (session.runtime) |runtime|
                        runtime.currentDirectoryAlloc(std.heap.page_allocator) catch null
                    else
                        null;
                    defer if (reported_directory) |directory| std.heap.page_allocator.free(directory);
                    const columns: u16 = if (self.activeView()) |view| view.columns else 80;
                    const rows: u16 = if (self.activeView()) |view| view.rows else 24;
                    _ = self.model.addSession(
                        session.shell,
                        session.profileTitle(),
                        session.command(),
                        reported_directory orelse session.workingDirectory(),
                        session.hold_on_exit,
                        columns,
                        rows,
                    ) catch |err| {
                        log.err("unable to duplicate tab: {}", .{err});
                        return 0;
                    };
                    self.syncPresentation() catch |err| log.err("unable to present duplicated tab: {}", .{err});
                },
                .close_other_tabs, .close_tabs_right => {
                    if (argument >= self.model.tabs.items.len) return 0;
                    if (self.activeView()) |view| view.resetInteraction();
                    self.detachPresentation() catch return 0;
                    var index = self.model.tabs.items.len;
                    while (index > 0) {
                        index -= 1;
                        const should_close = if (command == .close_other_tabs) index != argument else index > argument;
                        if (!should_close) continue;
                        for (self.model.tabs.items[index].panes.items) |pane_to_close| if (!self.destroyView(pane_to_close.id)) {
                            _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                            return 0;
                        };
                        self.model.closeTab(index);
                    }
                    self.model.activateTab(@min(@as(usize, argument), self.model.tabs.items.len - 1));
                    self.syncPresentation() catch |err| log.err("unable to present remaining tabs: {}", .{err});
                },
                .reorder_tab => {
                    const from: usize = argument >> 16;
                    const to: usize = argument & 0xffff;
                    if (from >= self.model.tabs.items.len or to >= self.model.tabs.items.len or from == to) return 0;
                    if (self.activeView()) |view| view.resetInteraction();
                    self.detachPresentation() catch return 0;
                    self.model.moveTab(from, to) catch |err| {
                        log.err("unable to reorder tab: {}", .{err});
                        return 0;
                    };
                    self.syncPresentation() catch |err| log.err("unable to present reordered tabs: {}", .{err});
                },
                .split_right, .split_down => {
                    if (self.activeView()) |view| view.resetInteraction();
                    _ = self.model.splitFocused(if (command == .split_right) .left_right else .top_bottom) catch |err| {
                        log.err("unable to split focused pane: {}", .{err});
                        return 0;
                    };
                    self.syncPresentation() catch |err| {
                        log.err("unable to present split panes: {}", .{err});
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    };
                },
                .focus_left, .focus_right, .focus_up, .focus_down => {
                    const changed = self.model.focusDirection(switch (command) {
                        .focus_left => .left,
                        .focus_right => .right,
                        .focus_up => .up,
                        .focus_down => .down,
                        else => unreachable,
                    });
                    if (!changed) return 0;
                    const pane = self.model.activePane() orelse return 0;
                    if (self.chrome) |*bridge| _ = bridge.focusPane(pane.id);
                    self.syncChrome();
                    self.syncScrollbar(false);
                    self.syncTaskbarProgress();
                    return 0;
                },
                .close_pane => {
                    const pane_id = (self.model.activePane() orelse return 0).id;
                    const bridge = if (self.chrome) |*value| value else return 0;
                    if (!bridge.detachPane(pane_id)) {
                        log.err("unable to detach focused pane before close", .{});
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    }
                    if (std.mem.indexOfScalar(u64, self.attached_panes.items, pane_id)) |index| _ = self.attached_panes.swapRemove(index);
                    var removed = self.model.extractFocusedPane() orelse return 0;
                    if (!self.destroyView(removed.pane_id)) {
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    }
                    self.model.destroyRemovedPane(&removed);
                    if (self.model.tabCount() == 0) {
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    }
                    self.syncPresentation() catch |err| {
                        log.err("unable to present panes after close: {}", .{err});
                        _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                        return 0;
                    };
                },
                .select => {
                    if (self.activeView()) |view| view.resetInteraction();
                    self.detachPresentation() catch return 0;
                    self.model.activateTab(argument);
                    self.syncPresentation() catch |err| log.err("unable to present active panes: {}", .{err});
                },
                .open_settings => {
                    self.openSettingsPage() catch |err| log.err("unable to open settings: {}", .{err});
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
                    if (self.activeView()) |view| view.scrollTo(argument);
                    return 0;
                },
                .scroll_wheel => {
                    if (self.activeView()) |view| view.handleMouseWheelDelta(@bitCast(argument));
                    return 0;
                },
                .notification_activate => {
                    if (self.activeView()) |view| view.resetInteraction();
                    self.detachPresentation() catch return 0;
                    if (!self.model.activateSessionId(argument)) return 0;
                    self.syncPresentation() catch |err| log.err("unable to present active panes: {}", .{err});
                    if (self.activeView()) |view| {
                        view.syncSessions();
                        view.invalidate();
                    }
                    self.syncChrome();
                    _ = win.ShowWindow(hwnd, win.SW_RESTORE);
                    _ = win.SetForegroundWindow(hwnd);
                    if (self.chrome) |*bridge| {
                        if (self.model.activePane()) |pane| _ = bridge.focusPane(pane.id);
                    }
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
                    if (self.activeView()) |view| view.resetInteraction();
                    self.detachPresentation() catch return 0;
                    const next = if (command == .select_previous) (active + count - 1) % count else (active + 1) % count;
                    self.model.activateTab(next);
                    self.syncPresentation() catch |err| log.err("unable to present active panes: {}", .{err});
                },
                .shutdown => return 0,
            }
            for (self.views.items) |entry| entry.view.syncSessions();
            _ = win.InvalidateRect(hwnd, null, 0);
            for (self.views.items) |entry| entry.view.invalidate();
            self.syncChrome();
            return 0;
        },
        titles_changed_message => {
            if (self.model.syncTitles()) self.syncChrome();
            return 0;
        },
        initial_chrome_message => {
            self.syncChrome();
            return 0;
        },
        shell_exited_message => {
            self.detachPresentation() catch |err| {
                log.err("unable to detach panes before exited-session cleanup: {}", .{err});
                _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                return 0;
            };
            var changed = false;
            while (self.model.extractCleanlyExitedPane()) |removed_value| {
                var removed = removed_value;
                if (!self.destroyView(removed.pane_id)) {
                    // The pane is already extracted; retain its runtime forever rather
                    // than let a native child callback observe freed session state.
                    _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                    return 0;
                }
                self.model.destroyRemovedPane(&removed);
                changed = true;
            }
            if (!changed) {
                self.syncPresentation() catch |err| log.err("unable to present active panes: {}", .{err});
                return 0;
            }
            if (self.model.tabCount() == 0) {
                _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
                return 0;
            }
            self.syncPresentation() catch |err| log.err("unable to present active panes: {}", .{err});
            if (self.activeView()) |view| {
                view.syncSessions();
                view.invalidate();
            }
            self.syncChrome();
            return 0;
        },
        scrollbar_changed_message => {
            const source_id: u64 = @bitCast(lparam);
            if (!self.isAttached(source_id) or (self.model.activePane() orelse return 0).id != source_id) return 0;
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
        win.WM_CLOSE => {
            if (!confirmCloseTabs(hwnd, self.model.tabCount())) return 0;
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        win.WM_DPICHANGED => {
            const new_dpi: u32 = @intCast(wparam & 0xffff);
            const new_font = createFont(self.settings.font_family, self.zoomed_font_size, self.settings.font_weight, new_dpi);
            if (new_font != null) {
                self.reloadViews(new_font, self.settings, self.zoomed_font_size, new_dpi) catch |err| {
                    log.err("unable to reload renderers for DPI change: {}", .{err});
                    _ = win.DeleteObject(new_font);
                    return win.DefSubclassProc(hwnd, message, wparam, lparam);
                };
                const old_font = self.font;
                self.font = new_font;
                self.dpi = new_dpi;
                _ = win.DeleteObject(old_font);
                self.publishReloadedViews("renderers after DPI change");
                _ = win.InvalidateRect(hwnd, null, 0);
            }
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        win.WM_SETTINGCHANGE => {
            for (self.views.items) |entry| entry.view.refreshTextRenderingSettings();
            self.updateTheme(false);
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        win.WM_DROPFILES => {
            if (self.activeView()) |view| return win.SendMessageW(view.hwnd, message, wparam, lparam);
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        win.WM_THEMECHANGED, win.WM_SYSCOLORCHANGE => {
            self.updateTheme(false);
            return win.DefSubclassProc(hwnd, message, wparam, lparam);
        },
        else => return win.DefSubclassProc(hwnd, message, wparam, lparam),
    }
}

fn confirmCloseTabs(hwnd: win.HWND, tab_count: usize) bool {
    if (tab_count <= 1) return true;
    var text_bytes: [192]u8 = undefined;
    const text = std.fmt.bufPrint(
        &text_bytes,
        "This window has {d} open tabs. Closing the window will close all of them.\n\nClose anyway?",
        .{tab_count},
    ) catch return false;
    var wide: [192:0]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&wide, text) catch return false;
    wide[length] = 0;
    return win.MessageBoxW(
        hwnd,
        &wide,
        std.unicode.utf8ToUtf16LeStringLiteral("Close multiple tabs?"),
        win.MB_OKCANCEL | win.MB_ICONWARNING | win.MB_DEFBUTTON2,
    ) == win.IDOK;
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
    self.chrome_colors.ensureTotalCapacity(std.heap.page_allocator, count) catch |err| {
        log.err("unable to allocate chrome colors: {}", .{err});
        return;
    };
    self.chrome_activity.ensureTotalCapacity(std.heap.page_allocator, count) catch |err| {
        log.err("unable to allocate chrome activity states: {}", .{err});
        return;
    };
    self.chrome_titles.items.len = count;
    self.chrome_title_lengths.items.len = count;
    self.chrome_colors.items.len = count;
    self.chrome_activity.items.len = count;
    for (self.model.tabs.items, 0..) |*tab, index| {
        const title = tab.displayTitle();
        if (title.len > std.math.maxInt(i32)) {
            log.err("terminal title exceeds the WinUI bridge limit", .{});
            _ = win.PostMessageW(self.hwnd.?, win.WM_CLOSE, 0, 0);
            return;
        }
        self.chrome_titles.items[index] = title.ptr;
        self.chrome_title_lengths.items[index] = @intCast(title.len);
        const color = if (tab.focusedPane()) |pane| theme.randomAccent(pane.session.background_seed) else self.model.terminal_theme.background;
        self.chrome_colors.items[index] = @as(u32, color.red) << 16 |
            @as(u32, color.green) << 8 |
            color.blue;
        self.chrome_activity.items[index] = @intFromBool(tab.has_unread_output);
    }
    if (!bridge.update(self.chrome_titles.items, self.chrome_title_lengths.items, self.chrome_colors.items, self.chrome_activity.items, self.model.activeTabIndex(), self.settings.randomize_tab_background)) {
        _ = win.PostMessageW(self.hwnd.?, win.WM_CLOSE, 0, 0);
        return;
    }
    self.syncScrollbar(false);
    self.syncTaskbarProgress();
}

fn syncScrollbarImpl(self: *Application, show: bool) void {
    const bridge = if (self.chrome) |*value| value else return;
    const active = self.model.activePane() orelse return;
    const state = (self.viewFor(active.id) orelse return).scrollbar();
    const limit = std.math.maxInt(u32);
    if (!bridge.updateScrollbar(
        active.id,
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
            const title = if (notification.title().len > 0) notification.title() else session.displayTitle();
            if (!std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(notification.body())) continue;
            _ = bridge.showNotification(session.id, title, notification.body());
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

fn paneEvent(context: ?*anyopaque, source: *const chrome.PaneEvent) callconv(.c) void {
    const self: *Application = @ptrCast(@alignCast(context orelse return));
    const hwnd = self.hwnd orelse return;
    if (source.size >= @sizeOf(chrome.PaneEvent) and
        (source.kind == chrome.pane_ime_preedit or source.kind == chrome.pane_ime_commit or
            source.kind == chrome.pane_ime_clear or source.kind == chrome.pane_find_query))
    {
        const view = self.viewFor(source.target_id) orelse return;
        const text: []const u16 = if (source.text_length == 0) &.{} else if (source.text) |ptr| ptr[0..source.text_length] else return;
        switch (source.kind) {
            chrome.pane_ime_preedit => view.setImePreedit(text, source.selection_start, source.selection_length),
            chrome.pane_ime_commit => view.commitIme(text),
            chrome.pane_ime_clear => view.clearImePreedit(),
            chrome.pane_find_query => view.setSearchQuery(text),
            else => unreachable,
        }
        if (source.kind != chrome.pane_find_query) if (view.imeBounds()) |bounds| {
            if (self.chrome) |*bridge| _ = bridge.updateImeBounds(source.target_id, bounds);
        };
        return;
    }
    self.pane_events_mutex.lock();
    self.pane_events.append(std.heap.page_allocator, source.*) catch {
        self.pane_events_mutex.unlock();
        return;
    };
    self.pane_events_mutex.unlock();
    _ = win.PostMessageW(hwnd, pane_event_message, 0, 0);
}

fn requestRuntimeRefresh(context: ?*anyopaque) void {
    const self: *Application = @ptrCast(@alignCast(context orelse return));
    if (self.refresh_pending.swap(true, .acq_rel)) return;
    const value = self.refresh_hwnd.load(.acquire);
    if (value == 0 or win.PostMessageW(win32.handleFromInt(win.HWND, value), runtime_refresh_message, 0, 0) == 0)
        self.refresh_pending.store(false, .release);
}

fn addDefaultSessionImpl(self: *Application) !void {
    try self.addProfile(self.settings.defaultProfile());
    if (self.activeView()) |view| {
        view.syncSessions();
        view.invalidate();
    }
    self.syncChrome();
}

fn applyLaunchPlanImpl(self: *Application) !void {
    for (self.launch_plan.actions.items) |action| {
        const profile = self.profileNamed(action.profile) orelse return error.UnknownProfile;
        const directory = action.working_directory orelse profile.working_directory;
        switch (action.kind) {
            .new_tab => try self.addProfileAt(profile, directory),
            .split_right, .split_down => {
                if (self.activeView()) |view| view.resetInteraction();
                _ = try self.model.splitFocusedSession(
                    if (action.kind == .split_right) .left_right else .top_bottom,
                    profile.shell,
                    profile.name,
                    profile.command,
                    directory,
                    self.settings.hold_on_exit,
                );
                try self.syncPresentation();
            },
        }
    }
}

fn profileNamedImpl(self: *Application, name: ?[]const u8) ?config.Profile {
    if (name == null) return self.settings.defaultProfile();
    for (self.settings.profileSlice()) |profile| {
        if (std.ascii.eqlIgnoreCase(profile.name, name.?)) return profile;
    }
    return null;
}

fn addProfileImpl(self: *Application, profile: config.Profile) !void {
    const reported_directory = if (self.model.activeSession()) |session|
        if (session.runtime) |runtime| runtime.currentDirectoryAlloc(std.heap.page_allocator) catch null else null
    else
        null;
    defer if (reported_directory) |directory| std.heap.page_allocator.free(directory);
    const working_directory = if (profile.working_directory.len > 0) profile.working_directory else reported_directory orelse "";
    try self.addProfileAt(profile, working_directory);
}

fn addProfileAtImpl(self: *Application, profile: config.Profile, working_directory: []const u8) !void {
    if (self.activeView()) |view| view.resetInteraction();
    const columns: u16 = if (self.activeView()) |view| view.columns else 80;
    const rows: u16 = if (self.activeView()) |view| view.rows else 24;
    _ = try self.model.addSession(profile.shell, profile.name, profile.command, working_directory, self.settings.hold_on_exit, columns, rows);
    try self.syncPresentation();
}

fn openFallbackProfileImpl(self: *Application, failed: config.Profile, launch_error: anyerror) bool {
    for (self.settings.profileSlice()) |profile| {
        if (std.ascii.eqlIgnoreCase(profile.command, failed.command) or
            !std.ascii.eqlIgnoreCase(profile.command, "cmd.exe")) continue;
        self.addProfile(profile) catch return false;
        self.showProfileFallback(failed, profile, launch_error);
        return true;
    }
    return false;
}

fn showProfileFallbackImpl(self: *Application, failed: config.Profile, fallback: config.Profile, launch_error: anyerror) void {
    const hwnd = self.hwnd orelse return;
    var bytes: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &bytes,
        "Zigonaut couldn't start the default profile \"{s}\" ({s}).\n\n{s} was opened instead. Review the command in Settings.\n\nDetails: {}",
        .{ failed.name, failed.command, fallback.name, launch_error },
    ) catch return;
    _ = showUtf8Message(hwnd, text, "Default profile unavailable", win.MB_OK | win.MB_ICONWARNING);
}

fn showProfileLaunchErrorImpl(self: *Application, profile: config.Profile, launch_error: anyerror) void {
    log.err("unable to open profile {s}: {}", .{ profile.name, launch_error });
    const hwnd = self.hwnd orelse return;
    var bytes: [512]u8 = undefined;
    const text = std.fmt.bufPrint(
        &bytes,
        "Zigonaut couldn't start \"{s}\".\n\nCommand: {s}\nDetails: {}\n\nOpen profile settings?",
        .{ profile.name, profile.command, launch_error },
    ) catch return;
    if (showUtf8Message(hwnd, text, "Profile unavailable", win.MB_YESNO | win.MB_ICONERROR | win.MB_DEFBUTTON2) == win.IDYES) {
        self.openSettingsPage() catch |err| log.err("unable to open settings after profile failure: {}", .{err});
    }
}

fn showUtf8Message(hwnd: win.HWND, text: []const u8, title: []const u8, style: win.UINT) c_int {
    var wide_text: [512:0]u16 = undefined;
    const text_length = std.unicode.utf8ToUtf16Le(&wide_text, text) catch return 0;
    wide_text[text_length] = 0;
    var wide_title: [128:0]u16 = undefined;
    const title_length = std.unicode.utf8ToUtf16Le(&wide_title, title) catch return 0;
    wide_title[title_length] = 0;
    return win.MessageBoxW(hwnd, &wide_text, &wide_title, style);
}

fn spawnNewWindowImpl(self: *Application) !void {
    const allocator = std.heap.page_allocator;
    const executable = try std.process.executablePathAlloc(self.io, allocator);
    defer allocator.free(executable);
    const directory = if (self.model.activeSession()) |session|
        if (session.runtime) |runtime| try runtime.currentDirectoryAlloc(allocator) else null
    else
        null;
    defer if (directory) |value| allocator.free(value);

    const argv: []const []const u8 = if (directory) |value|
        &.{ executable, "--working-directory", value }
    else
        &.{executable};
    process_spawn_mutex.lock();
    defer process_spawn_mutex.unlock();
    const child = try std.process.spawn(self.io, .{ .argv = argv });
    std.os.windows.CloseHandle(child.thread_handle);
    std.os.windows.CloseHandle(child.id.?);
}

fn pipeCommandOutputImpl(self: *Application) !void {
    if (self.settings.pipe_command_output.len == 0) {
        const view = self.activeView() orelse return;
        return view.copyLastCommandOutput();
    }
    const runtime = (self.model.activeSession() orelse return).runtime orelse return;
    const output = try runtime.lastCommandOutputAlloc(std.heap.page_allocator) orelse return;
    errdefer std.heap.page_allocator.free(output);
    const directory = try runtime.currentDirectoryAlloc(std.heap.page_allocator);
    errdefer if (directory) |value| std.heap.page_allocator.free(value);
    try PipeCommandTask.spawn(self.settings.pipe_command_output, output, directory);
}

const PipeCommandTask = struct {
    command: []u8,
    output: []u8,
    directory: ?[]u8,

    fn spawn(command: []const u8, output: []u8, directory: ?[]u8) !void {
        const allocator = std.heap.page_allocator;
        const task = try allocator.create(PipeCommandTask);
        errdefer allocator.destroy(task);
        task.* = .{
            .command = try allocator.dupe(u8, command),
            .output = output,
            .directory = directory,
        };
        errdefer allocator.free(task.command);
        const thread = try std.Thread.spawn(.{}, run, .{task});
        thread.detach();
    }

    fn run(self: *PipeCommandTask) void {
        const allocator = std.heap.page_allocator;
        defer {
            allocator.free(self.command);
            allocator.free(self.output);
            if (self.directory) |directory| allocator.free(directory);
            allocator.destroy(self);
        }

        runPipeCommand(allocator, self.command, self.output, self.directory) catch |err| {
            log.err("unable to start pipe_command_output: {}", .{err});
        };
    }
};

fn runPipeCommand(allocator: std.mem.Allocator, command: []const u8, output: []const u8, directory: ?[]const u8) !void {
    process_spawn_mutex.lock();
    var spawn_locked = true;
    defer if (spawn_locked) process_spawn_mutex.unlock();

    var stdin_read: win.HANDLE = null;
    var stdin_write: win.HANDLE = null;
    var security = win.SECURITY_ATTRIBUTES{
        .nLength = @sizeOf(win.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = win.TRUE,
    };
    if (win.CreatePipe(&stdin_read, &stdin_write, &security, 0) == 0) return error.CreatePipeFailed;
    defer {
        if (stdin_read != null) _ = win.CloseHandle(stdin_read);
        if (stdin_write != null) _ = win.CloseHandle(stdin_write);
    }
    if (win.SetHandleInformation(stdin_write, win.HANDLE_FLAG_INHERIT, 0) == 0) return error.SetHandleInformationFailed;

    const nul_name = std.unicode.utf8ToUtf16LeStringLiteral("NUL");
    var nul = win.CreateFileW(
        nul_name,
        win.GENERIC_READ | win.GENERIC_WRITE,
        win.FILE_SHARE_READ | win.FILE_SHARE_WRITE,
        &security,
        win.OPEN_EXISTING,
        win.FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (nul == win.INVALID_HANDLE_VALUE) return error.OpenNullDeviceFailed;
    defer {
        if (nul != null) _ = win.CloseHandle(nul);
    }

    var attribute_bytes: usize = 0;
    _ = win.InitializeProcThreadAttributeList(null, 1, 0, &attribute_bytes);
    const attribute_memory = win.HeapAlloc(win.GetProcessHeap(), 0, attribute_bytes) orelse return error.OutOfMemory;
    defer _ = win.HeapFree(win.GetProcessHeap(), 0, attribute_memory);
    const attributes: win.LPPROC_THREAD_ATTRIBUTE_LIST = @ptrCast(attribute_memory);
    if (win.InitializeProcThreadAttributeList(attributes, 1, 0, &attribute_bytes) == 0) return error.InitializeAttributeListFailed;
    defer win.DeleteProcThreadAttributeList(attributes);
    var inherited_handles = [_]win.HANDLE{ stdin_read, nul };
    if (win.UpdateProcThreadAttribute(
        attributes,
        0,
        win.PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        @ptrCast(&inherited_handles),
        @sizeOf(@TypeOf(inherited_handles)),
        null,
        null,
    ) == 0) return error.UpdateAttributeListFailed;

    var system_directory: [win.MAX_PATH]u16 = undefined;
    const system_length = win.GetSystemDirectoryW(&system_directory, system_directory.len);
    if (system_length == 0 or system_length >= system_directory.len - "\\cmd.exe".len) return error.SystemDirectoryUnavailable;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\cmd.exe");
    @memcpy(system_directory[system_length..][0..suffix.len], suffix);
    system_directory[system_length + suffix.len] = 0;
    const application_name: [*:0]const u16 = @ptrCast(&system_directory);

    var command_line = std.ArrayList(u16).empty;
    defer command_line.deinit(allocator);
    try command_line.appendSlice(allocator, std.unicode.utf8ToUtf16LeStringLiteral("cmd.exe /d /s /c \""));
    const wide_command = try std.unicode.utf8ToUtf16LeAlloc(allocator, command);
    defer allocator.free(wide_command);
    try command_line.appendSlice(allocator, wide_command);
    try command_line.appendSlice(allocator, &.{ '"', 0 });

    const current_directory = if (directory) |value| try std.unicode.utf8ToUtf16LeAllocZ(allocator, value) else null;
    defer if (current_directory) |value| allocator.free(value);
    var startup: win.STARTUPINFOEXW = std.mem.zeroes(win.STARTUPINFOEXW);
    startup.StartupInfo.cb = @sizeOf(win.STARTUPINFOEXW);
    startup.StartupInfo.dwFlags = win.STARTF_USESTDHANDLES;
    startup.StartupInfo.hStdInput = stdin_read;
    startup.StartupInfo.hStdOutput = nul;
    startup.StartupInfo.hStdError = nul;
    startup.lpAttributeList = attributes;
    var process: win.PROCESS_INFORMATION = std.mem.zeroes(win.PROCESS_INFORMATION);
    if (win.CreateProcessW(
        application_name,
        @ptrCast(command_line.items.ptr),
        null,
        null,
        win.TRUE,
        win.EXTENDED_STARTUPINFO_PRESENT | win.CREATE_NO_WINDOW,
        null,
        if (current_directory) |value| value.ptr else null,
        &startup.StartupInfo,
        &process,
    ) == 0) return error.CreateProcessFailed;
    _ = win.CloseHandle(process.hThread);
    stdin_read = null;
    _ = win.CloseHandle(inherited_handles[0]);
    nul = null;
    _ = win.CloseHandle(inherited_handles[1]);
    process_spawn_mutex.unlock();
    spawn_locked = false;

    var offset: usize = 0;
    while (offset < output.len) {
        var written: win.DWORD = 0;
        if (win.WriteFile(stdin_write, output[offset..].ptr, @intCast(output.len - offset), &written, null) == 0 or written == 0) break;
        offset += written;
    }
    _ = win.CloseHandle(stdin_write);
    stdin_write = null;
    _ = win.WaitForSingleObject(process.hProcess, win.INFINITE);
    _ = win.CloseHandle(process.hProcess);
}

fn launchPlanFromArgsAlloc(allocator: std.mem.Allocator, args: std.process.Args) !LaunchPlan {
    var iterator = try std.process.Args.Iterator.initAllocator(args, allocator);
    defer iterator.deinit();
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    while (iterator.next()) |argument| try arguments.append(allocator, argument);
    return launchPlanFromArgumentsAlloc(allocator, arguments.items);
}

fn launchPlanFromArgumentsAlloc(allocator: std.mem.Allocator, arguments: []const []const u8) !LaunchPlan {
    var result = LaunchPlan{ .allocator = allocator };
    errdefer result.deinit();
    if (arguments.len <= 1) {
        try result.actions.append(allocator, .{});
        return result;
    }

    var index: usize = 1;
    while (index < arguments.len) {
        var action = LaunchAction{};
        errdefer action.deinit(allocator);
        var split_command = false;
        if (isNewTabCommand(arguments[index])) {
            index += 1;
        } else if (isSplitCommand(arguments[index])) {
            action.kind = .split_right;
            split_command = true;
            index += 1;
        }

        var direction_set = false;
        while (index < arguments.len and !std.mem.eql(u8, arguments[index], ";")) {
            const argument = arguments[index];
            if (std.mem.eql(u8, argument, "-p") or std.mem.eql(u8, argument, "--profile")) {
                index += 1;
                if (index >= arguments.len or std.mem.eql(u8, arguments[index], ";")) return error.MissingProfile;
                const replacement = try allocator.dupe(u8, arguments[index]);
                if (action.profile) |value| allocator.free(value);
                action.profile = replacement;
            } else if (std.mem.eql(u8, argument, "-d") or std.mem.eql(u8, argument, "--startingDirectory") or std.mem.eql(u8, argument, "--working-directory")) {
                index += 1;
                if (index >= arguments.len or std.mem.eql(u8, arguments[index], ";")) return error.MissingWorkingDirectory;
                if (!isValidLaunchDirectory(arguments[index])) return error.InvalidWorkingDirectory;
                const replacement = try allocator.dupe(u8, arguments[index]);
                if (action.working_directory) |value| allocator.free(value);
                action.working_directory = replacement;
            } else if (std.mem.eql(u8, argument, "-H") or std.mem.eql(u8, argument, "--horizontal")) {
                if (!split_command or direction_set) return error.InvalidSplitDirection;
                action.kind = .split_down;
                direction_set = true;
            } else if (std.mem.eql(u8, argument, "-V") or std.mem.eql(u8, argument, "--vertical")) {
                if (!split_command or direction_set) return error.InvalidSplitDirection;
                action.kind = .split_right;
                direction_set = true;
            } else {
                return error.UnknownLaunchArgument;
            }
            index += 1;
        }
        try result.actions.append(allocator, action);
        action = .{};
        if (index < arguments.len) {
            index += 1;
            if (index == arguments.len) return error.EmptyLaunchCommand;
        }
    }
    if (result.actions.items[0].kind != .new_tab) try result.actions.insert(allocator, 0, .{});
    return result;
}

fn isNewTabCommand(argument: []const u8) bool {
    return std.mem.eql(u8, argument, "new-tab") or std.mem.eql(u8, argument, "nt");
}

fn isSplitCommand(argument: []const u8) bool {
    return std.mem.eql(u8, argument, "split-pane") or std.mem.eql(u8, argument, "sp");
}

fn isValidLaunchDirectory(path: []const u8) bool {
    return path.len > 0 and std.mem.indexOfScalar(u8, path, 0) == null and std.unicode.utf8ValidateSlice(path);
}

test "launch arguments create tabs and splits with Windows Terminal aliases" {
    const allocator = std.testing.allocator;
    const arguments = [_][]const u8{
        "zigonaut.exe", "new-tab", "-p", "PowerShell", "-d", "C:\\work", ";",
        "sp", "-H", "--profile", "Command Prompt", ";", "split-pane", "-V", "--startingDirectory", ".",
    };
    var plan = try launchPlanFromArgumentsAlloc(allocator, &arguments);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 3), plan.actions.items.len);
    try std.testing.expectEqual(LaunchKind.new_tab, plan.actions.items[0].kind);
    try std.testing.expectEqualStrings("PowerShell", plan.actions.items[0].profile.?);
    try std.testing.expectEqualStrings("C:\\work", plan.actions.items[0].working_directory.?);
    try std.testing.expectEqual(LaunchKind.split_down, plan.actions.items[1].kind);
    try std.testing.expectEqualStrings("Command Prompt", plan.actions.items[1].profile.?);
    try std.testing.expectEqual(LaunchKind.split_right, plan.actions.items[2].kind);
    try std.testing.expectEqualStrings(".", plan.actions.items[2].working_directory.?);
}

test "launch arguments validate values and command boundaries" {
    const allocator = std.testing.allocator;
    const defaults = [_][]const u8{"zigonaut.exe"};
    var default_plan = try launchPlanFromArgumentsAlloc(allocator, &defaults);
    defer default_plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), default_plan.actions.items.len);

    const missing = [_][]const u8{ "zigonaut.exe", "--working-directory" };
    try std.testing.expectError(error.MissingWorkingDirectory, launchPlanFromArgumentsAlloc(allocator, &missing));

    const invalid = [_][]const u8{ "zigonaut.exe", "--working-directory", "bad\x00path" };
    try std.testing.expectError(error.InvalidWorkingDirectory, launchPlanFromArgumentsAlloc(allocator, &invalid));

    const unknown = [_][]const u8{ "zigonaut.exe", "--not-an-option" };
    try std.testing.expectError(error.UnknownLaunchArgument, launchPlanFromArgumentsAlloc(allocator, &unknown));

    const invalid_direction = [_][]const u8{ "zigonaut.exe", "new-tab", "-H" };
    try std.testing.expectError(error.InvalidSplitDirection, launchPlanFromArgumentsAlloc(allocator, &invalid_direction));

    const initial_split = [_][]const u8{ "zigonaut.exe", "sp", "-p", "WSL" };
    var split_plan = try launchPlanFromArgumentsAlloc(allocator, &initial_split);
    defer split_plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), split_plan.actions.items.len);
    try std.testing.expectEqual(LaunchKind.new_tab, split_plan.actions.items[0].kind);
    try std.testing.expectEqual(LaunchKind.split_right, split_plan.actions.items[1].kind);
    try std.testing.expectEqualStrings("WSL", split_plan.actions.items[1].profile.?);
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
    return createFont(value.font_family, value.font_size, value.font_weight, dpi);
}

fn createFont(font_family: []const u8, font_size: u16, font_weight: config.FontWeight, dpi: u32) win.HFONT {
    var wide_name = std.mem.zeroes([128]u16);
    _ = std.unicode.utf8ToUtf16Le(wide_name[0 .. wide_name.len - 1], font_family) catch 0;
    return win.CreateFontW(
        -scaled(font_size, dpi),
        0,
        0,
        0,
        @intFromEnum(font_weight),
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

fn openSettingsPageImpl(self: *Application) !void {
    const path = try config.pathAlloc(std.heap.page_allocator);
    defer std.heap.page_allocator.free(path);
    const bridge = if (self.chrome) |*value| value else return error.ChromeUnavailable;
    if (!bridge.showSettings(path, self.loaded.contents)) return error.OpenSettingsFailed;
}

fn reloadSettingsImpl(self: *Application) !void {
    var replacement = try config.loadOrCreate(std.heap.page_allocator, self.io);
    var replacement_owned = true;
    errdefer if (replacement_owned) replacement.deinit();

    const next = replacement.value;
    const changed = config.changes(self.settings, next);
    const padding_changed = self.settings.padding_horizontal != next.padding_horizontal or
        self.settings.padding_vertical != next.padding_vertical;
    const new_font = if (changed.font) createFontFor(next, self.dpi) else null;
    if (changed.font and new_font == null) return error.CreateFontFailed;
    var new_font_owned = new_font != null;
    errdefer {
        if (new_font_owned) _ = win.DeleteObject(new_font);
    }
    var profiles_committed = false;
    errdefer {
        if (!profiles_committed) self.syncProfiles(&self.settings) catch {
            if (self.hwnd) |hwnd| _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
        };
    }
    try self.syncProfiles(&next);
    if (new_font != null) {
        try self.reloadViews(new_font, next, next.font_size, self.dpi);
    } else if (padding_changed) {
        try self.detachPresentation();
    }

    const old_font = self.font;
    if (new_font != null) {
        self.font = new_font;
        self.zoomed_font_size = next.font_size;
        new_font_owned = false;
    }
    var previous = self.loaded;
    self.loaded = replacement;
    self.settings = self.loaded.value;
    replacement_owned = false;
    profiles_committed = true;
    previous.deinit();

    if (changed.theme) self.themes = theme.Catalog.load(std.heap.page_allocator, self.io);
    self.model.applyClipboardWriteSettings(self.settings.osc52_clipboard_write, self.settings.osc52_clipboard_max_bytes);
    self.model.setDefaultScrollbackSize(self.settings.scrollback_size);
    for (self.views.items) |entry| entry.view.updatePadding(self.settings.padding_horizontal, self.settings.padding_vertical);
    self.updateTheme(changed.theme);
    if (new_font != null) _ = win.DeleteObject(old_font);
    for (self.views.items) |entry| entry.view.invalidate();
    if (changed.font or padding_changed) self.publishReloadedViews("views after settings reload");
}

fn scaled(value: anytype, dpi: u32) i32 {
    return win.MulDiv(@intCast(value), @intCast(dpi), 96);
}

fn updateThemeImpl(self: *Application, terminal_theme_changed: bool) void {
    const hwnd = self.hwnd orelse return;
    const previous_dark_theme = self.dark_theme;
    self.dark_theme = config.useDarkTheme(self.settings, appsUseDarkTheme());
    self.high_contrast = highContrastEnabled();
    const update_terminal_theme = self.terminal_ready and (terminal_theme_changed or previous_dark_theme != self.dark_theme);
    if (update_terminal_theme) self.model.applySettings(config.terminalTheme(self.settings, &self.themes, self.dark_theme), self.settings.randomize_tab_background);
    if (self.terminal_ready) for (self.views.items) |entry| entry.view.updateTheme(self.dark_theme, self.high_contrast, self.settings.background_opacity);
    if (self.chrome) |*bridge| _ = bridge.updateAppearance(@intFromEnum(self.settings.backdrop), self.high_contrast, self.dark_theme);
    if (update_terminal_theme) self.syncChrome();
    var dark_mode: win.BOOL = @intFromBool(self.dark_theme and !self.high_contrast);
    _ = win.DwmSetWindowAttribute(hwnd, 20, &dark_mode, @sizeOf(win.BOOL));
    _ = win.InvalidateRect(hwnd, null, 0);
}

fn setZoomedFontSizeImpl(self: *Application, size: u16) void {
    if (size == self.zoomed_font_size) return;
    const new_font = createFont(self.settings.font_family, size, self.settings.font_weight, self.dpi);
    if (new_font == null) return;
    self.reloadViews(new_font, self.settings, size, self.dpi) catch {
        _ = win.DeleteObject(new_font);
        return;
    };
    _ = win.DeleteObject(self.font);
    self.font = new_font;
    self.zoomed_font_size = size;
    self.publishReloadedViews("renderers after zoom change");
}

fn attachTerminalRendererImpl(self: *Application) bool {
    self.syncPresentation() catch return false;
    return true;
}

fn detachTerminalRendererImpl(self: *Application) void {
    self.detachPresentation() catch {};
}

fn recoverTerminalRendererImpl(self: *Application) void {
    const new_font = createFont(self.settings.font_family, self.zoomed_font_size, self.settings.font_weight, self.dpi);
    if (new_font == null) {
        log.err("unable to recreate the terminal font after a renderer failure", .{});
        return;
    }
    self.reloadViews(new_font, self.settings, self.zoomed_font_size, self.dpi) catch |err| {
        _ = win.DeleteObject(new_font);
        log.err("unable to recover the terminal renderer: {}", .{err});
        return;
    };
    _ = win.DeleteObject(self.font);
    self.font = new_font;
    self.publishReloadedViews("renderers after recovery");
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
