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
};
