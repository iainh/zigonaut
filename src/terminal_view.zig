const std = @import("std");
const App = @import("app.zig").App;
const SessionRuntime = @import("session.zig").SessionRuntime;
const Terminal = @import("terminal.zig").Terminal;
const TextEngine = @import("directwrite_renderer.zig").Engine;
const GdiRenderer = @import("gdi_renderer.zig");
const input = @import("input.zig");
const theme = @import("theme.zig");

const win = @import("win32.zig").c;
const log = std.log.scoped(.terminal_view);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZigonautTerminalView");
const refresh_timer = 1;
const logical_padding = 8;
const wheel_rows = 3;

pub const View = struct {
    hwnd: win.HWND = null,
    model: *App,
    font: win.HFONT,
    text_engine: ?TextEngine,
    input_state: input.State = .{},
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
    last_titles_generation: u64 = 0,
    selection: ?MouseSelection = null,
    titles_changed_message: win.UINT,
    shell_exited_message: win.UINT,
    scrollbar_changed_message: win.UINT,
    wheel_remainder: i32 = 0,

    pub fn registerClass(instance: win.HINSTANCE, cursor: win.HCURSOR) !void {
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
        if (win.RegisterClassExW(&window_class) == 0) return error.RegisterTerminalViewClassFailed;
    }

    pub fn init(
        parent: win.HWND,
        model: *App,
        font: win.HFONT,
        font_family: []const u8,
        font_size: u16,
        dpi: u32,
        titles_changed_message: win.UINT,
        shell_exited_message: win.UINT,
        scrollbar_changed_message: win.UINT,
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
            .titles_changed_message = titles_changed_message,
            .shell_exited_message = shell_exited_message,
            .scrollbar_changed_message = scrollbar_changed_message,
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
        if (self.text_engine) |*engine| engine.setWindow(self.hwnd) catch |err| {
            log.warn("DirectWrite window initialization failed; using GDI fallback: {}", .{err});
            engine.deinit();
            self.text_engine = null;
        };
    }

    fn deinitResources(self: *View) void {
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

    pub fn invalidate(self: *View) void {
        _ = win.InvalidateRect(self.hwnd, null, 0);
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
        const session = self.model.activeSession() orelse {
            self.notifyScrollbar(false);
            return;
        };
        const runtime = session.runtime orelse return;
        const generation = runtime.contentGeneration();
        if (runtime == self.last_runtime and generation == self.last_content_generation) return;
        self.last_runtime = runtime;
        self.last_content_generation = generation;
        self.notifyScrollbar(false);
        self.invalidate();
    }

    pub fn updateTheme(self: *View, dark_theme: bool, high_contrast: bool) void {
        self.dark_theme = dark_theme;
        self.high_contrast = high_contrast;
        self.invalidate();
    }

    fn resizeSessions(self: *View) void {
        var client: win.RECT = undefined;
        if (win.GetClientRect(self.hwnd, &client) == 0) return;

        const padding = scaled(logical_padding, win.GetDpiForWindow(self.hwnd));
        const inner_width = @max(client.right - 2 * padding, 1);
        const inner_height = @max(client.bottom - 2 * padding, 1);
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
        const steps = @divTrunc(self.wheel_remainder, win.WHEEL_DELTA);
        self.wheel_remainder -= steps * win.WHEEL_DELTA;
        self.scrollViewport(-@as(isize, steps * wheel_rows));
    }

    fn handleMouseWheel(self: *View, wparam: usize) void {
        const raw_delta: u16 = @truncate(wparam >> 16);
        self.handleMouseWheelDelta(@as(i16, @bitCast(raw_delta)));
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

        const padding = scaled(logical_padding, win.GetDpiForWindow(self.hwnd));
        const session = self.model.activeSession();
        self.gdi_renderer.present(dc, client, .{
            .font = self.font,
            .foreground = self.model.terminal_theme.foreground,
            .background = self.activeBackground(),
            .runtime = if (session) |active| active.runtime else null,
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .focused = self.focused,
            .high_contrast = self.high_contrast,
            .origin_x = padding,
            .origin_y = padding,
        });
    }

    fn paintDirect2D(self: *View, client: win.RECT, width: i32, height: i32) !void {
        const background = if (self.high_contrast)
            win.GetSysColor(win.COLOR_WINDOW)
        else
            colorRef(self.activeBackground());
        const foreground = if (self.high_contrast)
            win.GetSysColor(win.COLOR_WINDOWTEXT)
        else
            colorRef(self.model.terminal_theme.foreground);
        const engine = &self.text_engine.?;
        try engine.beginFrame(@intCast(width), @intCast(height), background);
        errdefer engine.endFrame() catch {};

        const padding = scaled(logical_padding, win.GetDpiForWindow(self.hwnd));
        if (self.model.activeSession()) |session| {
            var renderer = DirectWriteCellRenderer{
                .engine = engine,
                .view = self,
                .client = client,
                .origin_x = padding,
                .origin_y = padding,
            };
            session.runtime.?.renderViewport(&renderer) catch {
                drawDirectWriteMessage(
                    engine,
                    "libghostty render state unavailable",
                    paddedRect(client, padding),
                    foreground,
                    background,
                );
            };
        } else {
            drawDirectWriteMessage(
                engine,
                "Open a PowerShell or WSL session.",
                paddedRect(client, padding),
                foreground,
                background,
            );
        }
        try engine.endFrame();
    }

    fn activeBackground(self: *View) theme.Color {
        const session = self.model.activeSession() orelse return self.model.terminal_theme.background;
        return session.background;
    }

    fn handleKey(self: *View, wparam: win.WPARAM, lparam: win.LPARAM, released: bool) bool {
        if (wparam == win.VK_F4 and win.GetKeyState(win.VK_MENU) < 0) return false;
        if (isPasteShortcut(wparam)) {
            if (!released) self.pasteClipboard() catch |err| log.debug("unable to paste clipboard: {}", .{err});
            return true;
        }
        if (input.keyFromVirtualKey(wparam) == null) return false;
        if (!released) self.clearSelection();
        const session = self.model.activeSession() orelse return true;
        const event = self.input_state.keyEvent(wparam, lparam, released).?;
        session.runtime.?.sendKey(event.key, event.action, input.currentModifiers()) catch |err| {
            log.debug("unable to send terminal key: {}", .{err});
        };
        return true;
    }

    fn handleCharacter(self: *View, code_unit: u16) void {
        if (self.input_state.suppressCharacter(code_unit)) return;
        self.clearSelection();
        const session = self.model.activeSession() orelse return;
        var utf8: [4]u8 = undefined;
        const encoded = self.input_state.encodeUnsuppressedCharacter(code_unit, &utf8) orelse return;
        session.runtime.?.write(encoded) catch |err| {
            log.debug("unable to write terminal input: {}", .{err});
        };
    }

    fn beginSelection(self: *View, lparam: win.LPARAM) void {
        const point = self.mousePoint(lparam, false) orelse {
            self.clearSelection();
            return;
        };
        const session = self.model.activeSession() orelse return;
        const runtime = session.runtime orelse return;
        self.clearSelection();
        self.selection = .{
            .range = .{ .anchor = point, .focus = point },
            .runtime = runtime,
            .dragging = true,
        };
        _ = win.SetCapture(self.hwnd);
        self.invalidate();
    }

    fn updateSelection(self: *View, lparam: win.LPARAM) void {
        const point = self.mousePoint(lparam, true) orelse return;
        const current = self.selection orelse return;
        if (!current.dragging or current.range.focus.x == point.x and current.range.focus.y == point.y) return;
        const session = self.model.activeSession() orelse {
            self.abandonSelection();
            return;
        };
        if (session.runtime != current.runtime) {
            self.abandonSelection();
            return;
        }
        if (self.selection) |*selection| {
            selection.range.focus = point;
            selection.runtime.setSelection(selection.range) catch |err| {
                log.debug("unable to update terminal selection: {}", .{err});
                return;
            };
            selection.moved = true;
            self.invalidate();
        }
    }

    fn finishSelection(self: *View, lparam: win.LPARAM) void {
        if (self.selection == null or !self.selection.?.dragging) return;
        self.updateSelection(lparam);
        if (self.selection == null) return;
        self.selection.?.dragging = false;
        if (win.GetCapture() == self.hwnd) _ = win.ReleaseCapture();
        if (!self.selection.?.moved) {
            self.selection = null;
            self.invalidate();
            return;
        }
        self.copySelection() catch |err| log.debug("unable to copy terminal selection: {}", .{err});
    }

    fn cancelSelectionDrag(self: *View) void {
        if (self.selection) |*selection| selection.dragging = false;
    }

    fn abandonSelection(self: *View) void {
        self.selection = null;
        if (win.GetCapture() == self.hwnd) _ = win.ReleaseCapture();
        self.invalidate();
    }

    fn clearSelection(self: *View) void {
        if (self.selection == null) return;
        const selection = self.selection.?;
        self.selection = null;
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
        const padding = scaled(logical_padding, win.GetDpiForWindow(self.hwnd));
        var x = mouseCoordinate(lparam, 0) - padding;
        var y = mouseCoordinate(lparam, 16) - padding;
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
    }

    fn pasteClipboard(self: *View) !void {
        const session = self.model.activeSession() orelse return;
        const runtime = session.runtime orelse return;
        const text = try clipboardTextAlloc(self.hwnd, std.heap.page_allocator);
        defer std.heap.page_allocator.free(text);
        self.clearSelection();
        try runtime.paste(text);
    }
};

const MouseSelection = struct {
    range: Terminal.Selection,
    runtime: *SessionRuntime,
    dragging: bool,
    moved: bool = false,
};

const DirectWriteCellRenderer = struct {
    engine: *TextEngine,
    view: *View,
    client: win.RECT,
    origin_x: i32,
    origin_y: i32,
    frame: ?Terminal.Frame = null,

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
        const normal_background = if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOW) else colorRef(cell.background);
        const foreground = if (cell.selected) win.GetSysColor(win.COLOR_HIGHLIGHTTEXT) else if (solid_cursor) normal_background else normal_foreground;
        const background = if (cell.selected)
            win.GetSysColor(win.COLOR_HIGHLIGHT)
        else if (solid_cursor)
            (if (self.view.high_contrast) win.GetSysColor(win.COLOR_WINDOWTEXT) else colorRef(self.frame.?.cursor))
        else
            normal_background;
        const underline_color = if (self.view.high_contrast) foreground else colorRef(cell.underline_color);
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
            cell.underline,
            @intFromEnum(cell.occupancy),
        );
    }

    pub fn endRow(self: *DirectWriteCellRenderer, _: u16) void {
        self.engine.endRow();
    }

    pub fn endFrame(self: *DirectWriteCellRenderer, frame: Terminal.Frame) void {
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
        win.WM_CREATE => {
            _ = win.SetTimer(hwnd, refresh_timer, 33, null);
            _ = win.SetFocus(hwnd);
            return 0;
        },
        win.WM_LBUTTONDOWN => {
            _ = win.SetFocus(hwnd);
            if (view) |current| current.beginSelection(lparam);
            return 0;
        },
        win.WM_MOUSEMOVE => {
            if (view) |current| current.updateSelection(lparam);
            return 0;
        },
        win.WM_LBUTTONUP => {
            if (view) |current| current.finishSelection(lparam);
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
            if (view) |current| current.handleMouseWheel(wparam);
            return 0;
        },
        win.WM_TIMER => {
            if (wparam == refresh_timer) {
                if (view) |current| current.refreshIfNeeded();
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
            if (view) |current| current.deinitResources();
            return 0;
        },
        win.WM_NCDESTROY => {
            const result = win.DefWindowProcW(hwnd, message, wparam, lparam);
            _ = win.SetWindowLongPtrW(hwnd, win.GWLP_USERDATA, 0);
            if (view) |current| current.hwnd = null;
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

fn isPasteShortcut(key: win.WPARAM) bool {
    const control = win.GetKeyState(win.VK_CONTROL) < 0;
    const shift = win.GetKeyState(win.VK_SHIFT) < 0;
    return shift and (key == win.VK_INSERT or control and key == 'V');
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

fn paddedRect(rect: win.RECT, padding: i32) win.RECT {
    return .{
        .left = rect.left + padding,
        .top = rect.top + padding,
        .right = rect.right - padding,
        .bottom = rect.bottom - padding,
    };
}

fn colorRef(color: theme.Color) win.COLORREF {
    return rgb(color.red, color.green, color.blue);
}

fn rgb(red: u8, green: u8, blue: u8) win.COLORREF {
    return @as(win.COLORREF, red) | (@as(win.COLORREF, green) << 8) | (@as(win.COLORREF, blue) << 16);
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
