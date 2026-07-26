const std = @import("std");
const SearchMatch = @import("search.zig").Match;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");

const columns = 120;
const rows = 40;
const feed_iterations = 10_000;
const render_iterations = 500;
const resize_session_count = 8;
const resize_iterations = 50;
const resize_feed_iterations = 2_000;
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
    const unchanged_capture_ns = timer.lap();
    for (0..render_iterations) |iteration| {
        // Rewrite one cell on one row without moving the cursor between rows.
        terminal.feed(if (iteration % 2 == 0) "\rX" else "\rY");
        try snapshot.capture(std.heap.page_allocator, &terminal);
    }
    const one_row_capture_ns = timer.lap();
    for (0..render_iterations) |_| snapshot.replay(&renderer);
    const replay_ns = timer.lap();

    var matches = std.ArrayList(SearchMatch).empty;
    defer matches.deinit(std.heap.page_allocator);
    var search_scratch = Terminal.SearchScratch{};
    defer search_scratch.deinit(std.heap.page_allocator);
    const total_rows = try terminal.totalRows();
    for (0..total_rows) |row| try terminal.searchRow(std.heap.page_allocator, &search_scratch, @intCast(row), "terminal_view", &matches);
    const search_ns = timer.lap();

    var resize_terminals: [resize_session_count]Terminal = undefined;
    var initialized: usize = 0;
    defer for (resize_terminals[0..initialized]) |*resize_terminal| resize_terminal.deinit();
    for (&resize_terminals) |*resize_terminal| {
        resize_terminal.* = try Terminal.init(columns, rows, theme.rasmus);
        initialized += 1;
        for (0..resize_feed_iterations) |_| resize_terminal.feed(line);
    }
    _ = timer.lap();
    for (0..resize_iterations) |iteration| {
        const target_columns: u16 = if (iteration % 2 == 0) columns - 1 else columns;
        const target_rows: u16 = if (iteration % 2 == 0) rows - 1 else rows;
        for (&resize_terminals) |*resize_terminal| try resize_terminal.resize(target_columns, target_rows, 9, 18);
    }
    const all_resize_ns = timer.lap();
    for (0..resize_iterations) |iteration| {
        const target_columns: u16 = if (iteration % 2 == 0) columns - 1 else columns;
        const target_rows: u16 = if (iteration % 2 == 0) rows - 1 else rows;
        try resize_terminals[0].resize(target_columns, target_rows, 9, 18);
    }
    const active_resize_ns = timer.lap();

    std.debug.print(
        "feed: {d} bytes in {d:.2} ms ({d:.2} MiB/s)\n" ++
            "render: {d} frames in {d:.2} ms ({d:.2} us/frame)\n" ++
            "snapshot cell size: {d} bytes\n" ++
            "snapshot capture unchanged: {d:.2} us/frame; one-row update: {d:.2} us/frame; replay after one-row update: {d:.2} us/frame; checksum={d}\n" ++
            "search: {d} rows, {d} matches in {d:.2} ms\n" ++
            "resize: {d} sessions x {d} changes in {d:.2} ms ({d:.2} us/change); active-only {d:.2} ms ({d:.2} us/change)\n",
        .{
            line.len * feed_iterations,
            milliseconds(feed_ns),
            @as(f64, @floatFromInt(line.len * feed_iterations)) / @as(f64, @floatFromInt(feed_ns)) * 1_000_000_000.0 / (1024.0 * 1024.0),
            render_iterations,
            milliseconds(render_ns),
            @as(f64, @floatFromInt(render_ns)) / @as(f64, render_iterations) / 1_000.0,
            Terminal.RenderSnapshot.cell_size,
            @as(f64, @floatFromInt(unchanged_capture_ns)) / @as(f64, render_iterations) / 1_000.0,
            @as(f64, @floatFromInt(one_row_capture_ns)) / @as(f64, render_iterations) / 1_000.0,
            @as(f64, @floatFromInt(replay_ns)) / @as(f64, render_iterations) / 1_000.0,
            renderer.checksum,
            total_rows,
            matches.items.len,
            milliseconds(search_ns),
            resize_session_count,
            resize_iterations,
            milliseconds(all_resize_ns),
            @as(f64, @floatFromInt(all_resize_ns)) / resize_iterations / 1_000.0,
            milliseconds(active_resize_ns),
            @as(f64, @floatFromInt(active_resize_ns)) / resize_iterations / 1_000.0,
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
