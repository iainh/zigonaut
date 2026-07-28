const std = @import("std");
const Pty = @import("pty.zig").Pty;
const win = @import("win32.zig").c;

pub fn main() !void {
    var pty = try Pty.spawn(
        std.heap.page_allocator,
        "cmd.exe /d /q",
        "",
        90,
        23,
    );
    defer {
        _ = win.TerminateProcess(pty.process, 0);
        pty.stopIo(null);
        pty.closeConsole();
        pty.finishClose();
    }

    // Complete OpenConsole's initial device-attributes negotiation so the
    // attached client can finish starting.
    try pty.write("\x1b[?61c");
    win.Sleep(100);
    try drainOutput(&pty);
    try pty.write("for /L %i in (1,1,40) do @echo ROW-%i-ABCDEFGHIJKLMNOPQRSTUVWXYZ\r\necho ZIGONAUT_READY\r\n");
    var startup_output: [64 * 1024]u8 = undefined;
    var startup_length: usize = 0;
    var attempts: usize = 0;
    while (std.mem.indexOf(u8, startup_output[0..startup_length], "ZIGONAUT_READY") == null) {
        if (attempts == 200) return error.ChildDidNotBecomeReady;
        attempts += 1;
        if (startup_length == startup_output.len) return error.StartupOutputTooLarge;
        const available = try availableOutput(&pty);
        if (available == 0) {
            if (pty.exitedCleanly()) return error.ChildExitedBeforeReady;
            win.Sleep(25);
            continue;
        }
        startup_length += try pty.read(startup_output[startup_length..][0..@min(available, startup_output.len - startup_length)]);
    }

    // Consume the marker's trailing newline and any output already in flight.
    win.Sleep(250);
    try drainOutput(&pty);

    for (0..4) |_| {
        for ([_]struct { columns: u16, rows: u16 }{
            .{ .columns = 54, .rows = 12 },
            .{ .columns = 74, .rows = 17 },
            .{ .columns = 44, .rows = 11 },
            .{ .columns = 79, .rows = 20 },
            .{ .columns = 90, .rows = 23 },
        }) |size| {
            try pty.resize(size.columns, size.rows);
            win.Sleep(100);
            if (try availableOutput(&pty) != 0) return error.ResizeProducedTerminalOutput;
        }
    }

    std.debug.print("side-by-side ConPTY resize produced no synthetic terminal output\n", .{});
}

fn drainOutput(pty: *Pty) !void {
    var buffer: [4096]u8 = undefined;
    while (true) {
        const available = try availableOutput(pty);
        if (available == 0) break;
        _ = try pty.read(buffer[0..@min(buffer.len, available)]);
    }
}

fn availableOutput(pty: *const Pty) !usize {
    var available: win.DWORD = 0;
    if (win.PeekNamedPipe(pty.output, null, 0, null, &available, null) == 0) {
        return error.PeekPseudoConsoleFailed;
    }
    return available;
}
