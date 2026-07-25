const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");

const columns = 120;
const rows = 40;
const feed_iterations = 10_000;
const render_iterations = 500;
const line = "\x1b[38;2;120;180;255mcompile\x1b[0m src/terminal_view.zig:123:45 " ++
    "abcdefghijklmnopqrstuvwxyz 0123456789\r\n";

pub fn main() !void {
    var terminal = try Terminal.init(columns, rows, theme.rasmus);
    defer terminal.deinit();

    var timer = try std.time.Timer.start();
    for (0..feed_iterations) |_| terminal.feed(line);
    const feed_ns = timer.lap();

    var renderer = BenchmarkRenderer{};
    for (0..render_iterations) |_| try terminal.renderViewport(&renderer);
    const render_ns = timer.lap();

    var snapshot = Terminal.RenderSnapshot{};
    defer snapshot.deinit(std.heap.page_allocator);
    try snapshot.capture(std.heap.page_allocator, &terminal);
    for (0..render_iterations) |_| try snapshot.capture(std.heap.page_allocator, &terminal);
    const capture_ns = timer.lap();
    for (0..render_iterations) |_| snapshot.replay(&renderer);
    const replay_ns = timer.lap();

    std.debug.print(
        "feed: {d} bytes in {d:.2} ms ({d:.2} MiB/s)\n" ++
            "render: {d} frames in {d:.2} ms ({d:.2} us/frame)\n" ++
            "snapshot capture: {d:.2} us/frame; replay: {d:.2} us/frame; checksum={d}\n",
        .{
            line.len * feed_iterations,
            milliseconds(feed_ns),
            @as(f64, @floatFromInt(line.len * feed_iterations)) / @as(f64, @floatFromInt(feed_ns)) * 1_000_000_000.0 / (1024.0 * 1024.0),
            render_iterations,
            milliseconds(render_ns),
            @as(f64, @floatFromInt(render_ns)) / @as(f64, render_iterations) / 1_000.0,
            @as(f64, @floatFromInt(capture_ns)) / @as(f64, render_iterations) / 1_000.0,
            @as(f64, @floatFromInt(replay_ns)) / @as(f64, render_iterations) / 1_000.0,
            renderer.checksum,
        },
    );
}

const BenchmarkRenderer = struct {
    checksum: u64 = 0,

    pub fn beginFrame(self: *BenchmarkRenderer, frame: Terminal.Frame) void {
        self.checksum +%= frame.cursor_x;
    }

    pub fn beginRow(self: *BenchmarkRenderer, row: u16) void {
        self.checksum +%= row;
    }

    pub fn drawCell(self: *BenchmarkRenderer, cell: Terminal.Cell) void {
        self.checksum +%= cell.x;
        self.checksum +%= cell.codepoints.len;
        if (cell.codepoints.len != 0) self.checksum +%= cell.codepoints[0];
    }

    pub fn endRow(_: *BenchmarkRenderer, _: u16) void {}

    pub fn endFrame(self: *BenchmarkRenderer, frame: Terminal.Frame) void {
        self.checksum +%= frame.cursor_y;
    }
};

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / 1_000_000.0;
}
