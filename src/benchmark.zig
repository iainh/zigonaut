const std = @import("std");
const search = @import("search.zig");
const SearchMatch = search.Match;
const Terminal = @import("terminal.zig").Terminal;
const theme = @import("theme.zig");
const directwrite = @import("directwrite_renderer.zig");
const Pty = @import("pty.zig").Pty;
const win32 = @import("win32.zig");
const win = win32.c;

const columns = 120;
const rows = 40;
const feed_iterations = 10_000;
const render_iterations = 500;
const resize_session_count = 8;
const resize_iterations = 50;
const resize_feed_iterations = 2_000;
const line = "\x1b[38;2;120;180;255mcompile\x1b[0m src/terminal_view.zig:123:45 " ++
    "abcdefghijklmnopqrstuvwxyz 0123456789\r\n";

pub fn main(init: std.process.Init) !void {
    try directwrite.installPngDecoder();
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(std.heap.page_allocator);
    var iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, std.heap.page_allocator);
    defer iterator.deinit();
    while (iterator.next()) |argument| try arguments.append(std.heap.page_allocator, argument);
    if (arguments.items.len >= 2 and std.mem.eql(u8, arguments.items[1], "--conpty")) {
        return benchmarkConpty();
    }
    if (arguments.items.len == 5 and std.mem.eql(u8, arguments.items[1], "--conpty-producer")) {
        const mode = std.meta.stringToEnum(ConptyProducerMode, arguments.items[2]) orelse return error.InvalidProducerMode;
        const chunk_bytes = try std.fmt.parseInt(usize, arguments.items[3], 10);
        const total_bytes = try std.fmt.parseInt(usize, arguments.items[4], 10);
        return runConptyProducer(mode, chunk_bytes, total_bytes);
    }

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
    for (0..render_iterations) |_| snapshot.replayDirty(&renderer);
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

    var link_terminal = try Terminal.init(80, 24, theme.rasmus);
    defer link_terminal.deinit();
    var link_scratch = Terminal.LinkScratch{};
    defer link_scratch.deinit(std.heap.page_allocator);
    link_terminal.feed("https://example.com/zigonaut");
    const link_iterations = 10_000;
    for (0..link_iterations) |_| {
        const found = (try link_terminal.linkAtAllocWithScratch(
            std.heap.page_allocator,
            std.heap.page_allocator,
            &link_scratch,
            .{ .x = 10, .y = 0 },
        )).?;
        std.mem.doNotOptimizeAway(found.start_column);
        std.heap.page_allocator.free(found.uri);
    }
    const link_lookup_ns = timer.lap();

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
    const search_highlight = try benchmarkSearchHighlight();

    std.debug.print(
        "feed: {d} bytes in {d:.2} ms ({d:.2} MiB/s)\n" ++
            "render: {d} frames in {d:.2} ms ({d:.2} us/frame)\n" ++
            "snapshot cell size: {d} bytes\n" ++
            "snapshot capture unchanged: {d:.2} us/frame; one-row update: {d:.2} us/frame; replay after one-row update: {d:.2} us/frame; checksum={d}\n" ++
            "search cold: {d} rows in {d:.2} ms; warm cached: {d} matches in {d:.2} ms\n" ++
            "link lookup: {d} iterations in {d:.2} ms ({d:.2} us/lookup)\n" ++
            "resize: {d} sessions x {d} changes in {d:.2} ms ({d:.2} us/change); active-only {d:.2} ms ({d:.2} us/change)\n" ++
            "DirectWrite layout cache: {d} ReleaseFast repetitions in {d:.2} ms; {d} creations ({d} hot-reuse misses), {d} entries\n",
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
            link_iterations,
            milliseconds(link_lookup_ns),
            @as(f64, @floatFromInt(link_lookup_ns)) / link_iterations / 1_000.0,
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
        },
    );
    std.debug.print(
        "DirectWrite baselines (native retained renderer):\n" ++
            "  1 warm resolved row/run: {d:.2} us/row ({d} rows; layout hits={d}, misses={d}, layout->Draw={d}, callbacks={d}, glyph submissions={d}; plan hits={d}, misses={d}, bypasses={d})\n" ++
            "  2 monochrome color translation: {d:.2} us/row ({d} rows; attempts={d}, successes={d})\n" ++
            "  3 foreground fragmentation: uniform {d:.2} us/row, fragmented {d:.2} us/row, ratio {d:.2}x ({d} rows each; plan hits={d}, misses={d})\n" ++
            "  4 final scene transfer: full {d:.2} us CPU / {d:.2} us GPU per copy ({d}x{d}); one-row damage {d:.2} us CPU / {d:.2} us GPU per copy ({d}x{d}, {d:.2} KiB copied); {d} calls each; no Present\n",
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
            perIterationUs(dwrite.scene_copy_gpu_nanoseconds, dwrite.scene_copy_iterations),
            dwrite.scene_width,
            dwrite.scene_height,
            perIterationUs(dwrite.scene_region_copy_nanoseconds, dwrite.scene_copy_iterations),
            perIterationUs(dwrite.scene_region_copy_gpu_nanoseconds, dwrite.scene_copy_iterations),
            dwrite.scene_width,
            dwrite.scene_region_height,
            @as(f64, @floatFromInt(dwrite.scene_region_copy_bytes)) / @as(f64, @floatFromInt(dwrite.scene_copy_iterations)) / 1024.0,
            dwrite.scene_copy_iterations,
        },
    );
    std.debug.print(
        "  glyph submission A/B CPU submission (same invocation, 3 warm frames excluded, {d} measured; same 40 warm fragmented rows; includes full flush + EndDraw, excludes Present/GPU wait): legacy Direct2D SpriteBatch {d:.2} us/frame; D3D11 instancing {d:.2} us/frame; {d:.2}% change\n",
        .{ dwrite.fragmented_frame_iterations, perIterationUs(dwrite.legacy_fragmented_frame_nanoseconds, dwrite.fragmented_frame_iterations), perIterationUs(dwrite.instanced_fragmented_frame_nanoseconds, dwrite.fragmented_frame_iterations), improvement(dwrite.legacy_fragmented_frame_nanoseconds, dwrite.instanced_fragmented_frame_nanoseconds) },
    );
    std.debug.print(
        "  instance upload A/B (same invocation, 40 warm fragmented rows): immutable buffer/SRV {d:.2} us/frame; triple dynamic WRITE_DISCARD {d:.2} us/frame; {d:.2}% change (uses={d}, wraps={d}, creations={d}, growths={d})\n",
        .{ perIterationUs(dwrite.immutable_instance_frame_nanoseconds, dwrite.fragmented_frame_iterations), perIterationUs(dwrite.dynamic_instance_frame_nanoseconds, dwrite.fragmented_frame_iterations), improvement(dwrite.immutable_instance_frame_nanoseconds, dwrite.dynamic_instance_frame_nanoseconds), dwrite.glyph_slot_uses, dwrite.glyph_slot_wraps, dwrite.glyph_buffer_creations, dwrite.glyph_capacity_growths },
    );
    std.debug.print(
        "  estimated snapshot-stage UI component cost (one-row update): synchronous capture + dirty replay {d:.2} us/frame; dirty replay after callback preparation {d:.2} us/frame; {d:.2}% change (excludes wait/message handoff)\n",
        .{ @as(f64, @floatFromInt(one_row_capture_ns + replay_ns)) / @as(f64, render_iterations) / 1_000.0, @as(f64, @floatFromInt(replay_ns)) / @as(f64, render_iterations) / 1_000.0, improvement(one_row_capture_ns + replay_ns, replay_ns) },
    );
    std.debug.print(
        "  scroll A/B CPU submission (same invocation, {d} warm iterations excluded, {d} measured; includes draw + final transfer, excludes Present/GPU wait): full 40-row fragmented redraw {d:.2} us/frame; scratch shift + exposed fragmented row {d:.2} us/frame; {d:.2}% change\n",
        .{
            3,
            dwrite.scroll_iterations,
            perIterationUs(dwrite.scroll_full_nanoseconds, dwrite.scroll_iterations),
            perIterationUs(dwrite.scroll_shift_nanoseconds, dwrite.scroll_iterations),
            improvement(dwrite.scroll_full_nanoseconds, dwrite.scroll_shift_nanoseconds),
        },
    );
    std.debug.print(
        "    atlas: {d}x{d} generation={d}, allocations={d}, reserved={d} px, rejected={d}/{d} px, resets={d}; batches={d}, sprites={d}, native submissions={d}; placement hits={d}, misses={d}, rasterizations={d}; population batches={d}\n",
        .{ dwrite.atlas_extent, dwrite.atlas_extent, dwrite.atlas_generation, dwrite.atlas_resource_allocations, dwrite.atlas_reserved_area, dwrite.atlas_rejected_count, dwrite.atlas_rejected_area, dwrite.atlas_pressure_resets, dwrite.atlas_sprite_batches, dwrite.atlas_sprites, dwrite.fragmented_native_glyph_submissions, dwrite.atlas_placement_hits, dwrite.atlas_placement_misses, dwrite.atlas_rasterizations, dwrite.atlas_uploads },
    );
    std.debug.print(
        "    atlas warm frame: {d:.2} us ({d} fragmented rows; includes BeginDraw, Clear, row submission, and EndDraw; excludes transfer/Present)\n",
        .{ perIterationUs(dwrite.atlas_warm_frame_nanoseconds, 1), dwrite.atlas_warm_frame_rows },
    );
    std.debug.print(
        "    atlas cold frame CPU submission: {d:.2} us (resources={d}, rasterizations={d}, population batches={d}; includes lazy creation, one fragmented row, and EndDraw; excludes GPU completion)\n",
        .{ perIterationUs(dwrite.atlas_cold_frame_nanoseconds, 1), dwrite.atlas_cold_resource_allocations, dwrite.atlas_cold_rasterizations, dwrite.atlas_cold_uploads },
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

const ConptyProducerMode = enum { native, legacy };
const conpty_ready_marker = "~ZIGONAUT-CONPTY-READY~";
const conpty_done_marker = "~ZIGONAUT-CONPTY-DONE~";
const conpty_effects = "\x1b]9;4;1;73\x1b\\\x1b]777;notify;ConPTY;semantic effects\x1b\\";

fn benchmarkConpty() !void {
    const total_bytes = 16 * 1024 * 1024;
    const executable = try executablePathAlloc(std.heap.page_allocator);
    defer std.heap.page_allocator.free(executable);
    std.debug.print("ConPTY end-to-end baselines ({d} MiB producer payload; includes Ghostty parsing):\n", .{total_bytes / (1024 * 1024)});
    for ([_]struct { mode: ConptyProducerMode, chunk_bytes: usize }{
        .{ .mode = .native, .chunk_bytes = 4 * 1024 },
        .{ .mode = .native, .chunk_bytes = 128 * 1024 },
        .{ .mode = .legacy, .chunk_bytes = 4 * 1024 },
        .{ .mode = .legacy, .chunk_bytes = 32 * 1024 },
    }) |case| try benchmarkConptyCase(executable, case.mode, case.chunk_bytes, total_bytes);
}

fn benchmarkConptyCase(executable: []const u8, mode: ConptyProducerMode, chunk_bytes: usize, total_bytes: usize) !void {
    const command = try std.fmt.allocPrint(
        std.heap.page_allocator,
        "\"{s}\" --conpty-producer {s} {d} {d}",
        .{ executable, @tagName(mode), chunk_bytes, total_bytes },
    );
    defer std.heap.page_allocator.free(command);

    var startup_timer = try Timer.start();
    var pty = try Pty.spawn(std.heap.page_allocator, command, "", columns, rows);
    defer {
        _ = win.TerminateProcess(pty.process, 0);
        pty.closeIo();
        pty.closeConsole();
        pty.finishClose();
    }
    var watchdog = ConptyWatchdog{ .process = pty.process };
    const watchdog_thread = try std.Thread.spawn(.{}, ConptyWatchdog.run, .{&watchdog});
    defer {
        watchdog.complete.store(true, .release);
        watchdog_thread.join();
    }
    try pty.write("\x1b[?61c");

    var terminal = try Terminal.init(columns, rows, theme.rasmus);
    defer terminal.deinit();
    var effects = ConptyEffects{};
    try terminal.setProgressReport(ConptyEffects.progressReport, &effects);
    try terminal.setDesktopNotification(ConptyEffects.desktopNotification, &effects);
    var buffer: [16 * 1024]u8 = undefined;
    var ready_matcher = MarkerMatcher{ .marker = conpty_ready_marker };
    while (!ready_matcher.complete()) {
        const count = try pty.read(&buffer);
        if (count == 0) return if (watchdog.timed_out.load(.acquire)) error.ConptyBenchmarkTimedOut else error.ConptyProducerExitedBeforeReady;
        terminal.feed(buffer[0..count]);
        ready_matcher.feed(buffer[0..count]);
    }
    const startup_ns = startup_timer.read();

    var timer = try Timer.start();
    try pty.write("G");
    var done_matcher = MarkerMatcher{ .marker = conpty_done_marker };
    var received_bytes: usize = 0;
    var reads: usize = 0;
    var largest_read: usize = 0;
    while (!done_matcher.complete()) {
        const count = try pty.read(&buffer);
        if (count == 0) return if (watchdog.timed_out.load(.acquire)) error.ConptyBenchmarkTimedOut else error.ConptyProducerExitedBeforeDone;
        received_bytes += count;
        reads += 1;
        largest_read = @max(largest_read, count);
        terminal.feed(buffer[0..count]);
        done_matcher.feed(buffer[0..count]);
    }
    const elapsed_ns = timer.read();
    if (mode == .native and (!effects.progress_received or !effects.notification_received)) {
        return error.ConptyDroppedSemanticEffects;
    }
    std.mem.doNotOptimizeAway(try terminal.totalRows());
    std.debug.print(
        "  {s: <6} {d: >3} KiB writes: {d:.2} MiB/s, {d:.2} ms startup, {d} reads ({d:.1} KiB average, {d:.1} KiB max; {d:.2} MiB received)\n",
        .{
            @tagName(mode),
            chunk_bytes / 1024,
            @as(f64, @floatFromInt(total_bytes)) / @as(f64, @floatFromInt(elapsed_ns)) * std.time.ns_per_s / (1024.0 * 1024.0),
            milliseconds(startup_ns),
            reads,
            @as(f64, @floatFromInt(received_bytes)) / @as(f64, @floatFromInt(reads)) / 1024.0,
            @as(f64, @floatFromInt(largest_read)) / 1024.0,
            @as(f64, @floatFromInt(received_bytes)) / (1024.0 * 1024.0),
        },
    );
}

const ConptyEffects = struct {
    progress_received: bool = false,
    notification_received: bool = false,

    fn progressReport(context: ?*anyopaque, update: Terminal.ProgressUpdate) void {
        const self: *ConptyEffects = @ptrCast(@alignCast(context orelse return));
        const report = switch (update) {
            .remove => return,
            .report => |value| value,
        };
        self.progress_received = report.state == .normal and report.value == 73;
    }

    fn desktopNotification(context: ?*anyopaque, title: []const u8, body: []const u8) void {
        const self: *ConptyEffects = @ptrCast(@alignCast(context orelse return));
        self.notification_received = std.mem.eql(u8, title, "ConPTY") and std.mem.eql(u8, body, "semantic effects");
    }
};

const ConptyWatchdog = struct {
    process: win.HANDLE,
    complete: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    timed_out: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn run(self: *ConptyWatchdog) void {
        for (0..200) |_| {
            if (self.complete.load(.acquire)) return;
            win.Sleep(50);
        }
        if (self.complete.load(.acquire)) return;
        self.timed_out.store(true, .release);
        _ = win.TerminateProcess(self.process, 1);
    }
};

fn runConptyProducer(mode: ConptyProducerMode, chunk_bytes: usize, total_bytes: usize) !void {
    if (chunk_bytes == 0 or total_bytes == 0) return error.InvalidProducerSize;
    const output = win.GetStdHandle(win.STD_OUTPUT_HANDLE) orelse return error.ConsoleOutputUnavailable;
    const input = win.GetStdHandle(win.STD_INPUT_HANDLE) orelse return error.ConsoleInputUnavailable;
    var console_mode: win.DWORD = 0;
    if (win.GetConsoleMode(output, &console_mode) == 0) return error.ConsoleModeUnavailable;
    const output_mode = if (mode == .native)
        console_mode | win.ENABLE_VIRTUAL_TERMINAL_PROCESSING
    else
        console_mode & ~@as(win.DWORD, win.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    if (win.SetConsoleMode(output, output_mode) == 0) {
        return error.ConsoleModeUnavailable;
    }
    var input_mode: win.DWORD = 0;
    if (win.GetConsoleMode(input, &input_mode) == 0 or
        win.SetConsoleMode(input, input_mode & ~@as(win.DWORD, win.ENABLE_ECHO_INPUT | win.ENABLE_LINE_INPUT)) == 0)
    {
        return error.ConsoleModeUnavailable;
    }

    const payload = try std.heap.page_allocator.alloc(u8, chunk_bytes);
    defer std.heap.page_allocator.free(payload);
    @memset(payload, 'x');
    if (payload.len >= 2) {
        payload[payload.len - 2] = '\r';
        payload[payload.len - 1] = '\n';
    }
    const wide_payload = if (mode == .legacy)
        try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, payload)
    else
        null;
    defer if (wide_payload) |wide| std.heap.page_allocator.free(wide);

    try writeProducerOutput(output, mode, conpty_ready_marker);
    var gate: [1]u8 = undefined;
    var gate_read: win.DWORD = 0;
    if (win.ReadFile(input, &gate, gate.len, &gate_read, null) == 0 or gate_read != 1) return error.ProducerGateFailed;

    var remaining = total_bytes;
    while (remaining != 0) {
        const count = @min(remaining, payload.len);
        if (wide_payload) |wide| {
            try writeWideProducerOutput(output, wide[0..count]);
        } else {
            try writeByteProducerOutput(output, payload[0..count]);
        }
        remaining -= count;
    }
    try writeProducerOutput(output, mode, conpty_effects);
    try writeProducerOutput(output, mode, conpty_done_marker);
}

fn writeProducerOutput(handle: win.HANDLE, mode: ConptyProducerMode, bytes: []const u8) !void {
    switch (mode) {
        .native => try writeByteProducerOutput(handle, bytes),
        .legacy => {
            const wide = try std.unicode.utf8ToUtf16LeAlloc(std.heap.page_allocator, bytes);
            defer std.heap.page_allocator.free(wide);
            try writeWideProducerOutput(handle, wide);
        },
    }
}

fn writeByteProducerOutput(handle: win.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        var written: win.DWORD = 0;
        if (win.WriteFile(handle, bytes[offset..].ptr, @intCast(bytes.len - offset), &written, null) == 0 or written == 0) {
            return error.ProducerWriteFailed;
        }
        offset += written;
    }
}

fn writeWideProducerOutput(handle: win.HANDLE, wide: []const u16) !void {
    var offset: usize = 0;
    while (offset < wide.len) {
        var written: win.DWORD = 0;
        if (win.WriteConsoleW(handle, wide[offset..].ptr, @intCast(wide.len - offset), &written, null) == 0 or written == 0) {
            return error.ProducerWriteFailed;
        }
        offset += written;
    }
}

fn executablePathAlloc(allocator: std.mem.Allocator) ![]u8 {
    var path: [32_768]u16 = undefined;
    const length = win.GetModuleFileNameW(null, &path, path.len);
    if (length == 0 or length == path.len) return error.ExecutablePathUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(allocator, path[0..length]);
}

const MarkerMatcher = struct {
    marker: []const u8,
    matched: usize = 0,

    fn feed(self: *MarkerMatcher, bytes: []const u8) void {
        for (bytes) |byte| {
            if (self.complete()) return;
            if (byte == self.marker[self.matched]) {
                self.matched += 1;
            } else {
                self.matched = @intFromBool(byte == self.marker[0]);
            }
        }
    }

    fn complete(self: *const MarkerMatcher) bool {
        return self.matched == self.marker.len;
    }
};

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
