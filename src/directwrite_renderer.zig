const native = @import("win32.zig").c;

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

    pub fn refreshRenderingParams(self: *Engine) !void {
        if (native.zigonaut_text_engine_refresh_rendering_params(self.handle) < 0) {
            return error.DirectWriteRenderingParamsUpdateFailed;
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
        underline_color: u32,
        bold: bool,
        italic: bool,
        faint: bool,
        strikethrough: bool,
        overline: bool,
        underline: u8,
        occupancy: u8,
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
            underline_color,
            @intFromBool(bold),
            @intFromBool(italic),
            @intFromBool(faint),
            @intFromBool(strikethrough),
            @intFromBool(overline),
            underline,
            @intCast(occupancy),
        );
    }

    pub fn beginRow(
        self: *Engine,
        row: u16,
        origin_x: f32,
        top: f32,
        cell_width: f32,
        cell_height: f32,
    ) void {
        native.zigonaut_text_engine_begin_row(
            self.handle,
            row,
            origin_x,
            top,
            cell_width,
            cell_height,
        );
    }

    pub fn endRow(self: *Engine) void {
        native.zigonaut_text_engine_end_row(self.handle);
    }

    pub fn drawCursor(
        self: *Engine,
        left: f32,
        top: f32,
        width: f32,
        height: f32,
        color: u32,
        style: u8,
    ) void {
        native.zigonaut_text_engine_draw_cursor(
            self.handle,
            left,
            top,
            width,
            height,
            color,
            style,
        );
    }

    pub fn endFrame(self: *Engine) !void {
        if (native.zigonaut_text_engine_end_frame(self.handle) < 0) {
            return error.Direct2DEndFrameFailed;
        }
    }
};

test "cluster advances fit exact terminal spans" {
    const std = @import("std");
    var ligature = [_]f32{ 3.0, 4.0, 2.0 };
    native.zigonaut_fit_cluster_advances(&ligature, ligature.len, 20.0);
    try std.testing.expectApproxEqAbs(@as(f32, 20.0), sum(&ligature), 0.001);

    var combining = [_]f32{ 9.0, 0.0 };
    native.zigonaut_fit_cluster_advances(&combining, combining.len, 10.0);
    try std.testing.expectApproxEqAbs(@as(f32, 10.0), sum(&combining), 0.001);
}

fn sum(values: []const f32) f32 {
    var total: f32 = 0;
    for (values) |value| total += value;
    return total;
}
