const native = @cImport({
    @cInclude("directwrite_renderer.h");
});

pub const Engine = struct {
    handle: *native.ZigonautTextEngine,

    pub const Metrics = struct {
        width: u32,
        height: u32,
        baseline: u32,
    };

    pub fn init(font_family: []const u8, font_size: u32, dpi: u32) !Engine {
        var wide_name = [_]u16{0} ** 128;
        _ = @import("std").unicode.utf8ToUtf16Le(
            wide_name[0 .. wide_name.len - 1],
            font_family,
        ) catch return error.InvalidFontFamily;
        var handle: ?*native.ZigonautTextEngine = null;
        const result = native.zigonaut_text_engine_create(
            &wide_name,
            font_size,
            dpi,
            &handle,
        );
        if (result < 0 or handle == null) return error.DirectWriteInitializationFailed;
        return .{ .handle = handle.? };
    }

    pub fn deinit(self: *Engine) void {
        native.zigonaut_text_engine_destroy(self.handle);
    }

    pub fn setDpi(self: *Engine, dpi: u32) !void {
        if (native.zigonaut_text_engine_set_dpi(self.handle, dpi) < 0) {
            return error.DirectWriteDpiUpdateFailed;
        }
    }

    pub fn metrics(self: *const Engine) Metrics {
        const value = native.zigonaut_text_engine_get_cell_metrics(self.handle);
        return .{
            .width = value.width,
            .height = value.height,
            .baseline = value.baseline,
        };
    }

    pub fn setWindow(self: *Engine, hwnd: ?*anyopaque) !void {
        if (native.zigonaut_text_engine_set_window(
            self.handle,
            @intFromPtr(hwnd),
        ) < 0) {
            return error.DirectWriteWindowFailed;
        }
    }

    pub fn beginFrame(self: *Engine, width: u32, height: u32, background: u32) !void {
        if (native.zigonaut_text_engine_begin_frame(
            self.handle,
            width,
            height,
            background,
        ) < 0) return error.Direct2DBeginFrameFailed;
    }

    pub fn drawCell(
        self: *Engine,
        text: []const u16,
        left: f32,
        top: f32,
        width: f32,
        height: f32,
        foreground: u32,
        background: u32,
        bold: bool,
        italic: bool,
    ) void {
        _ = native.zigonaut_text_engine_draw_cell(
            self.handle,
            if (text.len == 0) null else text.ptr,
            @intCast(text.len),
            left,
            top,
            width,
            height,
            foreground,
            background,
            @intFromBool(bold),
            @intFromBool(italic),
        );
    }

    pub fn drawCursor(
        self: *Engine,
        left: f32,
        top: f32,
        width: f32,
        height: f32,
        color: u32,
    ) void {
        native.zigonaut_text_engine_draw_cursor(
            self.handle,
            left,
            top,
            width,
            height,
            color,
        );
    }

    pub fn endFrame(self: *Engine) !void {
        if (native.zigonaut_text_engine_end_frame(self.handle) < 0) {
            return error.Direct2DEndFrameFailed;
        }
    }
};
