const std = @import("std");
const App = @import("app.zig").App;
const SessionRuntime = @import("session.zig").SessionRuntime;
const Terminal = @import("terminal.zig").Terminal;
const TextEngine = @import("directwrite_renderer.zig").Engine;
const GdiRenderer = @import("gdi_renderer.zig");
const input = @import("input.zig");
const search = @import("search.zig");
const shell_quote = @import("shell_quote.zig");
const theme = @import("theme.zig");
const SearchMatch = search.Match;

const win32 = @import("win32.zig");
const win = win32.c;
const log = std.log.scoped(.terminal_view);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautTerminalView");
const refresh_message = win.WM_APP + 1;
const refresh_timer = 1;
const copy_flash_timer = 2;
const selection_scroll_timer = 3;
const idle_refresh_interval_ms = 250;
const search_refresh_interval_ms = 33;
const search_time_budget_ns = 2 * std.time.ns_per_ms;
const copy_flash_duration_ms = 150;
const wheel_rows = 3;

pub const View = struct {
    hwnd: win.HWND = null,
    refresh_hwnd: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    refresh_pending: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    refresh_interval_ms: u32 = idle_refresh_interval_ms,
    model: *App,
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
    copy_flash: bool = false,
    padding_horizontal: u16,
    padding_vertical: u16,
    background_opacity: u8,

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
        dpi: u32,
        padding_horizontal: u16,
        padding_vertical: u16,
        background_opacity: u8,
        titles_changed_message: win.UINT,
        shell_exited_message: win.UINT,
        scrollbar_changed_message: win.UINT,
        progress_changed_message: win.UINT,
        notification_changed_message: win.UINT,
    ) View {
        const text_engine = TextEngine.init(font_family, font_size, dpi) catch null;
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
            .background_opacity = background_opacity,
            .titles_changed_message = titles_changed_message,
            .shell_exited_message = shell_exited_message,
            .scrollbar_changed_message = scrollbar_changed_message,
            .progress_changed_message = progress_changed_message,
            .notification_changed_message = notification_changed_message,
        };
    }

    pub fn create(self: *View, parent: win.HWND, instance: win.HINSTANCE) !void {
        errdefer self.deinitResources();
        self.hwnd = win.CreateWindowExW(
            0,
            class_name,
            null,
            win.WS_CHILD | win.WS_VISIBLE | win.WS_CLIPSIBLINGS | win.WS_TABSTOP,
            0,
            0,
            1,
            1,
            parent,
            null,
            instance,
            self,
        ) orelse return error.CreateTerminalViewFailed;
        self.refresh_hwnd.store(@intFromPtr(self.hwnd), .release);
        self.model.setRefresh(.{ .callback = requestRefresh, .context = self });
        if (self.text_engine) |*engine| engine.setWindow(self.hwnd) catch |err| {
            log.warn("DirectWrite window initialization failed; using GDI fallback: {}", .{err});
            engine.deinit();
            self.text_engine = null;
        };
        win.DragAcceptFiles(self.hwnd, 1);
    }

    fn deinitResources(self: *View) void {
        self.clearHoveredLink();
        self.gdi_renderer.release();
        if (self.text_engine) |*engine| engine.deinit();
        self.text_engine = null;
    }

    pub fn move(self: *View, x: i32, y: i32, width: i32, height: i32) void {
        _ = win.MoveWindow(self.hwnd, x, y, @max(width, 1), @max(height, 1), 1);
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

    pub fn reloadFont(self: *View, font: win.HFONT, font_family: []const u8, font_size: u16, dpi: u32) !void {
        var text_engine = try TextEngine.init(font_family, font_size, dpi);
        errdefer text_engine.deinit();
        try text_engine.setWindow(self.hwnd);
        if (self.text_engine) |*engine| engine.deinit();
        self.text_engine = text_engine;
        self.font = font;
        self.updateCellSize(font);
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
        if (self.columns == 0 or self.rows == 0) return;
        self.model.resizeSessions(self.columns, self.rows, self.cell_width, self.cell_height);
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
        if (win.GetCapture() == self.hwnd) _ = win.ReleaseCapture();
        self.clearHoveredLink();
        self.wheel_remainder = 0;
        self.protocol_wheel_remainder = 0;
        self.protocol_hwheel_remainder = 0;
        self.last_click_tick = 0;
        self.click_count = 0;
        self.last_click_point = null;
    }

    pub fn invalidate(self: *View) void {
        _ = win.InvalidateRect(self.hwnd, null, 0);
    }

    fn requestRefresh(context: ?*anyopaque) void {
        const self: *View = @ptrCast(@alignCast(context orelse return));
        if (self.refresh_pending.swap(true, .acq_rel)) return;
        const value = self.refresh_hwnd.load(.acquire);
        if (value == 0 or win.PostMessageW(win32.handleFromInt(win.HWND, value), refresh_message, 0, 0) == 0) {
            self.refresh_pending.store(false, .release);
        }
    }

    fn setRefreshInterval(self: *View, interval_ms: u32) void {
        if (self.refresh_interval_ms == interval_ms or self.hwnd == null) return;
        self.refresh_interval_ms = interval_ms;
        _ = win.SetTimer(self.hwnd, refresh_timer, interval_ms, null);
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
        const session = self.model.activeSession() orelse {
            self.setRefreshInterval(idle_refresh_interval_ms);
            if (self.last_progress_runtime != null) {
                self.last_progress_runtime = null;
                _ = win.PostMessageW(win.GetParent(self.hwnd), self.progress_changed_message, 0, 0);
            }
            self.notifyScrollbar(false);
            return;
        };
        const runtime = session.runtime orelse {
            self.setRefreshInterval(idle_refresh_interval_ms);
            return;
        };
        const progress_generation = runtime.progressGeneration();
        if (runtime != self.last_progress_runtime or progress_generation != self.last_progress_generation) {
            self.last_progress_runtime = runtime;
            self.last_progress_generation = progress_generation;
            _ = win.PostMessageW(win.GetParent(self.hwnd), self.progress_changed_message, 0, 0);
        }
        const search_tick = runtime.searchTick(search_time_budget_ns);
        self.setRefreshInterval(if (search_tick.scanning) search_refresh_interval_ms else idle_refresh_interval_ms);
        if (search_tick.changed) self.invalidate();
        const generation = runtime.contentGeneration();
        if (runtime == self.last_runtime and generation == self.last_content_generation) return;
        self.clearHoveredLink();
        self.last_runtime = runtime;
        self.last_content_generation = generation;
        self.notifyScrollbar(false);
        self.invalidate();
    }

    pub fn updateTheme(self: *View, dark_theme: bool, high_contrast: bool, background_opacity: u8) void {
        self.dark_theme = dark_theme;
        self.high_contrast = high_contrast;
        self.background_opacity = background_opacity;
        self.invalidate();
    }

    pub fn updatePadding(self: *View, horizontal: u16, vertical: u16) void {
        self.padding_horizontal = horizontal;
        self.padding_vertical = vertical;
        self.columns = 0;
        self.rows = 0;
        self.resizeSessions();
        self.invalidate();
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
        const session = self.model.activeSession() orelse return .{ .total = 0, .offset = 0, .len = 0 };
        const runtime = session.runtime orelse return .{ .total = 0, .offset = 0, .len = 0 };
        return runtime.scrollbar() catch .{ .total = 0, .offset = 0, .len = 0 };
    }

    pub fn notifyScrollbar(self: *View, show: bool) void {
        _ = win.PostMessageW(win.GetParent(self.hwnd), self.scrollbar_changed_message, @intFromBool(show), 0);
    }

    fn scrollViewport(self: *View, delta: isize) void {
        if (delta == 0) return;
        const session = self.model.activeSession() orelse return;
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
            self.paintDirect2D(client, width, height) catch {
                self.invalidate();
            };
            return;
        }

        const padding_x = scaled(@intCast(self.padding_horizontal), win.GetDpiForWindow(self.hwnd));
        const padding_y = scaled(@intCast(self.padding_vertical), win.GetDpiForWindow(self.hwnd));
        const session = self.model.activeSession();
        self.gdi_renderer.present(dc, client, .{
            .font = self.font,
            .foreground = self.model.terminal_theme.foreground,
            .background = self.activeBackground(),
            .background_opacity = self.background_opacity,
            .dark_theme = self.dark_theme,
            .runtime = if (session) |active| active.runtime else null,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .focused = self.focused,
            .high_contrast = self.high_contrast,
            .origin_x = padding_x,
            .origin_y = padding_y,
            .hover_row = if (self.hovered_link) |hovered| hovered.link.row else null,
            .hover_start = if (self.hovered_link) |hovered| hovered.link.start_column else 0,
            .hover_end = if (self.hovered_link) |hovered| hovered.link.end_column else 0,
            .copy_flash = self.copy_flash,
        });
    }

    fn paintDirect2D(self: *View, client: win.RECT, width: i32, height: i32) !void {
        const background = if (self.high_contrast)
            win.GetSysColor(win.COLOR_WINDOW)
        else
            self.backgroundColorRef(self.activeBackground());
        const foreground = if (self.high_contrast)
            win.GetSysColor(win.COLOR_WINDOWTEXT)
        else
            colorRef(self.model.terminal_theme.foreground);
        const engine = &self.text_engine.?;
        try engine.beginFrame(@intCast(width), @intCast(height), background);
        errdefer engine.endFrame() catch {};

        const padding_x = scaled(@intCast(self.padding_horizontal), win.GetDpiForWindow(self.hwnd));
        const padding_y = scaled(@intCast(self.padding_vertical), win.GetDpiForWindow(self.hwnd));
        if (self.model.activeSession()) |session| {
            var renderer = DirectWriteCellRenderer{
                .engine = engine,
                .view = self,
                .client = client,
                .origin_x = padding_x,
                .origin_y = padding_y,
            };
            session.runtime.?.renderViewport(&renderer) catch {
                drawDirectWriteMessage(
                    engine,
                    "libghostty render state unavailable",
                    paddedRect(client, padding_x, padding_y),
                    foreground,
                    background,
                );
            };
        } else {
            drawDirectWriteMessage(
                engine,
                "Open a PowerShell or WSL session.",
                paddedRect(client, padding_x, padding_y),
                foreground,
                background,
            );
        }
        try engine.endFrame();
    }

    fn backgroundColorRef(self: *const View, color: theme.Color) win.COLORREF {
        return translucentColorRef(color, self.background_opacity, self.dark_theme);
    }

    fn cellBackgroundColorRef(self: *const View, color: theme.Color, default: theme.Color) win.COLORREF {
        if (!std.meta.eql(color, default)) return colorRef(color);
        return self.backgroundColorRef(color);
    }

    fn activeBackground(self: *View) theme.Color {
        const session = self.model.activeSession() orelse return self.model.terminal_theme.background;
        return session.background;
    }

    fn handleKey(self: *View, wparam: win.WPARAM, lparam: win.LPARAM, released: bool) bool {
        if (wparam == win.VK_F4 and win.GetKeyState(win.VK_MENU) < 0) return false;
        if (self.consumed_prompt_key == wparam) {
            if (released) self.consumed_prompt_key = null;
            return true;
        }
        if (released and (wparam == win.VK_CONTROL or wparam == win.VK_LCONTROL or wparam == win.VK_RCONTROL)) {
            self.clearHoveredLink();
        }
        if (isPasteShortcut(wparam)) {
            if (!released) self.pasteClipboard() catch |err| log.debug("unable to paste clipboard: {}", .{err});
            return true;
        }
        const runtime = if (self.model.activeSession()) |s| s.runtime else null;
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
        if (control_shift and wparam == 'G') {
            if (!released) {
                self.copyLastCommandOutput() catch |err| log.debug("unable to copy last command output: {}", .{err});
                self.suppressed_search_character = 0x07;
            }
            return true;
        }
        if (!released and control_shift and wparam == 'F') {
            if (runtime) |r| {
                r.searchBegin();
                self.setRefreshInterval(search_refresh_interval_ms);
            }
            self.suppressed_search_character = 0x06;
            self.invalidate();
            return true;
        }
        if (runtime) |r| if (r.searchEnabled()) {
            if (released) return true;
            const control = win.GetKeyState(win.VK_CONTROL) < 0;
            if (wparam == win.VK_ESCAPE or control and (wparam == 'C' or wparam == 'G')) {
                r.searchCancel();
                self.setRefreshInterval(idle_refresh_interval_ms);
            } else if (wparam == win.VK_BACK) {
                r.searchBackspace();
                self.setRefreshInterval(search_refresh_interval_ms);
            } else if (control and wparam == 'U') {
                r.searchClear();
                self.setRefreshInterval(search_refresh_interval_ms);
            } else if (wparam == win.VK_RETURN or control and wparam == 'N') {
                _ = r.searchNavigate(!(wparam == win.VK_RETURN and win.GetKeyState(win.VK_SHIFT) < 0));
            } else if (control and wparam == 'P') {
                _ = r.searchNavigate(false);
            } else {
                return true;
            }
            self.suppressed_search_character = searchControlCharacter(wparam, control);
            self.notifyScrollbar(true);
            self.invalidate();
            return true;
        };
        if (input.keyFromMessage(wparam, lparam) == null) return false;
        if (!released) self.clearSelection();
        const active_runtime = if (self.model.activeSession()) |session| session.runtime else null;
        if (!released and active_runtime == null) return true;
        const event = self.input_state.keyEvent(wparam, lparam, released) orelse return true;
        const index = @intFromEnum(event.key);
        if (event.action == .press) self.key_runtimes[index] = active_runtime;
        const key_runtime = self.key_runtimes[index] orelse return true;
        if (event.action == .release) self.key_runtimes[index] = null;
        if (!self.runtimeIsLive(key_runtime)) return true;
        const encoded = key_runtime.sendKey(event.key, event.action, input.currentModifiers(), event.unshifted_codepoint) catch |err| {
            log.debug("unable to send terminal key: {}", .{err});
            return true;
        };
        if (!released and encoded) self.input_state.suppressEncodedCharacter(event.key, event.unshifted_codepoint);
        return true;
    }

    fn releasePressedKeys(self: *View) void {
        for (std.enums.values(Terminal.Key)) |key| {
            const unshifted_codepoint = self.input_state.takePressed(key) orelse continue;
            const index = @intFromEnum(key);
            const runtime = self.key_runtimes[index];
            self.key_runtimes[index] = null;
            if (runtime) |current| {
                if (self.runtimeIsLive(current)) _ = current.sendKey(key, .release, input.currentModifiers(), unshifted_codepoint) catch |err| {
                    log.debug("unable to release terminal key: {}", .{err});
                };
            }
        }
    }

    fn runtimeIsLive(self: *const View, runtime: *SessionRuntime) bool {
        for (self.model.sessions.items) |session| if (session.runtime == runtime) return true;
        return false;
    }

    fn handleCharacter(self: *View, code_unit: u16) void {
        if (self.suppressed_search_character == code_unit) {
            self.suppressed_search_character = null;
            return;
        }
        self.suppressed_search_character = null;
        if (self.input_state.suppressCharacter(code_unit)) return;
        self.clearSelection();
        const session = self.model.activeSession() orelse return;
        var utf8: [4]u8 = undefined;
        const encoded = self.input_state.encodeUnsuppressedCharacter(code_unit, &utf8) orelse return;
        if (session.runtime.?.searchEnabled()) {
            session.runtime.?.searchAppend(encoded) catch {};
            self.setRefreshInterval(search_refresh_interval_ms);
            self.invalidate();
            return;
        }
        session.runtime.?.write(encoded) catch |err| {
            log.debug("unable to write terminal input: {}", .{err});
        };
    }

    fn beginSelection(self: *View, lparam: win.LPARAM) void {
        if (win.GetKeyState(win.VK_CONTROL) < 0 and self.openLinkAt(lparam)) return;
        if (win.GetKeyState(win.VK_SHIFT) >= 0 and self.beginProtocolButton(.left, lparam)) {
            _ = win.SetCapture(self.hwnd);
            return;
        }
        const point = self.mousePoint(lparam, false) orelse {
            self.clearSelection();
            return;
        };
        const session = self.model.activeSession() orelse return;
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
        _ = win.SetCapture(self.hwnd);
        _ = win.SetTimer(self.hwnd, selection_scroll_timer, 33, null);
        self.invalidate();
    }

    fn updateSelection(self: *View, lparam: win.LPARAM) void {
        if (self.protocol_runtime) |runtime| {
            _ = self.sendMouseTo(runtime, .motion, self.protocol_button orelse .none, clientPoint(lparam), self.protocol_button != null);
            return;
        }
        if (win.GetKeyState(win.VK_SHIFT) >= 0) if (self.model.activeSession()) |session| if (session.runtime) |runtime| {
            _ = self.sendMouseTo(runtime, .motion, .none, clientPoint(lparam), false);
        };
        if (self.selection == null or !self.selection.?.dragging) self.updateHoveredLink(lparam);
        const point = self.mousePoint(lparam, true) orelse return;
        const current = self.selection orelse return;
        if (!current.dragging or std.meta.eql(current.focus, point)) return;
        const session = self.model.activeSession() orelse {
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
            if (win.GetCapture() == self.hwnd) _ = win.ReleaseCapture();
            return;
        }
        if (self.selection == null or !self.selection.?.dragging) return;
        self.updateSelection(lparam);
        if (self.selection == null) return;
        self.selection.?.dragging = false;
        self.selection.?.runtime.endSelectionAnchor();
        _ = win.KillTimer(self.hwnd, selection_scroll_timer);
        if (win.GetCapture() == self.hwnd) _ = win.ReleaseCapture();
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
        if (win.GetCapture() == self.hwnd) _ = win.ReleaseCapture();
    }

    fn beginProtocolButton(self: *View, button: Terminal.MouseButton, lparam: win.LPARAM) bool {
        if (self.protocol_button != null) return true;
        const session = self.model.activeSession() orelse return false;
        const runtime = session.runtime orelse return false;
        if (!self.sendMouseTo(runtime, .press, button, clientPoint(lparam), true)) return false;
        self.protocol_button = button;
        self.protocol_runtime = runtime;
        _ = win.SetCapture(self.hwnd);
        return true;
    }

    fn sendMouseTo(self: *View, runtime: *SessionRuntime, action: Terminal.MouseAction, button: Terminal.MouseButton, point: Terminal.PixelPoint, pressed: bool) bool {
        const geometry = self.mouseGeometry() orelse return false;
        return runtime.sendMouse(action, button, point, input.currentModifiers(), geometry, pressed) catch false;
    }

    fn mouseGeometry(self: *View) ?Terminal.MouseGeometry {
        var rect: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &rect) == 0) return null;
        const dpi = win.GetDpiForWindow(self.hwnd);
        const px: u32 = @intCast(@max(scaled(@intCast(self.padding_horizontal), dpi), 0));
        const py: u32 = @intCast(@max(scaled(@intCast(self.padding_vertical), dpi), 0));
        const width: u32 = @intCast(@max(rect.right - rect.left, 1));
        const height: u32 = @intCast(@max(rect.bottom - rect.top, 1));
        const grid_width = @as(u32, self.columns) * self.cell_width;
        const grid_height = @as(u32, self.rows) * self.cell_height;
        return .{
            .screen_width = width,
            .screen_height = height,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .padding_top = py,
            .padding_bottom = height -| py -| grid_height,
            .padding_left = px,
            .padding_right = width -| px -| grid_width,
        };
    }

    fn lastMouseClientPoint(self: *View) Terminal.PixelPoint {
        var point: win.POINT = undefined;
        if (win.GetCursorPos(&point) == 0 or win.ScreenToClient(self.hwnd, &point) == 0) return .{ .x = 0, .y = 0 };
        return .{ .x = point.x, .y = point.y };
    }

    fn sendWheel(self: *View, delta: i32, horizontal: bool, point: Terminal.PixelPoint) bool {
        const session = self.model.activeSession() orelse return false;
        const runtime = session.runtime orelse return false;
        const remainder = if (horizontal) &self.protocol_hwheel_remainder else &self.protocol_wheel_remainder;
        const accumulated = wheelAccumulation(remainder.*, delta);
        if (accumulated.steps == 0) {
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
        const active = self.model.activeSession() orelse return self.abandonSelection();
        if (active.runtime != self.selection.?.runtime) return self.abandonSelection();
        var cursor: win.POINT = undefined;
        if (win.GetCursorPos(&cursor) == 0 or win.ScreenToClient(self.hwnd, &cursor) == 0) return;
        const dpi = win.GetDpiForWindow(self.hwnd);
        const top = scaled(@intCast(self.padding_vertical), dpi);
        const bottom = top + @as(i32, self.rows) * @as(i32, @intCast(self.cell_height));
        const distance = if (cursor.y < top) cursor.y - top else if (cursor.y >= bottom) cursor.y - bottom + 1 else return;
        const rows_per_tick: isize = @intCast(@min(@divTrunc(@abs(distance), self.cell_height) + 1, 8));
        self.scrollViewport(if (distance < 0) -rows_per_tick else rows_per_tick);
        const point = self.pixelPoint(cursor.x - scaled(@intCast(self.padding_horizontal), dpi), cursor.y - top);
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
        if (win.GetCapture() == self.hwnd) _ = win.ReleaseCapture();
        self.invalidate();
    }

    fn clearSelection(self: *View) void {
        if (self.selection == null) return;
        const selection = self.selection.?;
        self.selection = null;
        _ = win.KillTimer(self.hwnd, selection_scroll_timer);
        selection.runtime.endSelectionAnchor();
        if (win.GetCapture() == self.hwnd) _ = win.ReleaseCapture();
        if (self.model.activeSession()) |session| {
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
        const dpi = win.GetDpiForWindow(self.hwnd);
        var x = mouseCoordinate(lparam, 0) - scaled(@intCast(self.padding_horizontal), dpi);
        var y = mouseCoordinate(lparam, 16) - scaled(@intCast(self.padding_vertical), dpi);
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
        const session = self.model.activeSession() orelse return;
        const runtime = session.runtime orelse return;
        if (runtime != selection.runtime) return;
        const text = try runtime.selectedTextAlloc(std.heap.page_allocator);
        defer std.heap.page_allocator.free(text);
        try setClipboardText(self.hwnd, text);
        self.copy_flash = true;
        _ = win.SetTimer(self.hwnd, copy_flash_timer, copy_flash_duration_ms, null);
        self.invalidate();
    }

    fn copyLastCommandOutput(self: *View) !void {
        const session = self.model.activeSession() orelse return;
        const runtime = session.runtime orelse return;
        const text = try runtime.lastCommandOutputAlloc(std.heap.page_allocator) orelse return;
        defer std.heap.page_allocator.free(text);
        try setClipboardText(self.hwnd, text);
    }

    fn pasteClipboard(self: *View) !void {
        const session = self.model.activeSession() orelse return;
        const runtime = session.runtime orelse return;
        const text = try clipboardTextAlloc(self.hwnd, std.heap.page_allocator);
        defer std.heap.page_allocator.free(text);
        self.clearSelection();
        try runtime.paste(text);
    }

    fn pasteDroppedFiles(self: *View, drop: win.HDROP) !void {
        const session = self.model.activeSession() orelse return;
        const runtime = session.runtime orelse return;
        const shell: shell_quote.Shell = switch (session.shell) {
            .powershell, .pwsh => .powershell,
            .cmd, .custom => .windows,
            .wsl => .wsl,
        };
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
            const quoted = try shell_quote.pathAlloc(std.heap.page_allocator, path, shell);
            defer std.heap.page_allocator.free(quoted);
            if (command.items.len != 0) try command.append(std.heap.page_allocator, ' ');
            try command.appendSlice(std.heap.page_allocator, quoted);
        }
        if (command.items.len == 0) return;
        self.clearSelection();
        try runtime.paste(command.items);
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
        const session = self.model.activeSession() orelse return;
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
        const session = self.model.activeSession() orelse return false;
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

const DirectWriteCellRenderer = struct {
    engine: *TextEngine,
    view: *View,
    client: win.RECT,
    origin_x: i32,
    origin_y: i32,
    frame: ?Terminal.Frame = null,
    search_matches: []const SearchMatch = &.{},
    search_active: ?usize = null,
    search_offset: u64 = 0,
    search_enabled: bool = false,
    search_query: []const u8 = "",
    search_scanning: bool = false,

    pub fn searchState(self: *DirectWriteCellRenderer, enabled: bool, query: []const u8, matches: []const SearchMatch, active: ?usize, offset: u64, scanning: bool) void {
        self.search_enabled = enabled;
        self.search_query = query;
        self.search_matches = matches;
        self.search_active = active;
        self.search_offset = offset;
        self.search_scanning = scanning;
    }

    pub fn beginFrame(self: *DirectWriteCellRenderer, frame: Terminal.Frame) void {
        self.frame = frame;
    }

    pub fn beginRow(self: *DirectWriteCellRenderer, y: u16) void {
        self.engine.beginRow(
            y,
            @floatFromInt(self.origin_x),
            @floatFromInt(self.origin_y + @as(i32, y) * @as(i32, @intCast(self.view.cell_height))),
            @floatFromInt(self.view.cell_width),
            @floatFromInt(self.view.cell_height),
        );
    }

    pub fn drawCell(self: *DirectWriteCellRenderer, cell: Terminal.Cell) void {
        const left = self.origin_x + @as(i32, cell.x) * @as(i32, @intCast(self.view.cell_width));
        const top = self.origin_y + @as(i32, cell.y) * @as(i32, @intCast(self.view.cell_height));
        const solid_cursor = self.view.focused and
            self.frame.?.cursor_visible and
            self.frame.?.cursor_style == .block and
            cell.x >= self.frame.?.cursor_x and
            cell.x < self.frame.?.cursor_x + self.frame.?.cursor_columns and
            cell.y == self.frame.?.cursor_y;
        const normal_foreground = if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(cell.foreground);
        const normal_background = if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOW) else self.view.cellBackgroundColorRef(cell.background, self.frame.?.background);
        const search_kind = searchHighlight(self.search_matches, self.search_active, self.search_offset, cell.x, cell.y);
        const foreground = if (search_kind != 0 and self.view.high_contrast)
            win.GetSysColor(win.COLOR_HIGHLIGHTTEXT)
        else if (search_kind == 2)
            rgb(0, 0, 0)
        else if (search_kind == 1)
            rgb(255, 255, 255)
        else if (cell.selected)
            (if (self.view.copy_flash and !self.view.high_contrast) normal_background else win.GetSysColor(win.COLOR_HIGHLIGHTTEXT))
        else if (solid_cursor)
            normal_background
        else
            normal_foreground;
        const background = if (search_kind != 0 and self.view.high_contrast)
            win.GetSysColor(win.COLOR_HIGHLIGHT)
        else if (search_kind == 2)
            rgb(255, 140, 0)
        else if (search_kind == 1)
            rgb(110, 90, 20)
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
            @floatFromInt(self.view.cell_width),
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
        );
    }

    pub fn endRow(self: *DirectWriteCellRenderer, _: u16) void {
        self.engine.endRow();
    }

    pub fn endFrame(self: *DirectWriteCellRenderer, frame: Terminal.Frame) void {
        if (self.search_enabled) {
            var status: [512]u8 = undefined;
            const text = std.fmt.bufPrint(&status, " Find: {s}  {d} match{s}{s} ", .{ self.search_query, self.search_matches.len, if (self.search_matches.len == 1) "" else "es", if (self.search_scanning) " (scanning)" else "" }) catch " Find ";
            drawDirectWriteMessage(self.engine, text, .{ .left = self.origin_x, .top = self.client.bottom - self.origin_y - @as(i32, @intCast(self.view.cell_height)), .right = self.client.right - self.origin_x, .bottom = self.client.bottom - self.origin_y }, win.GetSysColor(win.COLOR_HIGHLIGHTTEXT), win.GetSysColor(win.COLOR_HIGHLIGHT));
        }
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

fn searchHighlight(matches: []const SearchMatch, active: ?usize, offset: u64, x: u16, y: u16) u2 {
    return search.highlight(matches, active, offset + y, x);
}

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
        refresh_message => {
            if (view) |current| {
                current.refresh_pending.store(false, .release);
                current.refreshIfNeeded();
            }
            return 0;
        },
        win.WM_CREATE => {
            _ = win.SetTimer(hwnd, refresh_timer, idle_refresh_interval_ms, null);
            _ = win.SetFocus(hwnd);
            return 0;
        },
        win.WM_LBUTTONDOWN, win.WM_LBUTTONDBLCLK => {
            _ = win.SetFocus(hwnd);
            if (view) |current| current.beginSelection(lparam);
            return 0;
        },
        win.WM_MBUTTONDOWN, win.WM_RBUTTONDOWN => {
            _ = win.SetFocus(hwnd);
            if (win.GetKeyState(win.VK_SHIFT) >= 0) if (view) |current| {
                if (current.beginProtocolButton(if (message == win.WM_MBUTTONDOWN) .middle else .right, lparam)) return 0;
            };
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
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
        win.WM_LBUTTONUP, win.WM_MBUTTONUP, win.WM_RBUTTONUP => {
            if (view) |current| current.finishSelection(switch (message) {
                win.WM_LBUTTONUP => .left,
                win.WM_MBUTTONUP => .middle,
                else => .right,
            }, lparam);
            return 0;
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
                current.releasePressedKeys();
                current.invalidate();
            }
            return 0;
        },
        win.WM_GETDLGCODE => return win.DLGC_WANTTAB,
        win.WM_KEYDOWN, win.WM_SYSKEYDOWN => {
            if (view) |current| {
                if (current.handleKey(wparam, lparam, false)) return 0;
            }
            return win.DefWindowProcW(hwnd, message, wparam, lparam);
        },
        win.WM_KEYUP, win.WM_SYSKEYUP => {
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
            if (view) |current| current.resizeSessions();
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
            if (view) |current| current.deinitResources();
            return 0;
        },
        win.WM_NCDESTROY => {
            const result = win.DefWindowProcW(hwnd, message, wparam, lparam);
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, 0);
            if (view) |current| {
                current.refresh_hwnd.store(0, .release);
                current.refresh_pending.store(false, .release);
                current.hwnd = null;
            }
            return result;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

const CellSize = struct { width: u32, height: u32 };

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

fn saturatingClick(value: u2) u2 {
    return if (value < 3) value + 1 else 3;
}

const WheelAccumulation = struct { steps: i32, remainder: i32 };
fn wheelAccumulation(remainder: i32, delta: i32) WheelAccumulation {
    const total = remainder + delta;
    const steps = @divTrunc(total, win.WHEEL_DELTA);
    return .{ .steps = steps, .remainder = total - steps * win.WHEEL_DELTA };
}

fn isPasteShortcut(key: win.WPARAM) bool {
    const control = win.GetKeyState(win.VK_CONTROL) < 0;
    const shift = win.GetKeyState(win.VK_SHIFT) < 0;
    return shift and (key == win.VK_INSERT or control and key == 'V');
}

fn searchControlCharacter(key: win.WPARAM, control: bool) ?u16 {
    return switch (key) {
        win.VK_ESCAPE => 0x1b,
        win.VK_BACK => 0x08,
        win.VK_RETURN => 0x0d,
        else => if (control and key >= 'A' and key <= 'Z') @intCast(key - 'A' + 1) else null,
    };
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
    const extra = std.mem.count(u8, text, "\n");
    const windows_text = try allocator.alloc(u8, text.len + extra);
    defer allocator.free(windows_text);
    var index: usize = 0;
    for (text) |byte| {
        if (byte == '\n') {
            windows_text[index] = '\r';
            index += 1;
        }
        windows_text[index] = byte;
        index += 1;
    }

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

fn drawDirectWriteMessage(
    engine: *TextEngine,
    text: []const u8,
    rect: win.RECT,
    foreground: u32,
    background: u32,
) void {
    var wide: [16 * 1024]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(&wide, text) catch return;
    engine.drawCell(
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

fn encodeUtf16(codepoints: []const u32, output: *[32]u16) usize {
    var length: usize = 0;
    for (codepoints) |codepoint| {
        if (codepoint <= 0xffff) {
            if (codepoint >= 0xd800 and codepoint <= 0xdfff) continue;
            output[length] = @intCast(codepoint);
            length += 1;
        } else if (codepoint <= 0x10ffff and length + 1 < output.len) {
            const value = codepoint - 0x10000;
            output[length] = @intCast(0xd800 + (value >> 10));
            output[length + 1] = @intCast(0xdc00 + (value & 0x3ff));
            length += 2;
        }
    }
    return length;
}

fn paddedRect(rect: win.RECT, padding_x: i32, padding_y: i32) win.RECT {
    return .{
        .left = rect.left + padding_x,
        .top = rect.top + padding_y,
        .right = rect.right - padding_x,
        .bottom = rect.bottom - padding_y,
    };
}

fn colorRef(color: theme.Color) win.COLORREF {
    return rgb(color.red, color.green, color.blue);
}

fn rgb(red: u8, green: u8, blue: u8) win.COLORREF {
    return @as(win.COLORREF, red) | (@as(win.COLORREF, green) << 8) | (@as(win.COLORREF, blue) << 16);
}

fn translucentColorRef(color: theme.Color, opacity_percent: u8, dark: bool) win.COLORREF {
    if (opacity_percent == 100) return colorRef(color);
    const backdrop = if (dark) theme.Color{ .red = 0x20, .green = 0x20, .blue = 0x20 } else theme.Color{ .red = 0xf3, .green = 0xf3, .blue = 0xf3 };
    const opacity: u16 = opacity_percent;
    return rgb(
        @intCast((@as(u16, color.red) * opacity + @as(u16, backdrop.red) * (100 - opacity)) / 100),
        @intCast((@as(u16, color.green) * opacity + @as(u16, backdrop.green) * (100 - opacity)) / 100),
        @intCast((@as(u16, color.blue) * opacity + @as(u16, backdrop.blue) * (100 - opacity)) / 100),
    );
}

fn blendColorRef(foreground: win.COLORREF, background: win.COLORREF) win.COLORREF {
    return rgb(
        @intCast(((foreground & 0xff) + (background & 0xff)) / 2),
        @intCast((((foreground >> 8) & 0xff) + ((background >> 8) & 0xff)) / 2),
        @intCast((((foreground >> 16) & 0xff) + ((background >> 16) & 0xff)) / 2),
    );
}

test "clipboard newlines normalize without changing lone carriage returns" {
    var text = [_]u8{ 'a', '\r', '\n', 'b', '\n', 'c', '\r', 'd' };
    try std.testing.expectEqualStrings("a\nb\nc\rd", normalizeClipboardNewlines(&text));
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
