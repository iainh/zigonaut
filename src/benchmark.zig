const std = @import("std");
const search = @import("search.zig");
const SearchMatch = search.Match;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");
const directwrite = @import("directwrite_renderer.zig");
const progress = @import("progress.zig");

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
    var search_cache = Terminal.SearchCache{};
    defer search_cache.deinit(std.heap.page_allocator);
    const total_rows = try terminal.totalRows();
    for (0..total_rows) |row| try terminal.searchRowCached(std.heap.page_allocator, &search_cache, @intCast(row), "terminal_view", &matches);
    const cold_search_ns = timer.lap();
    matches.clearRetainingCapacity();
    for (0..total_rows) |row| try terminal.searchRowCached(std.heap.page_allocator, &search_cache, @intCast(row), "compile", &matches);
    const warm_search_ns = timer.lap();

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

    const layout_repetitions = 5;
    const layout_result = try directwrite.benchmarkLayoutCache(layout_repetitions);
    const layout_cache_ns = timer.lap();
    const progress_bytewise_ns = benchmarkProgressParser(false);
    const progress_fast_ns = benchmarkProgressParser(true);
    const search_copy = try benchmarkSearchSnapshotCopy();
    const search_highlight = try benchmarkSearchHighlight();

    std.debug.print(
        "feed: {d} bytes in {d:.2} ms ({d:.2} MiB/s)\n" ++
            "render: {d} frames in {d:.2} ms ({d:.2} us/frame)\n" ++
            "snapshot cell size: {d} bytes\n" ++
            "snapshot capture unchanged: {d:.2} us/frame; one-row update: {d:.2} us/frame; replay after one-row update: {d:.2} us/frame; checksum={d}\n" ++
            "search cold: {d} rows in {d:.2} ms; warm cached: {d} matches in {d:.2} ms\n" ++
            "resize: {d} sessions x {d} changes in {d:.2} ms ({d:.2} us/change); active-only {d:.2} ms ({d:.2} us/change)\n" ++
            "DirectWrite layout cache: {d} ReleaseFast repetitions in {d:.2} ms; {d} creations ({d} hot-reuse misses), {d} entries\n" ++
            "output metadata scan: bytewise {d:.2} ms; skip plain text {d:.2} ms ({d:.2}% faster)\n" ++
            "unchanged search snapshot: copy every frame {d:.2} ms; generation cache {d:.2} ms ({d:.2}% faster)\n",
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
            milliseconds(cold_search_ns),
            matches.items.len,
            milliseconds(warm_search_ns),
            resize_session_count,
            resize_iterations,
            milliseconds(all_resize_ns),
            @as(f64, @floatFromInt(all_resize_ns)) / resize_iterations / 1_000.0,
            milliseconds(active_resize_ns),
            @as(f64, @floatFromInt(active_resize_ns)) / resize_iterations / 1_000.0,
            layout_repetitions,
            milliseconds(layout_cache_ns),
            layout_result.layout_creations,
            layout_result.hot_reuse_creations,
            layout_result.cache_entries,
            milliseconds(progress_bytewise_ns),
            milliseconds(progress_fast_ns),
            improvement(progress_bytewise_ns, progress_fast_ns),
            milliseconds(search_copy.uncached_ns),
            milliseconds(search_copy.cached_ns),
            improvement(search_copy.uncached_ns, search_copy.cached_ns),
        },
    );
    std.debug.print(
        "search highlighting: per-cell lookup {d:.2} ms; per-row lookup {d:.2} ms ({d:.2}% faster)\n",
        .{
            milliseconds(search_highlight.per_cell_ns),
            milliseconds(search_highlight.per_row_ns),
            improvement(search_highlight.per_cell_ns, search_highlight.per_row_ns),
        },
    );
}

fn benchmarkSearchHighlight() !struct { per_cell_ns: u64, per_row_ns: u64 } {
    const iterations = 1_000;
    var matches: [4096]SearchMatch = undefined;
    for (&matches, 0..) |*match, row| match.* = .{ .row = @intCast(row), .start = 40, .end = 48 };
    var checksum: u64 = 0;
    var timer = try std.time.Timer.start();
    for (0..iterations) |_| for (0..rows) |y| for (0..columns) |x| {
        checksum +%= search.highlight(&matches, 4030, 4000 + y, @intCast(x));
    };
    const per_cell_ns = timer.lap();
    for (0..iterations) |_| for (0..rows) |y| {
        const row_matches = search.matchesForRow(&matches, 4000 + y);
        for (0..columns) |x| checksum +%= search.highlightRow(row_matches, 4030, @intCast(x));
    };
    std.mem.doNotOptimizeAway(checksum);
    return .{ .per_cell_ns = per_cell_ns, .per_row_ns = timer.lap() };
}

fn benchmarkSearchSnapshotCopy() !struct { uncached_ns: u64, cached_ns: u64 } {
    const iterations = 20_000;
    var source = std.ArrayList(SearchMatch).empty;
    defer source.deinit(std.heap.page_allocator);
    try source.resize(std.heap.page_allocator, 4096);
    for (source.items, 0..) |*match, index| match.* = .{ .row = @intCast(index), .start = 1, .end = 8 };
    var destination = std.ArrayList(SearchMatch).empty;
    defer destination.deinit(std.heap.page_allocator);
    try destination.ensureTotalCapacity(std.heap.page_allocator, source.items.len);

    var timer = try std.time.Timer.start();
    for (0..iterations) |_| {
        destination.clearRetainingCapacity();
        destination.appendSliceAssumeCapacity(source.items);
        std.mem.doNotOptimizeAway(destination.items.ptr);
    }
    const uncached_ns = timer.lap();
    var copied_generation: u64 = 0;
    const source_generation: u64 = 0;
    for (0..iterations) |_| {
        if (copied_generation != source_generation) {
            destination.clearRetainingCapacity();
            destination.appendSliceAssumeCapacity(source.items);
            copied_generation = source_generation;
        }
        std.mem.doNotOptimizeAway(destination.items.ptr);
    }
    return .{ .uncached_ns = uncached_ns, .cached_ns = timer.lap() };
}

fn benchmarkProgressParser(fast: bool) u64 {
    const iterations = 100_000;
    var parser = progress.Parser{};
    var handler = ProgressBenchmarkHandler{};
    var timer = std.time.Timer.start() catch return 0;
    for (0..iterations) |_| {
        if (fast) {
            parser.feedEach(line, &handler);
        } else {
            for (line) |byte| if (parser.feedByte(byte)) |update| handler.handle(update);
        }
    }
    std.mem.doNotOptimizeAway(handler.count);
    return timer.read();
}

const ProgressBenchmarkHandler = struct {
    count: usize = 0,

    pub fn handle(self: *ProgressBenchmarkHandler, _: progress.Update) void {
        self.count += 1;
    }
};

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

fn improvement(before: u64, after: u64) f64 {
    return (@as(f64, @floatFromInt(before)) - @as(f64, @floatFromInt(after))) /
        @as(f64, @floatFromInt(before)) * 100.0;
}
