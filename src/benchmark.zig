const std = @import("std");
const search = @import("search.zig");
const SearchMatch = search.Match;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");
const directwrite = @import("directwrite_renderer.zig");
const progress = @import("progress.zig");
const win32 = @import("win32.zig");

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

    var timer = try Timer.start();
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
    const dwrite = try directwrite.benchmarkPipeline();
    const progress_bytewise_ns = benchmarkProgressParser(false);
    const progress_fast_ns = benchmarkProgressParser(true);
    const search_highlight = try benchmarkSearchHighlight();

    std.debug.print(
        "feed: {d} bytes in {d:.2} ms ({d:.2} MiB/s)\n" ++
            "render: {d} frames in {d:.2} ms ({d:.2} us/frame)\n" ++
            "snapshot cell size: {d} bytes\n" ++
            "snapshot capture unchanged: {d:.2} us/frame; one-row update: {d:.2} us/frame; replay after one-row update: {d:.2} us/frame; checksum={d}\n" ++
            "search cold: {d} rows in {d:.2} ms; warm cached: {d} matches in {d:.2} ms\n" ++
            "resize: {d} sessions x {d} changes in {d:.2} ms ({d:.2} us/change); active-only {d:.2} ms ({d:.2} us/change)\n" ++
            "DirectWrite layout cache: {d} ReleaseFast repetitions in {d:.2} ms; {d} creations ({d} hot-reuse misses), {d} entries\n" ++
            "output metadata scan: bytewise {d:.2} ms; skip plain text {d:.2} ms ({d:.2}% faster)\n",
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
        },
    );
    std.debug.print(
        "DirectWrite baselines (native retained renderer):\n" ++
            "  1 warm resolved row/run: {d:.2} us/row ({d} rows; layout hits={d}, misses={d}, layout->Draw={d}, callbacks={d}, glyph submissions={d}; plan hits={d}, misses={d}, bypasses={d})\n" ++
            "  2 monochrome color translation: {d:.2} us/row ({d} rows; attempts={d}, successes={d})\n" ++
            "  3 foreground fragmentation: uniform {d:.2} us/row, fragmented {d:.2} us/row, ratio {d:.2}x ({d} rows each; plan hits={d}, misses={d})\n" ++
            "  4 final scene transfer CPU submission: {d:.2} us/call ({d}x{d}, {d} CopyResource calls submitted; counter={d}; no GPU-completion wait or Present)\n",
        .{
            perIterationUs(dwrite.warm_row_nanoseconds, dwrite.warm_row_iterations),
            dwrite.warm_row_iterations,
            dwrite.layout_hits,
            dwrite.layout_misses,
            dwrite.layout_draws,
            dwrite.glyph_callbacks,
            dwrite.glyph_submissions,
            dwrite.resolved_plan_hits,
            dwrite.resolved_plan_misses,
            dwrite.resolved_plan_bypasses,
            perIterationUs(dwrite.monochrome_row_nanoseconds, dwrite.monochrome_row_iterations),
            dwrite.monochrome_row_iterations,
            dwrite.monochrome_translate_attempts,
            dwrite.monochrome_translate_successes,
            perIterationUs(dwrite.uniform_row_nanoseconds, dwrite.uniform_row_iterations),
            perIterationUs(dwrite.fragmented_row_nanoseconds, dwrite.fragmented_row_iterations),
            @as(f64, @floatFromInt(dwrite.fragmented_row_nanoseconds)) / @as(f64, @floatFromInt(dwrite.uniform_row_nanoseconds)),
            dwrite.uniform_row_iterations,
            dwrite.fragmented_plan_hits,
            dwrite.fragmented_plan_misses,
            perIterationUs(dwrite.scene_copy_nanoseconds, dwrite.scene_copy_iterations),
            dwrite.scene_width,
            dwrite.scene_height,
            dwrite.scene_copy_iterations,
            dwrite.scene_copy_d3d11_copies,
        },
    );
    std.debug.print(
        "    atlas: {d}x{d} generation={d}, allocations={d}, reserved={d} px, rejected={d}/{d} px, resets={d}; batches={d}, sprites={d}, native submissions={d}; placement hits={d}, misses={d}, rasterizations={d}; population batches={d}\n",
        .{ dwrite.atlas_extent, dwrite.atlas_extent, dwrite.atlas_generation,
            dwrite.atlas_resource_allocations, dwrite.atlas_reserved_area,
            dwrite.atlas_rejected_count, dwrite.atlas_rejected_area, dwrite.atlas_pressure_resets,
            dwrite.atlas_sprite_batches, dwrite.atlas_sprites,
            dwrite.fragmented_native_glyph_submissions, dwrite.atlas_placement_hits,
            dwrite.atlas_placement_misses, dwrite.atlas_rasterizations,
            dwrite.atlas_uploads },
    );
    std.debug.print(
        "    atlas warm frame: {d:.2} us ({d} fragmented rows; includes BeginDraw, Clear, row submission, and EndDraw; excludes transfer/Present)\n",
        .{ perIterationUs(dwrite.atlas_warm_frame_nanoseconds, 1), dwrite.atlas_warm_frame_rows },
    );
    std.debug.print(
        "    atlas cold frame CPU submission: {d:.2} us (resources={d}, rasterizations={d}, population batches={d}; includes lazy creation, one fragmented row, and EndDraw; excludes GPU completion)\n",
        .{ perIterationUs(dwrite.atlas_cold_frame_nanoseconds, 1),
            dwrite.atlas_cold_resource_allocations, dwrite.atlas_cold_rasterizations,
            dwrite.atlas_cold_uploads },
    );
    std.debug.print(
        "search highlighting: per-cell lookup {d:.2} ms; per-row lookup {d:.2} ms ({d:.2}% faster)\n" ++
            "search row lookup: binary {d:.2} ms; monotonic cursor {d:.2} ms ({d:.2}% faster)\n",
        .{
            milliseconds(search_highlight.per_cell_ns),
            milliseconds(search_highlight.per_row_ns),
            improvement(search_highlight.per_cell_ns, search_highlight.per_row_ns),
            milliseconds(search_highlight.per_row_ns),
            milliseconds(search_highlight.cursor_ns),
            improvement(search_highlight.per_row_ns, search_highlight.cursor_ns),
        },
    );
}

fn benchmarkSearchHighlight() !struct { per_cell_ns: u64, per_row_ns: u64, cursor_ns: u64 } {
    const iterations = 1_000;
    var matches: [4096]SearchMatch = undefined;
    for (&matches, 0..) |*match, row| match.* = .{ .row = @intCast(row), .start = 40, .end = 48 };
    var checksum: u64 = 0;
    var timer = try Timer.start();
    for (0..iterations) |_| for (0..rows) |y| for (0..columns) |x| {
        checksum +%= search.highlight(&matches, 4030, 4000 + y, @intCast(x));
    };
    const per_cell_ns = timer.lap();
    for (0..iterations) |_| for (0..rows) |y| {
        const row_matches = search.matchesForRow(&matches, 4000 + y);
        for (0..columns) |x| checksum +%= search.highlightRow(row_matches, 4030, @intCast(x));
    };
    const per_row_ns = timer.lap();
    for (0..iterations) |_| {
        var cursor = search.RowCursor.init(&matches, 4000);
        for (0..rows) |y| {
            const row_matches = cursor.next(4000 + y);
            for (0..columns) |x| checksum +%= search.highlightRow(row_matches, 4030, @intCast(x));
        }
    }
    std.mem.doNotOptimizeAway(checksum);
    return .{ .per_cell_ns = per_cell_ns, .per_row_ns = per_row_ns, .cursor_ns = timer.lap() };
}

fn benchmarkProgressParser(fast: bool) u64 {
    const iterations = 100_000;
    var parser = progress.Parser{};
    var handler = ProgressBenchmarkHandler{};
    var timer = Timer.start() catch return 0;
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

    pub fn drawImage(self: *BenchmarkRenderer, image: Terminal.Image) void {
        self.checksum +%= image.pixels.len;
    }

    pub fn endFrame(self: *BenchmarkRenderer, frame: Terminal.Frame) void {
        self.checksum +%= frame.cursor_y;
    }
};

fn milliseconds(nanoseconds: u64) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / 1_000_000.0;
}

fn perIterationUs(nanoseconds: u64, iterations: u32) f64 {
    return @as(f64, @floatFromInt(nanoseconds)) / @as(f64, @floatFromInt(iterations)) / 1_000.0;
}

test "per-iteration benchmark normalization uses microseconds" {
    try std.testing.expectEqual(@as(f64, 2.5), perIterationUs(10_000, 4));
}

fn improvement(before: u64, after: u64) f64 {
    return (@as(f64, @floatFromInt(before)) - @as(f64, @floatFromInt(after))) /
        @as(f64, @floatFromInt(before)) * 100.0;
}

const Timer = struct {
    started: u64,

    fn start() !Timer {
        return .{ .started = win32.monotonicNanoseconds() orelse return error.TimerUnavailable };
    }

    fn lap(self: *Timer) u64 {
        const now = win32.monotonicNanoseconds() orelse self.started;
        defer self.started = now;
        return now - self.started;
    }

    fn read(self: *const Timer) u64 {
        return (win32.monotonicNanoseconds() orelse self.started) - self.started;
    }
};
