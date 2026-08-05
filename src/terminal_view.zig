const std = @import("std");
const app_model = @import("app.zig");
const App = app_model.App;
const pane_tree = @import("pane_tree.zig");
const SessionRuntime = @import("session.zig").SessionRuntime;
const Terminal = @import("terminal.zig").Terminal;
const TextEngine = @import("directwrite_renderer.zig").Engine;
const GdiRenderer = @import("gdi_renderer.zig");
const config = @import("config.zig");
const input = @import("input.zig");
const search = @import("search.zig");
const shell_quote = @import("shell_quote.zig");
const theme = @import("theme.zig");
const SearchMatch = search.Match;

const win32 = @import("win32.zig");
const win = win32.c;
const log = std.log.scoped(.terminal_view);
const encodeUtf16 = GdiRenderer.encodeUtf16;
const paddedRect = GdiRenderer.paddedRect;
const colorRef = GdiRenderer.colorRef;
const rgb = GdiRenderer.rgb;
const translucentColorRef = GdiRenderer.translucentColorRef;
const blendColorRef = GdiRenderer.blendColorRef;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautTerminalView");
const render_message = win.WM_APP + 2;
const refresh_timer = 1;
const copy_flash_timer = 2;
const selection_scroll_timer = 3;
const synchronized_output_timer = 4;
const present_retry_timer = 5;
const search_refresh_interval_ms = 33;
const search_time_budget_ns = 2 * std.time.ns_per_ms;
const copy_flash_duration_ms = 150;
const wheel_rows = 3;
const minimum_columns = 10;
const minimum_rows = 4;

fn notifyAutomation(hwnd: win.HWND, changes: u32) void {
    const module = win.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("Zigonaut.WinUI.Bridge.dll")) orelse return;
    const address = win.GetProcAddress(module, "zigonaut_terminal_automation_notify") orelse return;
    const notify: *const fn (win.HWND, u32) callconv(.c) void = @ptrCast(address);
    notify(hwnd, changes);
}

const ContextMenuCommand = enum(u32) {
    copy = 1,
    paste,
    find,
    split_right,
    split_down,
    close_pane,
};

fn frameWaitCallback(context: ?*anyopaque, _: win.BOOLEAN) callconv(.winapi) void {
    const view: *View = @ptrCast(@alignCast(context orelse return));
    const epoch = view.frame_epoch.load(.acquire);
    _ = win.PostMessageW(view.hwnd, render_message, epoch, 0);
}

fn accessibilityText(context: ?*anyopaque, kind: u32, output: [*c]u16, capacity: u32) callconv(.c) u32 {
    const self: *View = @ptrCast(@alignCast(context orelse return 0));
    const session = self.boundSession() orelse return 0;
    const allocator = std.heap.page_allocator;
    const utf8 = if (kind == win.ZIGONAUT_ACCESSIBLE_NAME)
        std.fmt.allocPrint(allocator, "Terminal pane: {s}", .{session.displayTitle()}) catch return 0
    else value: {
        const runtime = session.runtime orelse return 0;
        if (runtime.selectedTextAlloc(allocator) catch null) |selected| {
            if (selected.len != 0) break :value selected;
            allocator.free(selected);
        }
        const buffer = allocator.alloc(u8, @as(usize, self.columns) * @as(usize, self.rows) * 64 + self.rows) catch return 0;
        const visible = runtime.writeViewportText(buffer) catch {
            allocator.free(buffer);
            return 0;
        };
        const copy = allocator.dupe(u8, visible) catch {
            allocator.free(buffer);
            return 0;
        };
        allocator.free(buffer);
        break :value copy;
    };
    defer allocator.free(utf8);
    const needed = std.unicode.calcUtf16LeLen(utf8) catch return 0;
    if (output != null and capacity >= needed) _ = std.unicode.utf8ToUtf16Le(output[0..capacity], utf8) catch return 0;
    return std.math.cast(u32, needed) orelse 0;
}

const AccessibilitySnapshotWriter = struct {
    query: *win.zigonaut_accessibility_snapshot,
    offset: u32 = 0,
    run_count: u32 = 0,
    selection_start: ?u32 = null,
    selection_end: u32 = 0,
    current_row: u16 = 0,
    fingerprint: u64 = 14695981039346656037,
    cursor_has_position: bool = false,
    cursor_x: u16 = 0,
    cursor_y: u16 = 0,

    fn hash(self: *@This(), bytes: []const u8) void {
        for (bytes) |byte| {
            self.fingerprint = (self.fingerprint ^ byte) *% 1099511628211;
        }
    }
    fn hashValue(self: *@This(), value: anytype) void {
        self.hash(std.mem.asBytes(&value));
    }

    pub fn searchState(_: *@This(), _: bool, _: []const u8, _: []const SearchMatch, _: ?usize, _: usize, _: bool) void {}
    pub fn beginFrame(self: *@This(), frame: Terminal.Frame) void {
        self.cursor_has_position = frame.cursor_has_position;
        self.cursor_x = frame.cursor_x;
        self.cursor_y = frame.cursor_y;
        self.hashValue(frame.cursor_has_position);
        self.hashValue(frame.cursor_x);
        self.hashValue(frame.cursor_y);
    }
    pub fn beginRow(self: *@This(), y: u16) void {
        self.current_row = y;
        if (y != 0) self.scalar('\n');
    }
    fn scalar(self: *@This(), cp: u32) void {
        if (cp <= 0xffff and !(cp >= 0xd800 and cp <= 0xdfff)) {
            if (self.offset < self.query.text_capacity and self.query.text != null) self.query.text[self.offset] = @intCast(cp);
            self.offset += 1;
            self.hashValue(@as(u16, @intCast(cp)));
        } else if (cp <= 0x10ffff) {
            const v = cp - 0x10000;
            if (self.offset + 1 < self.query.text_capacity and self.query.text != null) {
                self.query.text[self.offset] = @intCast(0xd800 + (v >> 10));
                self.query.text[self.offset + 1] = @intCast(0xdc00 + (v & 0x3ff));
            }
            self.offset += 2;
            self.hashValue(@as(u16, @intCast(0xd800 + (v >> 10))));
            self.hashValue(@as(u16, @intCast(0xdc00 + (v & 0x3ff))));
        }
    }
    pub fn drawCell(self: *@This(), cell: Terminal.Cell) void {
        if (cell.occupancy == .wide_tail) return;
        const start = self.offset;
        if (cell.codepoints.len == 0) self.scalar(' ') else for (cell.codepoints) |cp| self.scalar(cp);
        if (self.cursor_has_position and cell.x == self.cursor_x and self.current_row == self.cursor_y) self.query.caret = start;
        if (self.run_count < self.query.run_capacity and self.query.runs != null) self.query.runs[self.run_count] = .{
            .start = start,
            .end = self.offset,
            .row = self.current_row,
            .column = cell.x,
            .columns = if (cell.occupancy == .wide) 2 else 1,
            .reserved = 0,
        };
        self.run_count += 1;
        self.hashValue(start);
        self.hashValue(self.offset);
        self.hashValue(cell.x);
        self.hashValue(self.current_row);
        if (cell.selected) {
            if (self.selection_start == null) self.selection_start = start;
            self.selection_end = self.offset;
        }
    }
    pub fn endRow(_: *@This(), _: u16) void {}
    pub fn drawImage(_: *@This(), _: Terminal.Image) void {}
    pub fn endFrame(self: *@This(), frame: Terminal.Frame) void {
        self.query.caret_valid = @intFromBool(self.cursor_has_position);
        _ = frame;
        self.query.selection_active = @intFromBool(self.selection_start != null);
        self.query.selection_start = self.selection_start orelse 0;
        self.query.selection_end = if (self.selection_start != null) self.selection_end else 0;
        self.query.text_required = self.offset;
        self.query.run_required = self.run_count;
        self.hashValue(self.query.caret);
        self.hashValue(self.query.caret_valid);
        self.hashValue(self.query.selection_start);
        self.hashValue(self.query.selection_end);
        self.hashValue(self.query.selection_active);
        self.hashValue(self.query.grid_left);
        self.hashValue(self.query.grid_top);
        self.hashValue(self.query.cell_width);
        self.hashValue(self.query.cell_height);
        self.hashValue(self.query.rows);
        self.hashValue(self.query.columns);
        self.query.fingerprint = self.fingerprint;
    }
};

fn accessibilitySnapshot(view: *View, query: *win.zigonaut_accessibility_snapshot) bool {
    if (query.size != @sizeOf(win.zigonaut_accessibility_snapshot) or (query.text == null and query.text_capacity != 0) or (query.runs == null and query.run_capacity != 0)) return false;
    const session = view.boundSession() orelse return false;
    const runtime = session.runtime orelse return false;
    var client: win.RECT = undefined;
    if (win.GetClientRect(view.hwnd, &client) == 0) return false;
    const geometry = view.gridGeometry(client);
    var origin = win.POINT{ .x = geometry.left, .y = geometry.top };
    _ = win.ClientToScreen(view.hwnd, &origin);
    query.grid_left = origin.x;
    query.grid_top = origin.y;
    query.cell_width = view.cell_width;
    query.cell_height = view.cell_height;
    query.rows = view.rows;
    query.columns = view.columns;
    query.owner = @intFromPtr(view);
    var writer = AccessibilitySnapshotWriter{ .query = query };
    runtime.replayPreparedViewport(&writer);
    return true;
}

fn accessibilitySelect(view: *View, action: *const win.zigonaut_accessibility_action) bool {
    if (action.size != @sizeOf(win.zigonaut_accessibility_action) or action.kind != win.ZIGONAUT_ACCESSIBILITY_SELECT or action.owner != @intFromPtr(view)) return false;
    var snapshot = std.mem.zeroes(win.zigonaut_accessibility_snapshot);
    snapshot.size = @sizeOf(win.zigonaut_accessibility_snapshot);
    snapshot.kind = win.ZIGONAUT_ACCESSIBLE_TEXT_SNAPSHOT;
    if (!accessibilitySnapshot(view, &snapshot) or snapshot.fingerprint != action.expected_fingerprint) return false;
    if (action.start > action.end or action.end > snapshot.text_required) return false;
    const runtime = (view.boundSession() orelse return false).runtime orelse return false;
    if (action.start == action.end) {
        runtime.setSelection(null) catch return false;
        view.selection = null;
        view.invalidate();
        return true;
    }
    const runs = std.heap.page_allocator.alloc(win.zigonaut_accessibility_run, snapshot.run_required) catch return false;
    defer std.heap.page_allocator.free(runs);
    snapshot.runs = runs.ptr;
    snapshot.run_capacity = @intCast(runs.len);
    if (!accessibilitySnapshot(view, &snapshot) or snapshot.fingerprint != action.expected_fingerprint) return false;
    var first: ?win.zigonaut_accessibility_run = null;
    var last: ?win.zigonaut_accessibility_run = null;
    for (runs) |run| {
        if (run.end > action.start and run.start < action.end) {
            if (first == null) first = run;
            last = run;
        }
    }
    const begin = first orelse return false;
    const finish = last.?;
    const selection = Terminal.Selection{ .anchor = .{ .x = begin.column, .y = begin.row }, .focus = .{ .x = finish.column, .y = finish.row } };
    runtime.setSelection(selection) catch return false;
    view.selection = .{ .runtime = runtime, .dragging = false, .moved = true, .unit = .cell, .focus = selection.focus };
    view.invalidate();
    return true;
}

pub const View = struct {
    hwnd: win.HWND = null,
    render_dirty: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    full_rebuild_required: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    frame_wait_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    frame_wait: win.HANDLE = null,
    frame_epoch: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    present_pending: bool = false,
    resize_render_pending: bool = false,
    scene_has_images: bool = false,
    renderer_failed: bool = false,
    refresh_interval_ms: u32 = 0,
    model: *App,
    pane_id: ?pane_tree.PaneId = null,
    font: win.HFONT,
    text_engine: ?TextEngine,
    input_state: input.State = .{},
    key_runtimes: [std.enums.values(Terminal.Key).len]?*SessionRuntime = @splat(null),
    cell_width: u32,
    cell_height: u32,
    columns: u16 = 0,
    rows: u16 = 0,
    focused: bool = false,
    dark_theme: bool = true,
    high_contrast: bool = false,
    gdi_renderer: GdiRenderer.Owner = .{},
    last_runtime: ?*SessionRuntime = null,
    last_content_generation: u64 = 0,
    last_progress_runtime: ?*SessionRuntime = null,
    last_progress_generation: u64 = 0,
    last_titles_generation: u64 = 0,
    selection: ?MouseSelection = null,
    hovered_link: ?HoveredLink = null,
    titles_changed_message: win.UINT,
    shell_exited_message: win.UINT,
    scrollbar_changed_message: win.UINT,
    progress_changed_message: win.UINT,
    notification_changed_message: win.UINT,
    renderer_failed_message: win.UINT,
    ime_bounds_changed_message: win.UINT,
    search_status_changed_message: win.UINT,
    chrome_message: win.UINT,
    wheel_remainder: i32 = 0,
    protocol_wheel_remainder: i32 = 0,
    protocol_hwheel_remainder: i32 = 0,
    protocol_button: ?Terminal.MouseButton = null,
    protocol_runtime: ?*SessionRuntime = null,
    last_click_tick: u64 = 0,
    click_count: u2 = 0,
    last_click_point: ?Terminal.Point = null,
    suppressed_search_character: ?u16 = null,
    consumed_prompt_key: ?win.WPARAM = null,
    consumed_application_key: ?win.WPARAM = null,
    suppress_application_character: bool = false,
    copy_flash: bool = false,
    padding_horizontal: u16,
    padding_vertical: u16,
    balance_padding: bool = false,
    padding_color: config.PaddingColor = .background,
    background_opacity: u8,
    ime_preedit: std.ArrayList(u16) = .empty,
    ime_selection_start: u32 = 0,
    ime_selection_length: u32 = 0,
    ime_anchor_x: u16 = 0,
    ime_anchor_y: u16 = 0,
    ime_caret_x: i32 = 0,
    ime_caret_y: i32 = 0,
    ime_target_search: ?bool = null,

    pub fn registerClass(instance: win.HINSTANCE, cursor: win.HCURSOR) !void {
        const window_class = win.WNDCLASSEXW{
            .cbSize = @sizeOf(win.WNDCLASSEXW),
            .style = win.CS_HREDRAW | win.CS_VREDRAW | win.CS_DBLCLKS,
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
        if (win.RegisterClassExW(&window_class) == 0) return error.RegisterTerminalViewClassFailed;
    }

    pub fn init(
        parent: win.HWND,
        model: *App,
        font: win.HFONT,
        font_family: []const u8,
        font_size: u16,
        font_weight: u16,
        intense_font_weight: u16,
        text_antialiasing: u32,
        dpi: u32,
        padding_horizontal: u16,
        padding_vertical: u16,
        padding_balance: config.PaddingBalance,
        padding_color: config.PaddingColor,
        background_opacity: u8,
        titles_changed_message: win.UINT,
        shell_exited_message: win.UINT,
        scrollbar_changed_message: win.UINT,
        progress_changed_message: win.UINT,
        notification_changed_message: win.UINT,
        renderer_failed_message: win.UINT,
        ime_bounds_changed_message: win.UINT,
        search_status_changed_message: win.UINT,
        chrome_message: win.UINT,
    ) View {
        const text_engine = TextEngine.init(font_family, font_size, font_weight, intense_font_weight, dpi, text_antialiasing) catch null;
        const cell_size = if (text_engine) |engine| size: {
            const metrics = engine.metrics();
            break :size CellSize{ .width = metrics.width, .height = metrics.height };
        } else measureCell(parent, font);
        return .{
            .model = model,
            .font = font,
            .text_engine = text_engine,
            .cell_width = cell_size.width,
            .cell_height = cell_size.height,
            .padding_horizontal = padding_horizontal,
            .padding_vertical = padding_vertical,
            .balance_padding = padding_balance == .equal,
            .padding_color = padding_color,
            .background_opacity = background_opacity,
            .titles_changed_message = titles_changed_message,
            .shell_exited_message = shell_exited_message,
            .scrollbar_changed_message = scrollbar_changed_message,
            .progress_changed_message = progress_changed_message,
            .notification_changed_message = notification_changed_message,
            .renderer_failed_message = renderer_failed_message,
            .ime_bounds_changed_message = ime_bounds_changed_message,
            .search_status_changed_message = search_status_changed_message,
            .chrome_message = chrome_message,
        };
    }

    pub fn create(self: *View, parent: win.HWND, instance: win.HINSTANCE) !void {
        errdefer self.deinitResources();
        self.hwnd = win.CreateWindowExW(
            0,
            class_name,
            null,
            win.WS_CHILD | win.WS_CLIPSIBLINGS,
            0,
            0,
            1,
            1,
            parent,
            null,
            instance,
            self,
        ) orelse return error.CreateTerminalViewFailed;
        if (self.text_engine) |*engine| engine.setWindow(self.hwnd) catch |err| {
            log.warn("DirectWrite window initialization failed; using GDI fallback: {}", .{err});
            engine.deinit();
            self.text_engine = null;
        };
        win.DragAcceptFiles(self.hwnd, 1);
    }

    /// Destroys the child window synchronously, which releases renderer and
    /// swap-chain resources before the heap-stable View owner is freed.
    pub fn destroy(self: *View) bool {
        if (self.hwnd == null) return true;
        return win.DestroyWindow(self.hwnd) != 0;
    }

    fn deinitResources(self: *View) void {
        self.stopFrameScheduling();
        self.ime_preedit.deinit(std.heap.page_allocator);
        self.clearHoveredLink();
        self.gdi_renderer.release();
        if (self.text_engine) |*engine| engine.deinit();
        self.text_engine = null;
    }

    pub fn move(self: *View, x: i32, y: i32, width: i32, height: i32) void {
        _ = win.MoveWindow(self.hwnd, x, y, @max(width, 1), @max(height, 1), 1);
    }

    pub fn swapChain(self: *const View) ?*anyopaque {
        const engine = self.text_engine orelse return null;
        return engine.swapChain();
    }

    pub fn cellWidth(self: *const View) u32 {
        return self.cell_width;
    }

    pub fn cellHeight(self: *const View) u32 {
        return self.cell_height;
    }

    pub fn minimumWidth(self: *const View) u32 {
        const padding: u32 = @intCast(@max(scaled(@intCast(self.padding_horizontal), win.GetDpiForWindow(self.hwnd)), 0));
        return minimum_columns * self.cell_width + 2 * padding;
    }

    pub fn minimumHeight(self: *const View) u32 {
        const padding: u32 = @intCast(@max(scaled(@intCast(self.padding_vertical), win.GetDpiForWindow(self.hwnd)), 0));
        return minimum_rows * self.cell_height + 2 * padding;
    }

    pub fn widthForColumns(self: *const View, columns: u16) u32 {
        const padding: u32 = @intCast(@max(scaled(@intCast(self.padding_horizontal), win.GetDpiForWindow(self.hwnd)), 0));
        return @as(u32, columns) * self.cell_width + 2 * padding;
    }

    pub fn heightForRows(self: *const View, rows: u16) u32 {
        const padding: u32 = @intCast(@max(scaled(@intCast(self.padding_vertical), win.GetDpiForWindow(self.hwnd)), 0));
        return @as(u32, rows) * self.cell_height + 2 * padding;
    }

    pub fn updateFont(self: *View, font: win.HFONT, dpi: u32) void {
        self.font = font;
        if (self.text_engine) |*engine| engine.setDpi(dpi) catch |err| {
            log.warn("unable to update DirectWrite DPI: {}", .{err});
        };
        self.updateCellSize(font);
    }

    pub fn refreshTextRenderingSettings(self: *View) void {
        if (self.text_engine) |*engine| engine.refreshRenderingParams() catch |err| {
            log.warn("unable to refresh DirectWrite rendering settings: {}", .{err});
        };
        self.invalidate();
    }

    pub const PreparedReload = struct {
        engine: TextEngine,
        font: win.HFONT,

        pub fn deinit(self: *PreparedReload) void {
            self.engine.deinit();
        }
    };

    pub fn prepareReload(
        self: *View,
        font: win.HFONT,
        font_family: []const u8,
        font_size: u16,
        font_weight: u16,
        intense_font_weight: u16,
        text_antialiasing: u32,
        dpi: u32,
    ) !PreparedReload {
        var engine = try TextEngine.init(font_family, font_size, font_weight, intense_font_weight, dpi, text_antialiasing);
        errdefer engine.deinit();
        try engine.setWindow(self.hwnd);
        return .{ .engine = engine, .font = font };
    }

    pub fn commitReload(self: *View, prepared: PreparedReload) void {
        self.stopFrameScheduling();
        if (self.text_engine) |*engine| engine.deinit();
        self.text_engine = prepared.engine;
        self.renderer_failed = false;
        self.font = prepared.font;
        self.updateCellSize(prepared.font);
    }

    fn updateCellSize(self: *View, font: win.HFONT) void {
        const cell_size = if (self.text_engine) |engine| size: {
            const metrics = engine.metrics();
            break :size CellSize{ .width = metrics.width, .height = metrics.height };
        } else measureCell(self.hwnd, font);
        self.cell_width = cell_size.width;
        self.cell_height = cell_size.height;
        self.columns = 0;
        self.rows = 0;
        self.resizeSessions();
        self.invalidate();
    }

    pub fn syncSessions(self: *View) void {
        if (self.columns != 0 and self.rows != 0) {
            if (self.boundRuntime()) |runtime| runtime.resize(self.columns, self.rows, self.cell_width, self.cell_height);
        }
        self.refresh();
    }

    pub fn bindPane(self: *View, pane_id: ?pane_tree.PaneId) void {
        if (self.pane_id == pane_id) return;
        self.releasePressedKeys();
        self.resetInteraction();
        self.clearImePreedit();
        self.pane_id = pane_id;
        self.last_runtime = null;
        self.last_progress_runtime = null;
        self.last_content_generation = 0;
        self.last_progress_generation = 0;
        self.syncSessions();
        self.invalidate();
    }

    pub fn setImePreedit(self: *View, text: []const u16, selection_start: u32, selection_length: u32) void {
        if (self.ime_target_search == null) self.ime_target_search = false;
        self.ime_caret_x = 0;
        self.ime_caret_y = 0;
        self.ime_preedit.clearRetainingCapacity();
        self.ime_preedit.appendSlice(std.heap.page_allocator, text) catch {
            self.ime_preedit.clearRetainingCapacity();
        };
        self.ime_selection_start = @min(selection_start, @as(u32, @intCast(self.ime_preedit.items.len)));
        self.ime_selection_length = @min(selection_length, @as(u32, @intCast(self.ime_preedit.items.len)) - self.ime_selection_start);
        self.invalidate();
    }

    pub fn clearImePreedit(self: *View) void {
        self.ime_preedit.clearRetainingCapacity();
        self.ime_selection_start = 0;
        self.ime_selection_length = 0;
        self.ime_caret_x = 0;
        self.ime_caret_y = 0;
        self.ime_target_search = null;
        self.invalidate();
    }

    pub fn beginSearch(self: *View) void {
        const runtime = self.boundRuntime() orelse return;
        runtime.searchBegin();
        self.setRefreshInterval(search_refresh_interval_ms);
        self.notifySearchStatus();
        self.invalidate();
    }

    pub fn setSearchQuery(self: *View, text: []const u16) void {
        const runtime = self.boundRuntime() orelse return;
        const utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, text) catch return;
        defer std.heap.page_allocator.free(utf8);
        runtime.searchSet(utf8) catch return;
        self.setRefreshInterval(search_refresh_interval_ms);
        self.notifySearchStatus();
        self.invalidate();
    }

    pub fn cancelSearch(self: *View) void {
        const runtime = self.boundRuntime() orelse return;
        runtime.searchCancel();
        self.setRefreshInterval(0);
        self.notifyScrollbar(true);
        self.invalidate();
    }

    pub fn navigateSearch(self: *View, forward: bool) void {
        const runtime = self.boundRuntime() orelse return;
        _ = runtime.searchNavigate(forward);
        self.notifySearchStatus();
        self.notifyScrollbar(true);
        self.invalidate();
    }

    pub fn searchStatus(self: *View) ?SessionRuntime.SearchStatus {
        const runtime = self.boundRuntime() orelse return null;
        if (!runtime.searchEnabled()) return null;
        return runtime.searchStatus();
    }

    fn notifySearchStatus(self: *View) void {
        const pane_id = self.pane_id orelse return;
        if (self.hwnd != null) _ = win.PostMessageW(win.GetParent(self.hwnd), self.search_status_changed_message, @intCast(pane_id), 0);
    }

    pub fn commitIme(self: *View, text: []const u16) void {
        if (text.len == 0) return;
        const runtime = self.boundRuntime() orelse return;
        if (self.ime_target_search == null) return;
        const utf8 = std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, text) catch |err| {
            log.warn("dropping malformed TSF UTF-16 commit: {}", .{err});
            return;
        };
        defer std.heap.page_allocator.free(utf8);
        runtime.write(utf8) catch |err| log.debug("unable to write TSF commit: {}", .{err});
        self.scrollToBottom();
        self.invalidate();
    }

    pub fn imeBounds(self: *const View) ?win.zigonaut_ime_bounds {
        if (self.hwnd == null or self.ime_target_search == null) return null;
        var client: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &client) == 0 or client.right <= client.left or client.bottom <= client.top) return null;
        const geometry = self.gridGeometry(client);
        const targets_search = self.ime_target_search.?;
        const caret_x = if (self.ime_caret_x != 0) self.ime_caret_x else geometry.left + @as(i32, self.ime_anchor_x) * @as(i32, @intCast(self.cell_width));
        const caret_y = if (self.ime_caret_y != 0)
            self.ime_caret_y
        else if (targets_search)
            @max(client.top, geometry.gridBottom() - 2 * @as(i32, @intCast(self.cell_height)))
        else
            geometry.top + @as(i32, self.ime_anchor_y) * @as(i32, @intCast(self.cell_height));
        var caret_origin = win.POINT{ .x = std.math.clamp(caret_x, client.left, client.right - 1), .y = std.math.clamp(caret_y, client.top, client.bottom - 1) };
        var pane_origin = win.POINT{ .x = client.left, .y = client.top };
        var pane_end = win.POINT{ .x = client.right, .y = client.bottom };
        if (win.ClientToScreen(self.hwnd, &caret_origin) == 0 or
            win.ClientToScreen(self.hwnd, &pane_origin) == 0 or
            win.ClientToScreen(self.hwnd, &pane_end) == 0) return null;
        return .{
            .size = @sizeOf(win.zigonaut_ime_bounds),
            .left = caret_origin.x,
            .top = caret_origin.y,
            .right = @min(caret_origin.x + @as(i32, @intCast(@max(self.cell_width, 1))), pane_end.x),
            .bottom = @min(caret_origin.y + @as(i32, @intCast(@max(self.cell_height, 1))), pane_end.y),
            .pane_left = pane_origin.x,
            .pane_top = pane_origin.y,
            .pane_right = pane_end.x,
            .pane_bottom = pane_end.y,
        };
    }

    fn boundSession(self: *const View) ?*app_model.Session {
        return &(self.model.paneById(self.pane_id orelse return null) orelse return null).session;
    }

    fn boundRuntime(self: *const View) ?*SessionRuntime {
        return (self.boundSession() orelse return null).runtime;
    }

    /// Must be called before the model changes or destroys its active runtime.
    pub fn resetInteraction(self: *View) void {
        _ = win.KillTimer(self.hwnd, selection_scroll_timer);
        if (self.selection) |selection| {
            selection.runtime.setSelection(null) catch {};
            selection.runtime.endSelectionAnchor();
        }
        self.selection = null;
        if (self.protocol_runtime) |runtime| if (self.protocol_button) |button| {
            _ = self.sendMouseTo(runtime, .release, button, self.lastMouseClientPoint(), false);
        };
        self.protocol_button = null;
        self.protocol_runtime = null;
        self.clearHoveredLink();
        self.wheel_remainder = 0;
        self.protocol_wheel_remainder = 0;
        self.protocol_hwheel_remainder = 0;
        self.last_click_tick = 0;
        self.click_count = 0;
        self.last_click_point = null;
        self.consumed_application_key = null;
        self.suppress_application_character = false;
    }

    pub fn invalidate(self: *View) void {
        if (self.text_engine == null) {
            if (self.hwnd != null) _ = win.InvalidateRect(self.hwnd, null, 0);
            return;
        }
        self.full_rebuild_required.store(true, .release);
        self.invalidateContent();
    }

    /// Terminal generation refreshes may update only libghostty's dirty rows.
    fn invalidateContent(self: *View) void {
        if (self.text_engine == null) {
            if (self.hwnd != null) _ = win.InvalidateRect(self.hwnd, null, 0);
            return;
        }
        self.render_dirty.store(true, .release);
        self.armFrameWait();
    }

    fn armFrameWait(self: *View) void {
        if (self.hwnd == null or self.text_engine == null or self.renderer_failed or self.present_pending or
            self.frame_wait_pending.swap(true, .acq_rel)) return;
        const epoch = self.frame_epoch.load(.acquire);
        if (win.RegisterWaitForSingleObject(&self.frame_wait, self.text_engine.?.frameLatencyWaitableObject(), frameWaitCallback, self, win.INFINITE, win.WT_EXECUTEONLYONCE) == 0) {
            self.frame_wait_pending.store(false, .release);
            _ = win.PostMessageW(self.hwnd, render_message, epoch, 0);
        }
    }

    fn stopFrameScheduling(self: *View) void {
        _ = win.KillTimer(self.hwnd, present_retry_timer);
        self.clearFrameWait();
        _ = self.frame_epoch.fetchAdd(1, .acq_rel);
        self.present_pending = false;
        self.resize_render_pending = false;
        self.scene_has_images = false;
    }

    fn clearFrameWait(self: *View) void {
        if (self.frame_wait != null) {
            _ = win.UnregisterWaitEx(self.frame_wait, win32.handleFromInt(win.HANDLE, std.math.maxInt(usize)));
            self.frame_wait = null;
        }
        self.frame_wait_pending.store(false, .release);
    }

    /// A composition surface size change must not wait for the ordinary frame
    /// latency wakeup: WinUI has already committed the larger panel bounds. Draw
    /// the replacement frame in this WM_SIZE turn, like Ghostty's bounds-change
    /// display callback. If an older non-blocking Present is still queued, retain
    /// this request and run it immediately after that Present completes.
    fn renderResize(self: *View) void {
        self.full_rebuild_required.store(true, .release);
        self.render_dirty.store(true, .release);
        self.resize_render_pending = true;
        if (self.present_pending) {
            // DXGI_ERROR_WAS_STILL_DRAWING means the non-blocking Present was not
            // submitted. Do not present that obsolete-size frame before resizing.
            _ = win.KillTimer(self.hwnd, present_retry_timer);
            self.text_engine.?.abandonPendingPresent();
            self.present_pending = false;
        }
        self.paintPendingResize();
    }

    fn paintPendingResize(self: *View) void {
        if (!self.resize_render_pending or self.present_pending or self.text_engine == null or self.renderer_failed) return;
        self.clearFrameWait();
        if (!self.render_dirty.swap(false, .acq_rel)) return;
        if (self.paintSwapChain()) {
            self.resize_render_pending = false;
        } else {
            self.render_dirty.store(true, .release);
            self.armFrameWait();
        }
    }

    pub fn refresh(self: *View) void {
        self.refreshIfNeeded();
    }

    fn setRefreshInterval(self: *View, interval_ms: u32) void {
        if (self.refresh_interval_ms == interval_ms or self.hwnd == null) return;
        self.refresh_interval_ms = interval_ms;
        if (interval_ms == 0) {
            _ = win.KillTimer(self.hwnd, refresh_timer);
        } else {
            _ = win.SetTimer(self.hwnd, refresh_timer, interval_ms, null);
        }
    }

    fn deferSynchronizedOutput(self: *View) bool {
        const runtime = self.boundRuntime() orelse {
            _ = win.KillTimer(self.hwnd, synchronized_output_timer);
            return false;
        };
        const delay = runtime.synchronizedOutputDelay(win.GetTickCount64()) orelse {
            _ = win.KillTimer(self.hwnd, synchronized_output_timer);
            return false;
        };
        if (win.SetTimer(self.hwnd, synchronized_output_timer, @max(delay, 1), null) == 0) {
            // End synchronized output if the watchdog cannot run. Otherwise,
            // one terminal mode can suppress all later rendering.
            log.warn("unable to arm synchronized-output watchdog; releasing suppression", .{});
            runtime.forceEndSynchronizedOutput();
            return false;
        }
        return true;
    }

    fn prepareBoundRender(self: *View) bool {
        const runtime = self.boundRuntime() orelse return true;
        while (true) {
            const ready = runtime.prepareRender() catch |err| {
                log.warn("unable to prepare terminal render: {}", .{err});
                return false;
            };
            if (ready) return true;
            if (self.deferSynchronizedOutput()) return false;
        }
    }

    fn refreshIfNeeded(self: *View) void {
        if (self.model.hasCleanlyExitedSession()) {
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.shell_exited_message, 0, 0);
        }
        const titles_generation = self.model.titlesGeneration();
        if (titles_generation != self.last_titles_generation) {
            self.last_titles_generation = titles_generation;
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.titles_changed_message, 0, 0);
        }
        if (self.model.hasPendingNotification()) {
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.notification_changed_message, 0, 0);
        }
        const session = self.boundSession() orelse {
            self.setRefreshInterval(0);
            if (self.last_progress_runtime != null) {
                self.last_progress_runtime = null;
                _ = win.PostMessageW(win.GetParent(self.hwnd), self.progress_changed_message, 0, 0);
            }
            self.notifyScrollbar(false);
            return;
        };
        const runtime = session.runtime orelse {
            self.setRefreshInterval(0);
            return;
        };
        if (runtime.takeClipboardWrite()) |pending| {
            defer runtime.freeClipboardWrite(pending);
            const result = switch (pending) {
                .clear => clearClipboard(self.hwnd),
                .text => |text| setClipboardText(self.hwnd, text),
            };
            result catch |err| log.warn("unable to apply terminal clipboard write: {}", .{err});
        }
        const progress_generation = runtime.progressGeneration();
        if (runtime != self.last_progress_runtime or progress_generation != self.last_progress_generation) {
            self.last_progress_runtime = runtime;
            self.last_progress_generation = progress_generation;
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.progress_changed_message, 0, 0);
        }
        const search_tick = runtime.searchTick(search_time_budget_ns);
        self.setRefreshInterval(if (search_tick.scanning) search_refresh_interval_ms else 0);
        if (search_tick.changed) {
            self.notifySearchStatus();
            self.invalidate();
        }
        if (self.deferSynchronizedOutput()) return;
        const generation = runtime.contentGeneration();
        if (runtime == self.last_runtime and generation == self.last_content_generation) {
            if (self.render_dirty.load(.acquire)) self.armFrameWait();
            return;
        }
        self.clearHoveredLink();
        self.last_runtime = runtime;
        self.last_content_generation = generation;
        self.notifyScrollbar(false);
        self.invalidateContent();
    }

    pub fn updateTheme(self: *View, dark_theme: bool, high_contrast: bool, background_opacity: u8) void {
        self.dark_theme = dark_theme;
        self.high_contrast = high_contrast;
        self.background_opacity = background_opacity;
        self.invalidate();
    }

    pub fn updatePadding(self: *View, horizontal: u16, vertical: u16, balance: config.PaddingBalance, color: config.PaddingColor) void {
        const size_changed = self.padding_horizontal != horizontal or self.padding_vertical != vertical;
        const appearance_changed = self.balance_padding != (balance == .equal) or self.padding_color != color;
        if (!size_changed and !appearance_changed) return;
        self.padding_horizontal = horizontal;
        self.padding_vertical = vertical;
        self.balance_padding = balance == .equal;
        self.padding_color = color;
        self.full_rebuild_required.store(true, .release);
        if (size_changed) {
            self.columns = 0;
            self.rows = 0;
            self.resizeSessions();
        }
        self.invalidate();
    }

    fn gridGeometry(self: *const View, client: win.RECT) GridGeometry {
        const dpi = win.GetDpiForWindow(self.hwnd);
        return calculateGridGeometry(
            @max(client.right - client.left, 0),
            @max(client.bottom - client.top, 0),
            self.columns,
            self.rows,
            self.cell_width,
            self.cell_height,
            @max(scaled(@intCast(self.padding_horizontal), dpi), 0),
            @max(scaled(@intCast(self.padding_vertical), dpi), 0),
            self.balance_padding,
        );
    }

    fn resizeSessions(self: *View) void {
        var client: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &client) == 0) return;

        const padding_x = scaled(@intCast(self.padding_horizontal), win.GetDpiForWindow(self.hwnd));
        const padding_y = scaled(@intCast(self.padding_vertical), win.GetDpiForWindow(self.hwnd));
        const inner_width = @max(client.right - 2 * padding_x, 1);
        const inner_height = @max(client.bottom - 2 * padding_y, 1);
        const columns: u16 = @intCast(@min(@divTrunc(inner_width, @as(i32, @intCast(self.cell_width))), std.math.maxInt(u16)));
        const rows: u16 = @intCast(@min(@divTrunc(inner_height, @as(i32, @intCast(self.cell_height))), std.math.maxInt(u16)));
        const safe_columns = @max(columns, 1);
        const safe_rows = @max(rows, 1);
        if (self.columns == safe_columns and self.rows == safe_rows) return;

        self.columns = safe_columns;
        self.rows = safe_rows;
        self.syncSessions();
        self.notifyScrollbar(false);
    }

    pub fn scrollbar(self: *View) Terminal.Scrollbar {
        const session = self.boundSession() orelse return .{ .total = 0, .offset = 0, .len = 0 };
        const runtime = session.runtime orelse return .{ .total = 0, .offset = 0, .len = 0 };
        return runtime.scrollbar() catch .{ .total = 0, .offset = 0, .len = 0 };
    }

    pub fn notifyScrollbar(self: *View, show: bool) void {
        const pane_id = self.pane_id orelse return;
        _ = win.PostMessageW(
            win.GetParent(self.hwnd),
            self.scrollbar_changed_message,
            @intFromBool(show),
            @bitCast(pane_id),
        );
    }

    fn scrollViewport(self: *View, delta: isize) void {
        if (delta == 0) return;
        const session = self.boundSession() orelse return;
        session.runtime.?.scrollViewport(delta);
        self.notifyScrollbar(true);
        self.invalidate();
    }

    pub fn scrollTo(self: *View, requested: u32) void {
        const state = self.scrollbar();
        const target = @min(@as(usize, requested), state.total -| state.len);
        const delta: isize = if (target >= state.offset)
            @intCast(@min(target - state.offset, std.math.maxInt(isize)))
        else
            -@as(isize, @intCast(@min(state.offset - target, std.math.maxInt(isize))));
        self.scrollViewport(delta);
    }

    fn scrollToBottom(self: *View) void {
        const state = self.scrollbar();
        const bottom = state.total -| state.len;
        if (state.offset >= bottom) return;
        self.scrollViewport(@intCast(@min(bottom - state.offset, std.math.maxInt(isize))));
    }

    pub fn handleMouseWheelDelta(self: *View, delta: i32) void {
        self.wheel_remainder += delta;
        const row_delta = @divTrunc(self.wheel_remainder, @divExact(win.WHEEL_DELTA, wheel_rows));
        self.wheel_remainder -= row_delta * @divExact(win.WHEEL_DELTA, wheel_rows);
        self.scrollViewport(-@as(isize, row_delta));
    }

    fn handleMouseWheel(self: *View, wparam: usize, lparam: win.LPARAM) void {
        const raw_delta: u16 = @truncate(wparam >> 16);
        const delta: i32 = @as(i16, @bitCast(raw_delta));
        if (win.GetKeyState(win.VK_SHIFT) >= 0 and self.sendWheel(delta, false, screenLparamToClient(self.hwnd, lparam))) return;
        self.handleMouseWheelDelta(delta);
    }

    fn paint(self: *View) void {
        var ps: win.PAINTSTRUCT = undefined;
        const dc = win.BeginPaint(self.hwnd, &ps);
        defer _ = win.EndPaint(self.hwnd, &ps);

        var client: win.RECT = undefined;
        _ = win.GetClientRect(self.hwnd, &client);
        const width = client.right - client.left;
        const height = client.bottom - client.top;
        if (width <= 0 or height <= 0) return;

        if (self.text_engine != null) {
            self.invalidate();
            return;
        }
        if (!self.prepareBoundRender()) return;
        notifyAutomation(self.hwnd, win.ZIGONAUT_AUTOMATION_TEXT_CHANGED | win.ZIGONAUT_AUTOMATION_SELECTION_CHANGED);

        const geometry = self.gridGeometry(client);
        const session = self.boundSession();
        self.gdi_renderer.present(dc, client, .{
            .font = self.font,
            .foreground = self.model.terminal_theme.foreground,
            .background = self.activeBackground(),
            .background_opacity = self.background_opacity,
            .dark_theme = self.dark_theme,
            .runtime = if (session) |active| active.runtime else null,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .columns = self.columns,
            .rows = self.rows,
            .focused = self.focused,
            .high_contrast = self.high_contrast,
            .padding_color = self.padding_color,
            .origin_x = geometry.left,
            .origin_y = geometry.top,
            .hover_row = if (self.hovered_link) |hovered| hovered.link.row else null,
            .hover_start = if (self.hovered_link) |hovered| hovered.link.start_column else 0,
            .hover_end = if (self.hovered_link) |hovered| hovered.link.end_column else 0,
            .copy_flash = self.copy_flash,
        });
        if (self.ime_preedit.items.len != 0) {
            const left = geometry.left + @as(i32, self.ime_anchor_x) * @as(i32, @intCast(self.cell_width));
            const top = if (self.ime_target_search orelse false)
                geometry.gridBottom() - 2 * @as(i32, @intCast(self.cell_height))
            else
                geometry.top + @as(i32, self.ime_anchor_y) * @as(i32, @intCast(self.cell_height));
            const rect = win.RECT{ .left = left, .top = top, .right = client.right, .bottom = top + @as(i32, @intCast(self.cell_height)) };
            _ = win.SelectObject(dc, self.font);
            _ = win.SetTextColor(dc, if (self.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(self.model.terminal_theme.foreground));
            _ = win.SetBkColor(dc, if (self.high_contrast) win.GetSysColor(win.COLOR_WINDOW) else self.backgroundColorRef(self.activeBackground()));
            _ = win.SetBkMode(dc, win.OPAQUE);
            _ = win.ExtTextOutW(dc, left, top, win.ETO_CLIPPED | win.ETO_OPAQUE, &rect, self.ime_preedit.items.ptr, @intCast(self.ime_preedit.items.len), null);
            self.ime_caret_x = left + @as(i32, @intCast(self.ime_selection_start + self.ime_selection_length)) * @as(i32, @intCast(self.cell_width));
            self.ime_caret_y = top;
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.ime_bounds_changed_message, @intCast(self.pane_id orelse 0), 0);
        }
    }

    fn paintSwapChain(self: *View) bool {
        if (self.text_engine == null or self.renderer_failed or self.present_pending) return false;
        var client: win.RECT = undefined;
        _ = win.GetClientRect(self.hwnd, &client);
        const width = client.right - client.left;
        const height = client.bottom - client.top;
        if (width <= 0 or height <= 0) return false;
        if (!self.prepareBoundRender()) return false;
        notifyAutomation(self.hwnd, win.ZIGONAUT_AUTOMATION_TEXT_CHANGED | win.ZIGONAUT_AUTOMATION_SELECTION_CHANGED);
        const result = self.paintDirect2D(client, width, height) catch |err| {
            log.warn("terminal renderer failed: {}", .{err});
            self.renderer_failed = true;
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.renderer_failed_message, 0, 0);
            return true;
        };
        if (result == .retry) {
            self.present_pending = true;
            if (!self.armPresentRetry()) return true;
        } else if (self.render_dirty.load(.acquire)) self.armFrameWait();
        return true;
    }

    fn paintDirect2D(self: *View, client: win.RECT, width: i32, height: i32) !TextEngine.PresentResult {
        const background = if (self.high_contrast)
            win.GetSysColor(win.COLOR_WINDOW)
        else
            self.backgroundColorRef(self.activeBackground());
        const foreground = if (self.high_contrast)
            win.GetSysColor(win.COLOR_WINDOWTEXT)
        else
            colorRef(self.model.terminal_theme.foreground);
        const engine = &self.text_engine.?;
        var full_rebuild = self.full_rebuild_required.swap(false, .acq_rel);
        const current_has_images = if (self.boundRuntime()) |runtime| runtime.preparedViewportHasImages() else false;
        full_rebuild = full_rebuild or self.scene_has_images or current_has_images;
        const native_rebuilt = engine.beginFrame(@intCast(width), @intCast(height), background, full_rebuild) catch |err| {
            self.full_rebuild_required.store(true, .release);
            return err;
        };
        errdefer engine.abortFrame();
        full_rebuild = full_rebuild or native_rebuilt;

        const geometry = self.gridGeometry(client);
        if (self.boundSession()) |session| {
            var renderer = DirectWriteCellRenderer{
                .engine = engine,
                .view = self,
                .client = client,
                .origin_x = geometry.left,
                .origin_y = geometry.top,
                .background = background,
            };
            if (full_rebuild)
                session.runtime.?.replayPreparedViewport(&renderer)
            else
                session.runtime.?.replayPreparedViewportDirty(&renderer);
            if (renderer.draw_error) |err| return err;
            if (self.ime_preedit.items.len != 0) {
                const left: f32 = @floatFromInt(geometry.left + @as(i32, self.ime_anchor_x) * @as(i32, @intCast(self.cell_width)));
                const top: f32 = @floatFromInt(if (self.ime_target_search orelse false) geometry.gridBottom() - 2 * @as(i32, @intCast(self.cell_height)) else geometry.top + @as(i32, self.ime_anchor_y) * @as(i32, @intCast(self.cell_height)));
                self.ime_caret_x = @intFromFloat(engine.drawPreedit(self.ime_preedit.items, self.ime_selection_start + self.ime_selection_length, left, top, @floatFromInt(@max(client.right - @as(i32, @intFromFloat(left)), 1)), @floatFromInt(self.cell_height), foreground, background) orelse left);
                self.ime_caret_y = @intFromFloat(top);
            }
        } else {
            try drawDirectWriteMessage(
                engine,
                "Open a PowerShell or WSL session.",
                .{ .left = geometry.left, .top = geometry.top, .right = geometry.gridRight(), .bottom = geometry.gridBottom() },
                foreground,
                background,
            );
        }
        const result = try engine.endFrame();
        self.scene_has_images = current_has_images;
        if (self.ime_target_search != null) {
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.ime_bounds_changed_message, @intCast(self.pane_id orelse 0), 0);
        }
        return result;
    }

    fn retryPresent(self: *View) void {
        if (!self.present_pending or self.text_engine == null) return;
        _ = win.KillTimer(self.hwnd, present_retry_timer);
        const result = self.text_engine.?.retryPresent() catch |err| {
            log.warn("terminal renderer present retry failed: {}", .{err});
            self.renderer_failed = true;
            self.present_pending = false;
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.renderer_failed_message, 0, 0);
            return;
        };
        if (result == .retry) {
            _ = self.armPresentRetry();
            return;
        }
        self.present_pending = false;
        if (self.resize_render_pending) {
            self.paintPendingResize();
            return;
        }
        if (self.render_dirty.load(.acquire)) self.armFrameWait();
    }

    fn armPresentRetry(self: *View) bool {
        if (win.SetTimer(self.hwnd, present_retry_timer, 1, null) != 0) return true;
        log.warn("unable to schedule terminal presentation retry", .{});
        self.renderer_failed = true;
        self.present_pending = false;
        _ = win.PostMessageW(win.GetParent(self.hwnd), self.renderer_failed_message, 0, 0);
        return false;
    }

    fn backgroundColorRef(self: *const View, color: theme.Color) win.COLORREF {
        return translucentColorRef(color, self.background_opacity, self.dark_theme);
    }

    fn cellBackgroundColorRef(self: *const View, color: theme.Color, default: theme.Color) win.COLORREF {
        if (!std.meta.eql(color, default)) return colorRef(color);
        return self.backgroundColorRef(color);
    }

    fn activeBackground(self: *View) theme.Color {
        const session = self.boundSession() orelse return self.model.terminal_theme.background;
        return session.background;
    }

    fn handleKey(self: *View, wparam: win.WPARAM, lparam: win.LPARAM, released: bool) bool {
        if (wparam == win.VK_F4 and win.GetKeyState(win.VK_MENU) < 0) return false;
        if (self.handleApplicationShortcut(wparam, lparam, released)) return true;
        if (self.handleClipboardShortcut(wparam, lparam, released)) return true;
        if (self.consumed_prompt_key == wparam) {
            if (released) self.consumed_prompt_key = null;
            return true;
        }
        if (released and (wparam == win.VK_CONTROL or wparam == win.VK_LCONTROL or wparam == win.VK_RCONTROL)) {
            self.clearHoveredLink();
        }
        const runtime = if (self.boundSession()) |s| s.runtime else null;
        const control_shift = win.GetKeyState(win.VK_CONTROL) < 0 and win.GetKeyState(win.VK_SHIFT) < 0;
        if (!released and control_shift and (wparam == win.VK_UP or wparam == win.VK_DOWN)) {
            self.consumed_prompt_key = wparam;
            if (runtime) |r| {
                if (r.navigatePrompt(wparam == win.VK_DOWN) catch false) self.notifyScrollbar(true);
            }
            self.clearSelection();
            self.invalidate();
            return true;
        }
        if (!released and control_shift and wparam == 'F') {
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.chrome_message, @intFromEnum(@import("chrome_bridge.zig").Command.find), 0);
            self.suppressed_search_character = 0x06;
            return true;
        }
        if (input.keyFromMessage(wparam, lparam) == null) return false;
        if (!released) self.clearSelection();
        const active_runtime = if (self.boundSession()) |session| session.runtime else null;
        if (!released and active_runtime == null) return true;
        const event = self.input_state.keyEvent(wparam, lparam, released) orelse return true;
        const index = @intFromEnum(event.key);
        if (event.action == .press) self.key_runtimes[index] = active_runtime;
        const key_runtime = self.key_runtimes[index] orelse return true;
        if (event.action == .release) self.key_runtimes[index] = null;
        if (!self.runtimeIsLive(key_runtime)) return true;
        const encoded = key_runtime.sendKey(
            event.key,
            event.action,
            event.modifiers,
            event.consumed_modifiers,
            event.utf8[0..event.utf8_length],
            event.unshifted_codepoint,
        ) catch |err| {
            log.debug("unable to send terminal key: {}", .{err});
            return true;
        };
        if (!released and encoded) {
            self.input_state.suppressEncodedCharacter(event.key, event.unshifted_codepoint);
            self.scrollToBottom();
        }
        return true;
    }

    fn handleApplicationShortcut(self: *View, wparam: win.WPARAM, lparam: win.LPARAM, released: bool) bool {
        if (self.consumed_application_key == wparam) {
            if (released) {
                self.consumed_application_key = null;
                self.suppress_application_character = false;
            } else self.suppress_application_character = true;
            return true;
        }
        if (released or win.GetKeyState(win.VK_CONTROL) >= 0) return false;

        const shift = win.GetKeyState(win.VK_SHIFT) < 0;
        const alt = win.GetKeyState(win.VK_MENU) < 0;
        const command: ?u32 = if (alt and !shift and wparam == win.VK_LEFT)
            win.ZIGONAUT_CHROME_FOCUS_LEFT
        else if (alt and !shift and wparam == win.VK_RIGHT)
            win.ZIGONAUT_CHROME_FOCUS_RIGHT
        else if (alt and !shift and wparam == win.VK_UP)
            win.ZIGONAUT_CHROME_FOCUS_UP
        else if (alt and !shift and wparam == win.VK_DOWN)
            win.ZIGONAUT_CHROME_FOCUS_DOWN
        else if (alt)
            null
        else if (shift and wparam == 'T')
            win.ZIGONAUT_CHROME_NEW_DEFAULT
        else if (shift and wparam == 'N')
            win.ZIGONAUT_CHROME_NEW_WINDOW
        else if (shift and wparam == 'W')
            win.ZIGONAUT_CHROME_CLOSE_PANE
        else if (shift and wparam == 'O')
            win.ZIGONAUT_CHROME_SPLIT_RIGHT
        else if (shift and wparam == 'E')
            win.ZIGONAUT_CHROME_SPLIT_DOWN
        else if (shift and wparam == 'G')
            win.ZIGONAUT_CHROME_PIPE_COMMAND_OUTPUT
        else if (wparam == win.VK_TAB)
            if (shift) win.ZIGONAUT_CHROME_SELECT_PREVIOUS else win.ZIGONAUT_CHROME_SELECT_NEXT
        else if (wparam == win.VK_ADD or wparam == win.VK_OEM_PLUS)
            win.ZIGONAUT_CHROME_ZOOM_IN
        else if (wparam == win.VK_SUBTRACT or wparam == win.VK_OEM_MINUS)
            win.ZIGONAUT_CHROME_ZOOM_OUT
        else if (wparam == '0' or wparam == win.VK_NUMPAD0)
            win.ZIGONAUT_CHROME_ZOOM_RESET
        else if (!shift and wparam >= '1' and wparam <= '9')
            win.ZIGONAUT_CHROME_SELECT
        else
            null;
        const value = command orelse return false;
        self.consumed_application_key = wparam;
        self.suppress_application_character = true;
        const repeated = (lparam & (@as(win.LPARAM, 1) << 30)) != 0;
        if (!repeated) {
            const argument = if (value == win.ZIGONAUT_CHROME_SELECT) wparam - '1' else 0;
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.chrome_message, value, @intCast(argument));
        }
        return true;
    }

    fn handleClipboardShortcut(self: *View, wparam: win.WPARAM, lparam: win.LPARAM, released: bool) bool {
        const shortcut = clipboardShortcut(
            wparam,
            win.GetKeyState(win.VK_CONTROL) < 0,
            win.GetKeyState(win.VK_SHIFT) < 0,
            win.GetKeyState(win.VK_MENU) < 0,
        ) orelse return false;
        if (released) return true;

        self.consumed_application_key = wparam;
        self.suppress_application_character = true;
        const repeated = (lparam & (@as(win.LPARAM, 1) << 30)) != 0;
        if (repeated) return true;
        switch (shortcut) {
            .copy => self.copySelection() catch |err| log.debug("unable to copy terminal selection: {}", .{err}),
            .paste => self.pasteClipboard() catch |err| log.debug("unable to paste clipboard: {}", .{err}),
        }
        return true;
    }

    fn releasePressedKeys(self: *View) void {
        for (std.enums.values(Terminal.Key)) |key| {
            const pressed = self.input_state.takePressed(key) orelse continue;
            const index = @intFromEnum(key);
            const runtime = self.key_runtimes[index];
            self.key_runtimes[index] = null;
            if (runtime) |current| {
                const modifiers = input.normalizeModifiers(input.currentModifiers(), pressed.altgr_text);
                if (self.runtimeIsLive(current)) _ = current.sendKey(key, .release, modifiers, 0, "", pressed.unshifted_codepoint) catch |err| {
                    log.debug("unable to release terminal key: {}", .{err});
                };
            }
        }
    }

    fn runtimeIsLive(self: *const View, runtime: *SessionRuntime) bool {
        return self.model.runtimeIsLive(runtime);
    }

    fn handleCharacter(self: *View, code_unit: u16) void {
        if (self.suppress_application_character) {
            self.suppress_application_character = false;
            return;
        }
        if (self.suppressed_search_character == code_unit) {
            self.suppressed_search_character = null;
            return;
        }
        self.suppressed_search_character = null;
        if (self.input_state.suppressCharacter(code_unit)) return;
        self.clearSelection();
        const session = self.boundSession() orelse return;
        var utf8: [4]u8 = undefined;
        const encoded = self.input_state.encodeUnsuppressedCharacter(code_unit, &utf8) orelse return;
        session.runtime.?.write(encoded) catch |err| {
            log.debug("unable to write terminal input: {}", .{err});
            return;
        };
        self.scrollToBottom();
    }

    fn beginSelection(self: *View, lparam: win.LPARAM) void {
        if (win.GetKeyState(win.VK_CONTROL) < 0 and self.openLinkAt(lparam)) return;
        if (win.GetKeyState(win.VK_SHIFT) >= 0 and self.beginProtocolButton(.left, lparam)) {
            return;
        }
        const point = self.mousePoint(lparam, false) orelse {
            self.clearSelection();
            return;
        };
        const session = self.boundSession() orelse return;
        const runtime = session.runtime orelse return;
        self.clearSelection();
        const now = win.GetTickCount64();
        if (self.last_click_point != null and std.meta.eql(self.last_click_point.?, point) and now - self.last_click_tick <= win.GetDoubleClickTime())
            self.click_count = saturatingClick(self.click_count)
        else
            self.click_count = 1;
        self.last_click_tick = now;
        self.last_click_point = point;
        const unit: Terminal.SelectionUnit = if (self.click_count >= 3) .line else if (self.click_count == 2) .word else .cell;
        runtime.beginSelectionAnchor(point) catch return;
        runtime.setDerivedSelection(point, unit, unit == .cell and win.GetKeyState(win.VK_MENU) < 0) catch {
            runtime.endSelectionAnchor();
            return;
        };
        self.selection = .{
            .runtime = runtime,
            .dragging = true,
            .unit = unit,
            .focus = point,
        };
        _ = win.SetTimer(self.hwnd, selection_scroll_timer, 33, null);
        self.invalidate();
    }

    fn updateSelection(self: *View, lparam: win.LPARAM) void {
        if (self.protocol_runtime) |runtime| {
            _ = self.sendMouseTo(runtime, .motion, self.protocol_button orelse .none, clientPoint(lparam), self.protocol_button != null);
            return;
        }
        if (win.GetKeyState(win.VK_SHIFT) >= 0) if (self.boundSession()) |session| if (session.runtime) |runtime| {
            _ = self.sendMouseTo(runtime, .motion, .none, clientPoint(lparam), false);
        };
        if (self.selection == null or !self.selection.?.dragging) self.updateHoveredLink(lparam);
        const point = self.mousePoint(lparam, true) orelse return;
        const current = self.selection orelse return;
        if (!current.dragging or std.meta.eql(current.focus, point)) return;
        const session = self.boundSession() orelse {
            self.abandonSelection();
            return;
        };
        if (session.runtime != current.runtime) {
            self.abandonSelection();
            return;
        }
        if (self.selection) |*selection| {
            selection.runtime.setDerivedSelection(point, selection.unit, selection.unit == .cell and win.GetKeyState(win.VK_MENU) < 0) catch |err| {
                log.debug("unable to update terminal selection: {}", .{err});
                self.abandonSelection();
                return;
            };
            selection.focus = point;
            selection.moved = true;
            self.invalidate();
        }
    }

    fn finishSelection(self: *View, button: Terminal.MouseButton, lparam: win.LPARAM) void {
        if (self.protocol_runtime) |runtime| {
            if (self.protocol_button != button) return;
            _ = self.sendMouseTo(runtime, .release, button, clientPoint(lparam), false);
            self.protocol_button = null;
            self.protocol_runtime = null;
            return;
        }
        if (self.selection == null or !self.selection.?.dragging) return;
        self.updateSelection(lparam);
        if (self.selection == null) return;
        self.selection.?.dragging = false;
        self.selection.?.runtime.endSelectionAnchor();
        _ = win.KillTimer(self.hwnd, selection_scroll_timer);
        if (!self.selection.?.moved and self.selection.?.unit == .cell) {
            self.clearSelection();
            return;
        }
        self.copySelection() catch |err| log.debug("unable to copy terminal selection: {}", .{err});
    }

    fn cancelSelectionDrag(self: *View) void {
        if (self.selection) |*selection| {
            selection.dragging = false;
            selection.runtime.endSelectionAnchor();
        }
        if (self.protocol_runtime) |runtime| if (self.protocol_button) |button| {
            _ = self.sendMouseTo(runtime, .release, button, self.lastMouseClientPoint(), false);
        };
        self.protocol_button = null;
        self.protocol_runtime = null;
        _ = win.KillTimer(self.hwnd, selection_scroll_timer);
    }

    fn beginProtocolButton(self: *View, button: Terminal.MouseButton, lparam: win.LPARAM) bool {
        if (self.protocol_button != null) return true;
        const session = self.boundSession() orelse return false;
        const runtime = session.runtime orelse return false;
        if (!self.sendMouseTo(runtime, .press, button, clientPoint(lparam), true)) return false;
        self.protocol_button = button;
        self.protocol_runtime = runtime;
        return true;
    }

    fn sendMouseTo(self: *View, runtime: *SessionRuntime, action: Terminal.MouseAction, button: Terminal.MouseButton, point: Terminal.PixelPoint, pressed: bool) bool {
        const geometry = self.mouseGeometry() orelse return false;
        return runtime.sendMouse(action, button, point, input.currentModifiers(), geometry, pressed) catch false;
    }

    fn mouseGeometry(self: *View) ?Terminal.MouseGeometry {
        var rect: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &rect) == 0) return null;
        const geometry = self.gridGeometry(rect);
        const width: u32 = @intCast(@max(rect.right - rect.left, 1));
        const height: u32 = @intCast(@max(rect.bottom - rect.top, 1));
        return .{
            .screen_width = width,
            .screen_height = height,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .padding_top = @intCast(geometry.top),
            .padding_bottom = @intCast(geometry.bottom),
            .padding_left = @intCast(geometry.left),
            .padding_right = @intCast(geometry.right),
        };
    }

    fn lastMouseClientPoint(self: *View) Terminal.PixelPoint {
        var point: win.POINT = undefined;
        if (win.GetCursorPos(&point) == 0 or win.ScreenToClient(self.hwnd, &point) == 0) return .{ .x = 0, .y = 0 };
        return .{ .x = point.x, .y = point.y };
    }

    fn sendWheel(self: *View, delta: i32, horizontal: bool, point: Terminal.PixelPoint) bool {
        const session = self.boundSession() orelse return false;
        const runtime = session.runtime orelse return false;
        const remainder = if (horizontal) &self.protocol_hwheel_remainder else &self.protocol_wheel_remainder;
        const accumulated = wheelAccumulation(remainder.*, delta);
        if (accumulated.steps == 0) {
            // Keep partial detents for terminal mouse reports. For viewport
            // scrolling, pass them to the pixel-based scroll accumulator.
            if (runtime.mouseTracking()) {
                remainder.* = accumulated.remainder;
            } else {
                remainder.* = 0;
                if (!horizontal) self.handleMouseWheelDelta(accumulated.remainder);
            }
            return true;
        }
        const steps = accumulated.steps;
        const button: Terminal.MouseButton = if (horizontal)
            (if (steps > 0) .wheel_right else .wheel_left)
        else
            (if (steps > 0) .wheel_up else .wheel_down);
        const geometry = self.mouseGeometry() orelse return false;
        if (runtime.sendMouseWheel(button, @intCast(@abs(steps)), point, input.currentModifiers(), geometry) catch false) {
            remainder.* = accumulated.remainder;
        } else {
            remainder.* = 0;
            if (!horizontal) self.handleMouseWheelDelta(steps * win.WHEEL_DELTA + accumulated.remainder);
        }
        return true;
    }

    fn pixelPoint(self: *View, x: i32, y: i32) Terminal.Point {
        const px = std.math.clamp(x, 0, @as(i32, self.columns) * @as(i32, @intCast(self.cell_width)) - 1);
        const py = std.math.clamp(y, 0, @as(i32, self.rows) * @as(i32, @intCast(self.cell_height)) - 1);
        return .{ .x = @intCast(@divTrunc(px, @as(i32, @intCast(self.cell_width)))), .y = @intCast(@divTrunc(py, @as(i32, @intCast(self.cell_height)))) };
    }

    fn selectionAutoscroll(self: *View) void {
        if (self.selection == null or !self.selection.?.dragging) return;
        const active = self.boundSession() orelse return self.abandonSelection();
        if (active.runtime != self.selection.?.runtime) return self.abandonSelection();
        var cursor: win.POINT = undefined;
        if (win.GetCursorPos(&cursor) == 0 or win.ScreenToClient(self.hwnd, &cursor) == 0) return;
        var client: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &client) == 0) return;
        const geometry = self.gridGeometry(client);
        const top = geometry.top;
        const bottom = top + @as(i32, self.rows) * @as(i32, @intCast(self.cell_height));
        const distance = if (cursor.y < top) cursor.y - top else if (cursor.y >= bottom) cursor.y - bottom + 1 else return;
        const rows_per_tick: isize = @intCast(@min(@divTrunc(@abs(distance), self.cell_height) + 1, 8));
        self.scrollViewport(if (distance < 0) -rows_per_tick else rows_per_tick);
        const point = self.pixelPoint(cursor.x - geometry.left, cursor.y - top);
        if (self.selection) |*selection| {
            selection.runtime.setDerivedSelection(point, selection.unit, selection.unit == .cell and win.GetKeyState(win.VK_MENU) < 0) catch return self.abandonSelection();
            selection.focus = point;
            selection.moved = true;
        }
    }

    fn abandonSelection(self: *View) void {
        _ = win.KillTimer(self.hwnd, selection_scroll_timer);
        if (self.selection) |selection| {
            selection.runtime.setSelection(null) catch {};
            selection.runtime.endSelectionAnchor();
        }
        self.selection = null;
        self.invalidate();
    }

    fn clearSelection(self: *View) void {
        if (self.selection == null) return;
        const selection = self.selection.?;
        self.selection = null;
        _ = win.KillTimer(self.hwnd, selection_scroll_timer);
        selection.runtime.endSelectionAnchor();
        if (self.boundSession()) |session| {
            if (session.runtime == selection.runtime) {
                selection.runtime.setSelection(null) catch |err| {
                    log.debug("unable to clear terminal selection: {}", .{err});
                };
            }
        }
        self.invalidate();
    }

    fn mousePoint(self: *View, lparam: win.LPARAM, clamp_to_grid: bool) ?Terminal.Point {
        if (self.columns == 0 or self.rows == 0) return null;
        var client: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &client) == 0) return null;
        const geometry = self.gridGeometry(client);
        var x = mouseCoordinate(lparam, 0) - geometry.left;
        var y = mouseCoordinate(lparam, 16) - geometry.top;
        const width = @as(i32, self.columns) * @as(i32, @intCast(self.cell_width));
        const height = @as(i32, self.rows) * @as(i32, @intCast(self.cell_height));
        if (!clamp_to_grid and (x < 0 or y < 0 or x >= width or y >= height)) return null;
        x = std.math.clamp(x, 0, width - 1);
        y = std.math.clamp(y, 0, height - 1);
        return .{
            .x = @intCast(@divTrunc(x, @as(i32, @intCast(self.cell_width)))),
            .y = @intCast(@divTrunc(y, @as(i32, @intCast(self.cell_height)))),
        };
    }

    fn copySelection(self: *View) !void {
        const selection = self.selection orelse return;
        const session = self.boundSession() orelse return;
        const runtime = session.runtime orelse return;
        if (runtime != selection.runtime) return;
        const text = try runtime.selectedTextAlloc(std.heap.page_allocator);
        defer std.heap.page_allocator.free(text);
        try setClipboardText(self.hwnd, text);
        self.copy_flash = true;
        _ = win.SetTimer(self.hwnd, copy_flash_timer, copy_flash_duration_ms, null);
        self.invalidate();
    }

    pub fn copyLastCommandOutput(self: *View) !void {
        const session = self.boundSession() orelse return;
        const runtime = session.runtime orelse return;
        const text = try runtime.lastCommandOutputAlloc(std.heap.page_allocator) orelse return;
        defer std.heap.page_allocator.free(text);
        try setClipboardText(self.hwnd, text);
    }

    fn pasteClipboard(self: *View) !void {
        const session = self.boundSession() orelse return;
        const runtime = session.runtime orelse return;
        const text = try clipboardTextAlloc(self.hwnd, std.heap.page_allocator);
        defer std.heap.page_allocator.free(text);
        self.clearSelection();
        try runtime.paste(text);
        if (text.len != 0) self.scrollToBottom();
    }

    fn showContextMenu(self: *View, screen_point: ?win.POINT) void {
        const menu = win.CreatePopupMenu() orelse return;
        defer _ = win.DestroyMenu(menu);

        const runtime = if (self.boundSession()) |session| session.runtime else null;
        const copy_enabled = runtime != null and self.selection != null and self.selection.?.runtime == runtime.?;
        const paste_enabled = runtime != null and win.IsClipboardFormatAvailable(win.CF_UNICODETEXT) != 0;
        appendContextMenuItem(menu, .copy, "Copy\tCtrl+Shift+C", copy_enabled);
        appendContextMenuItem(menu, .paste, "Paste\tCtrl+Shift+V", paste_enabled);
        _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
        appendContextMenuItem(menu, .find, "Find\tCtrl+Shift+F", runtime != null);
        _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
        appendContextMenuItem(menu, .split_right, "Split right\tCtrl+Shift+O", runtime != null);
        appendContextMenuItem(menu, .split_down, "Split down\tCtrl+Shift+E", runtime != null);
        _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
        appendContextMenuItem(menu, .close_pane, "Close pane\tCtrl+Shift+W", self.pane_id != null);

        const point = screen_point orelse keyboardContextMenuPoint(self.hwnd);
        const selected = win.TrackPopupMenu(
            menu,
            win.TPM_RIGHTBUTTON | win.TPM_RETURNCMD,
            point.x,
            point.y,
            0,
            self.hwnd,
            null,
        );
        if (selected == 0) return;
        const command: ContextMenuCommand = @enumFromInt(selected);
        switch (command) {
            .copy => self.copySelection() catch |err| log.debug("unable to copy terminal selection: {}", .{err}),
            .paste => self.pasteClipboard() catch |err| log.debug("unable to paste clipboard: {}", .{err}),
            .find => self.postChromeCommand(win.ZIGONAUT_CHROME_FIND),
            .split_right => self.postChromeCommand(win.ZIGONAUT_CHROME_SPLIT_RIGHT),
            .split_down => self.postChromeCommand(win.ZIGONAUT_CHROME_SPLIT_DOWN),
            .close_pane => self.postChromeCommand(win.ZIGONAUT_CHROME_CLOSE_PANE),
        }
    }

    fn postChromeCommand(self: *View, command: u32) void {
        _ = win.PostMessageW(win.GetParent(self.hwnd), self.chrome_message, command, 0);
    }

    fn pasteDroppedFiles(self: *View, drop: win.HDROP) !void {
        const session = self.boundSession() orelse return;
        const runtime = session.runtime orelse return;
        const count = win.DragQueryFileW(drop, 0xffffffff, null, 0);
        var command = std.ArrayList(u8).empty;
        defer command.deinit(std.heap.page_allocator);
        var index: win.UINT = 0;
        while (index < count) : (index += 1) {
            const length = win.DragQueryFileW(drop, index, null, 0);
            const wide = try std.heap.page_allocator.alloc(u16, @as(usize, length) + 1);
            defer std.heap.page_allocator.free(wide);
            if (win.DragQueryFileW(drop, index, wide.ptr, length + 1) != length) continue;
            const path = try std.unicode.utf16LeToUtf8Alloc(std.heap.page_allocator, wide[0..length]);
            defer std.heap.page_allocator.free(path);
            const quoted = try shell_quote.pathAlloc(std.heap.page_allocator, path, session.shell);
            defer std.heap.page_allocator.free(quoted);
            if (command.items.len != 0) try command.append(std.heap.page_allocator, ' ');
            try command.appendSlice(std.heap.page_allocator, quoted);
        }
        if (command.items.len == 0) return;
        self.clearSelection();
        try runtime.paste(command.items);
        self.scrollToBottom();
    }

    fn updateHoveredLink(self: *View, lparam: win.LPARAM) void {
        if (win.GetKeyState(win.VK_CONTROL) >= 0) {
            self.clearHoveredLink();
            return;
        }
        const point = self.mousePoint(lparam, false) orelse {
            self.clearHoveredLink();
            return;
        };
        const session = self.boundSession() orelse return;
        const runtime = session.runtime orelse return;
        const generation = runtime.contentGeneration();
        if (self.hovered_link) |hovered| {
            if (hovered.runtime == runtime and hovered.generation == generation and
                hovered.point.x == point.x and hovered.point.y == point.y) return;
        }
        self.clearHoveredLink();
        const found = runtime.linkAtAlloc(std.heap.page_allocator, point) catch |err| {
            log.debug("unable to inspect terminal link: {}", .{err});
            return;
        } orelse return;
        self.hovered_link = .{
            .runtime = runtime,
            .generation = generation,
            .point = point,
            .link = found,
        };
        _ = win.SetCursor(win.LoadCursorW(null, win32.handleFromInt(win.LPCWSTR, 32649)));
        self.invalidate();
    }

    fn clearHoveredLink(self: *View) void {
        if (self.hovered_link) |hovered| std.heap.page_allocator.free(hovered.link.uri);
        if (self.hovered_link != null) self.invalidate();
        self.hovered_link = null;
    }

    fn openLinkAt(self: *View, lparam: win.LPARAM) bool {
        const point = self.mousePoint(lparam, false) orelse return false;
        const session = self.boundSession() orelse return false;
        const runtime = session.runtime orelse return false;
        const found = runtime.linkAtAlloc(std.heap.page_allocator, point) catch |err| {
            log.debug("unable to inspect terminal link: {}", .{err});
            return false;
        } orelse return false;
        defer std.heap.page_allocator.free(found.uri);
        openUri(found.uri) catch |err| {
            log.debug("unable to open terminal link: {}", .{err});
            return false;
        };
        return true;
    }
};

const MouseSelection = struct {
    runtime: *SessionRuntime,
    dragging: bool,
    moved: bool = false,
    unit: Terminal.SelectionUnit,
    focus: Terminal.Point,
};

const HoveredLink = struct {
    runtime: *SessionRuntime,
    generation: u64,
    point: Terminal.Point,
    link: Terminal.Link,
};

const PaddingExtensionRun = struct {
    left: i32,
    right: i32,
    color: u32,
};

const DirectWriteCellRenderer = struct {
    engine: *TextEngine,
    view: *View,
    client: win.RECT,
    origin_x: i32,
    origin_y: i32,
    background: u32,
    frame: ?Terminal.Frame = null,
    search_matches: []const SearchMatch = &.{},
    search_row_matches: search.RowMatches = .{ .matches = &.{}, .start_index = 0 },
    search_cursor: search.RowCursor = .{ .matches = &.{} },
    search_active: ?usize = null,
    search_offset: u64 = 0,
    row_metadata: Terminal.RowMetadata = .{},
    vertical_extension: ?PaddingExtensionRun = null,
    draw_error: ?anyerror = null,

    pub fn searchState(self: *DirectWriteCellRenderer, _: bool, _: []const u8, matches: []const SearchMatch, active: ?usize, offset: u64, _: bool) void {
        self.search_matches = matches;
        self.search_active = active;
        self.search_offset = offset;
    }

    pub fn beginFrame(self: *DirectWriteCellRenderer, frame: Terminal.Frame) void {
        self.frame = frame;
        self.search_cursor = .init(self.search_matches, self.search_offset);
    }

    pub fn rowMetadata(self: *DirectWriteCellRenderer, _: u16, metadata: Terminal.RowMetadata) void {
        self.row_metadata = metadata;
    }

    pub fn beginRow(self: *DirectWriteCellRenderer, y: u16) void {
        self.vertical_extension = null;
        self.search_row_matches = self.search_cursor.next(self.search_offset + y);
        const top = self.origin_y + @as(i32, y) * @as(i32, @intCast(self.view.cell_height));
        const extend = self.view.padding_color != .background and !self.view.high_contrast;
        self.engine.clearRect(
            @floatFromInt(if (extend) self.client.left else self.origin_x),
            @floatFromInt(top),
            @floatFromInt(if (extend) self.client.right else self.origin_x + @as(i32, self.view.columns) * @as(i32, @intCast(self.view.cell_width))),
            @floatFromInt(top + @as(i32, @intCast(self.view.cell_height))),
            self.background,
        );
        if (extend and y == 0 and self.origin_y > self.client.top) self.engine.clearRect(
            @floatFromInt(self.client.left),
            @floatFromInt(self.client.top),
            @floatFromInt(self.client.right),
            @floatFromInt(self.origin_y),
            self.background,
        );
        const grid_bottom = self.origin_y + @as(i32, self.view.rows) * @as(i32, @intCast(self.view.cell_height));
        if (extend and y + 1 == self.view.rows and grid_bottom < self.client.bottom) self.engine.clearRect(
            @floatFromInt(self.client.left),
            @floatFromInt(grid_bottom),
            @floatFromInt(self.client.right),
            @floatFromInt(self.client.bottom),
            self.background,
        );
        self.engine.beginRow(
            y,
            @floatFromInt(self.origin_x),
            @floatFromInt(top),
            @floatFromInt(self.view.cell_width),
            @floatFromInt(self.view.cell_height),
        );
    }

    pub fn drawCell(self: *DirectWriteCellRenderer, cell: Terminal.Cell) void {
        if (self.draw_error != null) return;
        if (cell.occupancy == .wide_tail) return;
        const left = self.origin_x + @as(i32, cell.x) * @as(i32, @intCast(self.view.cell_width));
        const top = self.origin_y + @as(i32, cell.y) * @as(i32, @intCast(self.view.cell_height));
        const span: u32 = if (cell.occupancy == .wide) 2 else 1;
        const solid_cursor = self.view.focused and
            self.frame.?.cursor_visible and
            self.frame.?.cursor_style == .block and
            cell.x >= self.frame.?.cursor_x and
            cell.x < self.frame.?.cursor_x + self.frame.?.cursor_columns and
            cell.y == self.frame.?.cursor_y;
        const normal_foreground = if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(cell.foreground);
        const normal_background = if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOW) else self.view.cellBackgroundColorRef(cell.background, self.frame.?.background);
        const search_kind = search.highlightRow(self.search_row_matches, self.search_active, cell.x);
        if (self.view.padding_color != .background and !self.view.high_contrast) {
            const extension_foreground = if (search_kind == 2)
                win.GetSysColor(win.COLOR_HIGHLIGHTTEXT)
            else if (search_kind == 1)
                normal_background
            else if (cell.selected)
                (if (self.view.copy_flash) normal_background else win.GetSysColor(win.COLOR_HIGHLIGHTTEXT))
            else
                normal_foreground;
            const extension_background = if (search_kind == 2)
                win.GetSysColor(win.COLOR_HIGHLIGHT)
            else if (search_kind == 1)
                normal_foreground
            else if (cell.selected)
                (if (self.view.copy_flash) normal_foreground else win.GetSysColor(win.COLOR_HIGHLIGHT))
            else
                normal_background;
            const full_block = search_kind == 0 and !cell.selected and cell.codepoints.len == 1 and cell.codepoints[0] == 0x2588;
            self.extendBackground(cell, span, if (full_block)
                (if (cell.faint) blendColorRef(extension_foreground, extension_background) else extension_foreground)
            else
                extension_background);
        }
        const foreground = if (search_kind != 0 and self.view.high_contrast)
            win.GetSysColor(win.COLOR_HIGHLIGHTTEXT)
        else if (search_kind == 2)
            win.GetSysColor(win.COLOR_HIGHLIGHTTEXT)
        else if (search_kind == 1)
            normal_background
        else if (cell.selected)
            (if (self.view.copy_flash and !self.view.high_contrast) normal_background else win.GetSysColor(win.COLOR_HIGHLIGHTTEXT))
        else if (solid_cursor)
            normal_background
        else
            normal_foreground;
        const background = if (search_kind != 0 and self.view.high_contrast)
            win.GetSysColor(win.COLOR_HIGHLIGHT)
        else if (search_kind == 2)
            win.GetSysColor(win.COLOR_HIGHLIGHT)
        else if (search_kind == 1)
            normal_foreground
        else if (cell.selected)
            (if (self.view.copy_flash and !self.view.high_contrast) normal_foreground else win.GetSysColor(win.COLOR_HIGHLIGHT))
        else if (solid_cursor)
            (if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(self.frame.?.cursor))
        else
            normal_background;
        const underline_color = if (self.view.high_contrast) foreground else colorRef(cell.underline_color);
        const hovered = if (self.view.hovered_link) |value|
            value.link.row == cell.y and cell.x >= value.link.start_column and cell.x < value.link.end_column
        else
            false;
        var wide: [32]u16 = undefined;
        const length = encodeUtf16(cell.codepoints, &wide);
        self.engine.drawCell(
            wide[0..length],
            @floatFromInt(left),
            @floatFromInt(top),
            @floatFromInt(span * self.view.cell_width),
            @floatFromInt(self.view.cell_height),
            foreground,
            background,
            underline_color,
            cell.bold,
            cell.italic,
            cell.faint and !self.view.high_contrast,
            cell.strikethrough,
            cell.overline,
            if (hovered) @max(cell.underline, 1) else cell.underline,
            @intFromEnum(cell.occupancy),
        ) catch |err| {
            self.draw_error = err;
        };
    }

    fn extendBackground(self: *DirectWriteCellRenderer, cell: Terminal.Cell, span: u32, color: u32) void {
        if (self.view.padding_color == .background or self.view.high_contrast) return;
        const cell_width: i32 = @intCast(self.view.cell_width);
        const cell_height: i32 = @intCast(self.view.cell_height);
        const left = self.origin_x + @as(i32, cell.x) * cell_width;
        const right = left + @as(i32, @intCast(span)) * cell_width;
        const top = self.origin_y + @as(i32, cell.y) * cell_height;
        const bottom = top + cell_height;
        if (cell.x == 0 and self.origin_x > self.client.left) self.engine.clearRect(
            @floatFromInt(self.client.left),
            @floatFromInt(top),
            @floatFromInt(self.origin_x),
            @floatFromInt(bottom),
            color,
        );
        if (@as(u32, cell.x) + span >= self.view.columns) {
            const grid_right = self.origin_x + @as(i32, self.view.columns) * cell_width;
            if (grid_right < self.client.right) self.engine.clearRect(
                @floatFromInt(grid_right),
                @floatFromInt(top),
                @floatFromInt(self.client.right),
                @floatFromInt(bottom),
                color,
            );
        }
        const vertical = self.view.padding_color == .extendAlways or
            (!self.row_metadata.semantic_prompt and !self.row_metadata.never_extend_background);
        if (!vertical or (cell.y != 0 and cell.y + 1 != self.view.rows)) return;
        const strip_left = if (cell.x == 0) self.client.left else left;
        const strip_right = if (@as(u32, cell.x) + span >= self.view.columns) self.client.right else right;
        if (self.vertical_extension) |*run| {
            if (run.color == color and run.right == strip_left) {
                run.right = strip_right;
                return;
            }
            self.flushVerticalExtension(cell.y);
        }
        self.vertical_extension = .{ .left = strip_left, .right = strip_right, .color = color };
    }

    fn flushVerticalExtension(self: *DirectWriteCellRenderer, y: u16) void {
        const run = self.vertical_extension orelse return;
        self.vertical_extension = null;
        if (run.right <= run.left) return;
        if (y == 0 and self.origin_y > self.client.top) self.engine.clearRect(
            @floatFromInt(run.left),
            @floatFromInt(self.client.top),
            @floatFromInt(run.right),
            @floatFromInt(self.origin_y),
            run.color,
        );
        const grid_bottom = self.origin_y + @as(i32, self.view.rows) * @as(i32, @intCast(self.view.cell_height));
        if (y + 1 == self.view.rows and grid_bottom < self.client.bottom) self.engine.clearRect(
            @floatFromInt(run.left),
            @floatFromInt(grid_bottom),
            @floatFromInt(run.right),
            @floatFromInt(self.client.bottom),
            run.color,
        );
    }

    pub fn endRow(self: *DirectWriteCellRenderer, y: u16) void {
        self.flushVerticalExtension(y);
        self.engine.endRow() catch |err| {
            if (self.draw_error == null) self.draw_error = err;
        };
    }

    pub fn drawImage(self: *DirectWriteCellRenderer, image: Terminal.Image) void {
        if (self.draw_error != null) return;
        const cell_width: f32 = @floatFromInt(self.view.cell_width);
        const cell_height: f32 = @floatFromInt(self.view.cell_height);
        const origin_x: f32 = @floatFromInt(self.origin_x);
        const origin_y: f32 = @floatFromInt(self.origin_y);
        const left = origin_x + @as(f32, @floatFromInt(image.viewport_col)) * cell_width + @as(f32, @floatFromInt(image.x_offset));
        const top = origin_y + @as(f32, @floatFromInt(image.viewport_row)) * cell_height + @as(f32, @floatFromInt(image.y_offset));
        self.engine.drawImage(image, left, top, @floatFromInt(image.pixel_width), @floatFromInt(image.pixel_height), .{
            origin_x,                                                           origin_y,
            origin_x + @as(f32, @floatFromInt(self.view.columns)) * cell_width, origin_y + @as(f32, @floatFromInt(self.view.rows)) * cell_height,
        }) catch |err| {
            self.draw_error = err;
        };
    }

    pub fn endFrame(self: *DirectWriteCellRenderer, frame: Terminal.Frame) void {
        self.view.ime_anchor_x = frame.cursor_x;
        self.view.ime_anchor_y = frame.cursor_y;
        if (!frame.cursor_visible) return;
        if (self.view.focused and frame.cursor_style == .block) return;
        const left = self.origin_x + @as(i32, frame.cursor_x) * @as(i32, @intCast(self.view.cell_width));
        const top = self.origin_y + @as(i32, frame.cursor_y) * @as(i32, @intCast(self.view.cell_height));
        self.engine.drawCursor(
            @floatFromInt(left),
            @floatFromInt(top),
            @floatFromInt(@as(u32, frame.cursor_columns) * self.view.cell_width),
            @floatFromInt(self.view.cell_height),
            if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(frame.cursor),
            if (!self.view.focused or frame.cursor_style == .hollow)
                0
            else switch (frame.cursor_style) {
                .block => 1,
                .bar => 2,
                .underline => 3,
                .hollow => 0,
            },
        );
    }
};

fn windowProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.c) win.LRESULT {
    if (message == win.WM_NCCREATE) {
        const create: *win.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        const view: *View = @ptrCast(@alignCast(create.lpCreateParams));
        view.hwnd = hwnd;
        _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, @intCast(@intFromPtr(view)));
    }
    const userdata = win.GetWindowLongPtrW(hwnd, win.GWLP_USERDATA);
    const view: ?*View = if (userdata == 0) null else @ptrFromInt(@as(usize, @intCast(userdata)));

    switch (message) {
        win.ZIGONAUT_WM_ACCESSIBILITY_QUERY => {
            if (view == null or lparam == 0) return 0;
            const query: *win.zigonaut_accessibility_query = @ptrFromInt(@as(usize, @bitCast(lparam)));
            if (query.kind == win.ZIGONAUT_ACCESSIBLE_TEXT_SNAPSHOT)
                return @intFromBool(accessibilitySnapshot(view.?, @ptrCast(@alignCast(query))));
            if (query.size != @sizeOf(win.zigonaut_accessibility_query) or
                (query.kind != win.ZIGONAUT_ACCESSIBLE_NAME and query.kind != win.ZIGONAUT_ACCESSIBLE_VALUE) or
                (query.output == null and query.capacity != 0)) return 0;
            query.required = accessibilityText(view, query.kind, query.output, query.capacity);
            return 1;
        },
        win.ZIGONAUT_WM_ACCESSIBILITY_ACTION => {
            if (view == null or lparam == 0) return 0;
            const action: *const win.zigonaut_accessibility_action = @ptrFromInt(@as(usize, @bitCast(lparam)));
            return @intFromBool(accessibilitySelect(view.?, action));
        },
        render_message => {
            if (view) |current| {
                if (wparam == current.frame_epoch.load(.acquire)) {
                    current.clearFrameWait();
                    if (current.resize_render_pending) {
                        current.paintPendingResize();
                    } else if (current.render_dirty.swap(false, .acq_rel) and !current.paintSwapChain()) {
                        current.render_dirty.store(true, .release);
                    }
                }
            }
            return 0;
        },
        win.WM_CREATE => return 0,
        win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK => {
            if (view) |current| current.beginSelection(lparam);
            return 0;
        },
        win.WM_MBUTTONDOWN => {
            if (win.GetKeyState(win.VK_SHIFT) >= 0) if (view) |current| {
                if (current.beginProtocolButton(.middle, lparam)) return 0;
            };
            if (view) |current| current.pasteClipboard() catch |err| {
                log.debug("unable to paste clipboard: {}", .{err});
            };
            return 0;
        },
        win.WM_RBUTTONDOWN => {
            if (win.GetKeyState(win.VK_SHIFT) >= 0) if (view) |current| {
                if (current.beginProtocolButton(.right, lparam)) return 0;
            };
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_CONTEXTMENU => {
            if (view) |current| {
                const keyboard = lparam == -1;
                const point = if (keyboard) null else win.POINT{
                    .x = mouseCoordinate(lparam, 0),
                    .y = mouseCoordinate(lparam, 16),
                };
                current.showContextMenu(point);
            }
            return 0;
        },
        win.WM_DROPFILES => {
            const drop = win32.handleFromInt(win.HDROP, wparam);
            defer win.DragFinish(drop);
            if (view) |current| current.pasteDroppedFiles(drop) catch |err| {
                log.debug("unable to paste dropped files: {}", .{err});
            };
            return 0;
        },
        win.WM_MOUSEMOVE => {
            if (view) |current| current.updateSelection(lparam);
            return 0;
        },
        win.WM_LBUTTONUP, win.WM_MBUTTONUP => {
            if (view) |current| current.finishSelection(switch (message) {
                win.WM_LBUTTONUP => .left,
                else => .middle,
            }, lparam);
            return 0;
        },
        win.WM_RBUTTONUP => {
            if (view) |current| {
                const protocol = current.protocol_button == .right;
                current.finishSelection(.right, lparam);
                if (protocol) return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_CAPTURECHANGED, win.WM_CANCELMODE => {
            if (view) |current| current.cancelSelectionDrag();
            return 0;
        },
        win.WM_SETFOCUS => {
            if (view) |current| {
                current.focused = true;
                current.invalidate();
            }
            return 0;
        },
        win.WM_KILLFOCUS => {
            if (view) |current| {
                current.focused = false;
                current.consumed_prompt_key = null;
                current.consumed_application_key = null;
                current.suppress_application_character = false;
                current.releasePressedKeys();
                current.clearImePreedit();
                current.invalidate();
            }
            return 0;
        },
        win.WM_GETDLGCODE => return win.DLGC_WANTTAB,
        win.WM_KEYDOWN, win.WM_SYSKEYDOWN => {
            if (isContextMenuShortcut(wparam)) return 0;
            if (view) |current| {
                if (current.handleKey(wparam, lparam, false)) return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_KEYUP, win.WM_SYSKEYUP => {
            if (isContextMenuShortcut(wparam)) {
                if (view) |current| current.showContextMenu(null);
                return 0;
            }
            if (view) |current| {
                if (current.handleKey(wparam, lparam, true)) return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_CHAR => {
            if (view) |current| current.handleCharacter(@truncate(wparam));
            return 0;
        },
        win.WM_SYSCHAR => {
            if (view) |current| {
                if (current.input_state.suppressCharacter(@truncate(wparam))) return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_SIZE => {
            if (view) |current| {
                current.resizeSessions();
                if (current.text_engine != null)
                    current.renderResize()
                else
                    current.invalidate();
            }
            return 0;
        },
        win.WM_MOUSEWHEEL => {
            if (view) |current| current.handleMouseWheel(wparam, lparam);
            return 0;
        },
        win.WM_MOUSEHWHEEL => {
            if (view) |current| {
                const raw: u16 = @truncate(wparam >> 16);
                const delta: i32 = @as(i16, @bitCast(raw));
                if (win.GetKeyState(win.VK_SHIFT) >= 0) _ = current.sendWheel(delta, true, screenLparamToClient(hwnd, lparam));
            }
            return 0;
        },
        win.WM_TIMER => {
            if (wparam == refresh_timer) {
                if (view) |current| current.refreshIfNeeded();
            } else if (wparam == copy_flash_timer) {
                _ = win.KillTimer(hwnd, copy_flash_timer);
                if (view) |current| {
                    current.copy_flash = false;
                    current.invalidate();
                }
            } else if (wparam == selection_scroll_timer) {
                if (view) |current| current.selectionAutoscroll();
            } else if (wparam == synchronized_output_timer) {
                if (view) |current| current.refreshIfNeeded();
            } else if (wparam == present_retry_timer) {
                if (view) |current| current.retryPresent();
            }
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_PAINT => {
            if (view) |current| current.paint();
            return 0;
        },
        win.WM_DESTROY => {
            _ = win.KillTimer(hwnd, refresh_timer);
            _ = win.KillTimer(hwnd, copy_flash_timer);
            _ = win.KillTimer(hwnd, selection_scroll_timer);
            _ = win.KillTimer(hwnd, synchronized_output_timer);
            _ = win.KillTimer(hwnd, present_retry_timer);
            if (view) |current| current.deinitResources();
            return 0;
        },
        win.WM_NCDESTROY => {
            const result = win.DefWindowProcW(hwnd, message, wparam, lparam);
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, 0);
            if (view) |current| {
                current.hwnd = null;
            }
            return result;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

const CellSize = struct { width: u32, height: u32 };

const GridGeometry = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,
    grid_width: i32,
    grid_height: i32,

    fn gridRight(self: GridGeometry) i32 {
        return self.left + self.grid_width;
    }

    fn gridBottom(self: GridGeometry) i32 {
        return self.top + self.grid_height;
    }
};

fn calculateGridGeometry(
    screen_width: i32,
    screen_height: i32,
    columns: u16,
    rows: u16,
    cell_width: u32,
    cell_height: u32,
    padding_x: i32,
    padding_y: i32,
    balanced: bool,
) GridGeometry {
    const grid_width = @as(i32, columns) * @as(i32, @intCast(cell_width));
    const grid_height = @as(i32, rows) * @as(i32, @intCast(cell_height));
    const remaining_x = @max(screen_width - grid_width, 0);
    const remaining_y = @max(screen_height - grid_height, 0);
    const left = if (balanced) @divTrunc(remaining_x, 2) else @min(padding_x, remaining_x);
    const top = if (balanced) @divTrunc(remaining_y, 2) else @min(padding_y, remaining_y);
    return .{
        .left = left,
        .top = top,
        .right = remaining_x - left,
        .bottom = remaining_y - top,
        .grid_width = grid_width,
        .grid_height = grid_height,
    };
}

fn measureCell(hwnd: win.HWND, font: win.HFONT) CellSize {
    const dc = win.GetDC(hwnd);
    if (dc == null) return .{ .width = 9, .height = 18 };
    defer _ = win.ReleaseDC(hwnd, dc);

    const previous = win.SelectObject(dc, font);
    defer _ = win.SelectObject(dc, previous);
    var metrics: win.TEXTMETRICW = undefined;
    if (win.GetTextMetricsW(dc, &metrics) == 0) return .{ .width = 9, .height = 18 };
    return .{
        .width = @intCast(@max(metrics.tmAveCharWidth, 1)),
        .height = @intCast(@max(metrics.tmHeight + metrics.tmExternalLeading, 1)),
    };
}

fn scaled(value: i32, dpi: u32) i32 {
    return win.MulDiv(value, @intCast(dpi), 96);
}

fn mouseCoordinate(lparam: win.LPARAM, shift: u6) i32 {
    const bits: usize = @bitCast(lparam);
    const word: u16 = @truncate(bits >> shift);
    return @as(i16, @bitCast(word));
}

fn clientPoint(lparam: win.LPARAM) Terminal.PixelPoint {
    return .{ .x = mouseCoordinate(lparam, 0), .y = mouseCoordinate(lparam, 16) };
}

fn screenLparamToClient(hwnd: win.HWND, lparam: win.LPARAM) Terminal.PixelPoint {
    var point = win.POINT{ .x = mouseCoordinate(lparam, 0), .y = mouseCoordinate(lparam, 16) };
    _ = win.ScreenToClient(hwnd, &point);
    return .{ .x = point.x, .y = point.y };
}

fn appendContextMenuItem(menu: win.HMENU, command: ContextMenuCommand, comptime label: []const u8, enabled: bool) void {
    const flags: win.UINT = @intCast(win.MF_STRING | if (enabled) 0 else win.MF_GRAYED);
    _ = win.AppendMenuW(menu, flags, @intFromEnum(command), std.unicode.utf8ToUtf16LeStringLiteral(label));
}

fn keyboardContextMenuPoint(hwnd: win.HWND) win.POINT {
    var client: win.RECT = undefined;
    if (win.GetClientRect(hwnd, &client) == 0) return .{ .x = 0, .y = 0 };
    var point = win.POINT{ .x = client.left + 16, .y = client.top + 16 };
    _ = win.ClientToScreen(hwnd, &point);
    return point;
}

fn isContextMenuShortcut(key: win.WPARAM) bool {
    return key == win.VK_APPS or key == win.VK_F10 and win.GetKeyState(win.VK_SHIFT) < 0;
}

fn saturatingClick(value: u2) u2 {
    return if (value < 3) value + 1 else 3;
}

const WheelAccumulation = struct { steps: i32, remainder: i32 };
fn wheelAccumulation(remainder: i32, delta: i32) WheelAccumulation {
    const total = remainder + delta;
    const steps = @divTrunc(total, win.WHEEL_DELTA);
    return .{ .steps = steps, .remainder = total - steps * win.WHEEL_DELTA };
}

const ClipboardShortcut = enum { copy, paste };

fn clipboardShortcut(key: win.WPARAM, control: bool, shift: bool, alt: bool) ?ClipboardShortcut {
    if (alt) return null;
    if (shift and key == win.VK_INSERT) return .paste;
    if (control and key == win.VK_INSERT) return .copy;
    if (control and shift and key == 'C') return .copy;
    if (control and shift and key == 'V') return .paste;
    return null;
}

fn clipboardTextAlloc(hwnd: win.HWND, allocator: std.mem.Allocator) ![]u8 {
    if (win.OpenClipboard(hwnd) == 0) return error.OpenClipboardFailed;
    defer _ = win.CloseClipboard();
    const memory = win.GetClipboardData(win.CF_UNICODETEXT) orelse return error.ClipboardTextUnavailable;
    const raw = win.GlobalLock(memory) orelse return error.ClipboardLockFailed;
    defer _ = win.GlobalUnlock(memory);
    const source: [*:0]const u16 = @ptrCast(@alignCast(raw));
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(source));
    return allocator.realloc(utf8, normalizeClipboardNewlines(utf8).len);
}

fn normalizeClipboardNewlines(text: []u8) []u8 {
    var read: usize = 0;
    var write: usize = 0;
    while (read < text.len) : (read += 1) {
        if (text[read] == '\r' and read + 1 < text.len and text[read + 1] == '\n') continue;
        text[write] = text[read];
        write += 1;
    }
    return text[0..write];
}

fn openUri(uri: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, uri);
    defer allocator.free(wide);
    const result = win.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("open"), wide, null, null, win.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) return error.ShellExecuteFailed;
}

fn setClipboardText(hwnd: win.HWND, text: []const u8) !void {
    const allocator = std.heap.page_allocator;
    const windows_text = try windowsClipboardTextAlloc(allocator, text);
    defer allocator.free(windows_text);

    const wide = try allocator.alloc(u16, windows_text.len + 1);
    defer allocator.free(wide);
    const length = try std.unicode.utf8ToUtf16Le(wide[0 .. wide.len - 1], windows_text);
    wide[length] = 0;

    const memory = win.GlobalAlloc(win.GMEM_MOVEABLE, (length + 1) * @sizeOf(u16)) orelse return error.ClipboardAllocationFailed;
    var transferred = false;
    defer if (!transferred) {
        _ = win.GlobalFree(memory);
    };
    const raw = win.GlobalLock(memory) orelse return error.ClipboardLockFailed;
    const destination: [*]u16 = @ptrCast(@alignCast(raw));
    @memcpy(destination[0 .. length + 1], wide[0 .. length + 1]);
    _ = win.GlobalUnlock(memory);

    if (win.OpenClipboard(hwnd) == 0) return error.OpenClipboardFailed;
    defer _ = win.CloseClipboard();
    if (win.EmptyClipboard() == 0) return error.EmptyClipboardFailed;
    if (win.SetClipboardData(win.CF_UNICODETEXT, memory) == null) return error.SetClipboardDataFailed;
    transferred = true;
}

fn clearClipboard(hwnd: win.HWND) !void {
    if (win.OpenClipboard(hwnd) == 0) return error.OpenClipboardFailed;
    defer _ = win.CloseClipboard();
    if (win.EmptyClipboard() == 0) return error.EmptyClipboardFailed;
}

fn windowsClipboardTextAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var extra: usize = 0;
    for (text, 0..) |byte, index| if (byte == '\n' and (index == 0 or text[index - 1] != '\r')) {
        extra += 1;
    };
    const windows_text = try allocator.alloc(u8, text.len + extra);
    var output: usize = 0;
    for (text, 0..) |byte, index| {
        if (byte == '\n' and (index == 0 or text[index - 1] != '\r')) {
            windows_text[output] = '\r';
            output += 1;
        }
        windows_text[output] = byte;
        output += 1;
    }
    return windows_text;
}

fn drawDirectWriteMessage(
    engine: *TextEngine,
    text: []const u8,
    rect: win.RECT,
    foreground: u32,
    background: u32,
) !void {
    var wide: [16 * 1024]u16 = undefined;
    const length = try std.unicode.utf8ToUtf16Le(&wide, text);
    try engine.drawCell(
        wide[0..length],
        @floatFromInt(rect.left),
        @floatFromInt(rect.top),
        @floatFromInt(@max(rect.right - rect.left, 1)),
        @floatFromInt(@max(rect.bottom - rect.top, 1)),
        foreground,
        background,
        foreground,
        false,
        false,
        false,
        false,
        false,
        0,
        @intFromEnum(Terminal.Cell.Occupancy.narrow),
    );
}

test "clipboard newlines normalize without changing lone carriage returns" {
    var text = [_]u8{ 'a', '\r', '\n', 'b', '\n', 'c', '\r', 'd' };
    try std.testing.expectEqualStrings("a\nb\nc\rd", normalizeClipboardNewlines(&text));
}

test "Windows clipboard conversion preserves CRLF and expands lone LF" {
    const converted = try windowsClipboardTextAlloc(std.testing.allocator, "a\nb\r\nc\rd");
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("a\r\nb\r\nc\rd", converted);
}

test "standard terminal clipboard shortcuts are recognized" {
    try std.testing.expectEqual(ClipboardShortcut.copy, clipboardShortcut('C', true, true, false).?);
    try std.testing.expectEqual(ClipboardShortcut.copy, clipboardShortcut(win.VK_INSERT, true, false, false).?);
    try std.testing.expectEqual(ClipboardShortcut.paste, clipboardShortcut('V', true, true, false).?);
    try std.testing.expectEqual(ClipboardShortcut.paste, clipboardShortcut(win.VK_INSERT, false, true, false).?);
    try std.testing.expect(clipboardShortcut('C', true, false, false) == null);
    try std.testing.expect(clipboardShortcut('V', true, true, true) == null);
}

test "click count saturates" {
    try std.testing.expectEqual(@as(u2, 3), saturatingClick(3));
    try std.testing.expectEqual(@as(u2, 3), saturatingClick(2));
}

test "protocol wheel accumulation keeps partial deltas" {
    try std.testing.expectEqual(WheelAccumulation{ .steps = 0, .remainder = 80 }, wheelAccumulation(40, 40));
    try std.testing.expectEqual(WheelAccumulation{ .steps = 1, .remainder = 0 }, wheelAccumulation(80, 40));
    try std.testing.expectEqual(WheelAccumulation{ .steps = -1, .remainder = -20 }, wheelAccumulation(0, -140));
}

test "balanced grid geometry divides residual space equally" {
    const geometry = calculateGridGeometry(823, 517, 80, 24, 10, 20, 8, 8, true);
    try std.testing.expectEqual(@as(i32, 11), geometry.left);
    try std.testing.expectEqual(@as(i32, 12), geometry.right);
    try std.testing.expectEqual(@as(i32, 18), geometry.top);
    try std.testing.expectEqual(@as(i32, 19), geometry.bottom);
    try std.testing.expectEqual(@as(i32, 823), geometry.left + geometry.grid_width + geometry.right);
    try std.testing.expectEqual(@as(i32, 517), geometry.top + geometry.grid_height + geometry.bottom);
}

test "unbalanced geometry preserves configured top and left padding" {
    const geometry = calculateGridGeometry(823, 517, 80, 24, 10, 20, 8, 8, false);
    try std.testing.expectEqual(@as(i32, 8), geometry.left);
    try std.testing.expectEqual(@as(i32, 15), geometry.right);
    try std.testing.expectEqual(@as(i32, 8), geometry.top);
    try std.testing.expectEqual(@as(i32, 29), geometry.bottom);
}

test "grid geometry clips an oversized mandatory cell without negative padding" {
    const geometry = calculateGridGeometry(5, 7, 1, 1, 10, 20, 8, 8, true);
    try std.testing.expectEqual(@as(i32, 0), geometry.left);
    try std.testing.expectEqual(@as(i32, 0), geometry.right);
    try std.testing.expectEqual(@as(i32, 0), geometry.top);
    try std.testing.expectEqual(@as(i32, 0), geometry.bottom);
}
