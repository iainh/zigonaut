const std = @import("std");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("time.h");
    @cInclude("unistd.h");
});
const shared = @import("shared");
const pseudographics = shared.pseudographics;
const Terminal = shared.terminal.Terminal;
const search = shared.search;
const Search = search.State;
const SynchronizedOutput = shared.synchronized_output.Watchdog;
const hint = shared.hint;
const theme = shared.theme;
const Mutex = @import("platform_sync").Mutex;
const public_abi = @cImport({
    @cInclude("zigonaut_core.h");
});
extern var environ: [*:null]?[*:0]u8;
extern fn openpty(amaster: *c_int, aslave: *c_int, name: ?[*]u8, termp: ?*anyopaque, winp: ?*c.winsize) c_int;
extern fn proc_name(pid: c_int, buffer: [*]u8, buffersize: u32) c_int;

const notification_queue_capacity = 32;
const notification_max_bytes = 4096;
const clipboard_queue_capacity = 16;
const clipboard_default_max_bytes: u32 = 1024 * 1024;
const key_utf8_max_bytes = 64;

const QueuedNotification = struct { payload: []u8, title_len: u16 };
const QueuedClipboard = struct { payload: []u8, token: u64, clear: bool };

fn monotonicNanos() i64 {
    var value: c.timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &value) != 0) return 0;
    return @as(i64, value.tv_sec) * std.time.ns_per_s + value.tv_nsec;
}

fn monotonicMillis() u64 {
    return @intCast(@max(0, @divTrunc(monotonicNanos(), std.time.ns_per_ms)));
}

pub const Wake = ?*const fn (?*anyopaque) callconv(.c) void;
const Core = struct {
    mutex: Mutex = .{},
    write_mutex: Mutex = .{},
    callback_mutex: Mutex = .{},
    terminal: Terminal,
    master: c_int,
    cancel_read: c_int,
    cancel_write: c_int,
    child: c.pid_t,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    exited: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake: Wake,
    context: ?*anyopaque,
    title: [4096]u8 = undefined,
    title_len: u32 = 0,
    title_explicit: bool = false,
    default_title: [256]u8 = undefined,
    default_title_len: u16 = 0,
    notifications: std.ArrayList(QueuedNotification) = .empty,
    clipboard_writes: std.ArrayList(QueuedClipboard) = .empty,
    clipboard_enabled: bool = false,
    clipboard_max_bytes: u32 = clipboard_default_max_bytes,
    next_clipboard_token: u64 = 1,
    search_cache: Terminal.SearchCache = .{},
    search: Search = .{},
    selection_unit: Terminal.SelectionUnit = .cell,
    selection_rectangle: bool = false,
    progress_active: bool = false,
    progress_state: Terminal.ProgressState = .normal,
    progress_value: u8 = 0,
    progress_generation: u64 = 0,
    output_generation: u64 = 0,
    synchronized_output: SynchronizedOutput = .{},
    render_snapshot: Terminal.RenderSnapshot = .{},
};

pub const NotificationResult = extern struct {
    version: u32,
    size: u32,
    required_title: u32,
    written_title: u32,
    required_body: u32,
    written_body: u32,
    status: u8,
    reserved: [7]u8,
};

pub const ClipboardResult = extern struct {
    version: u32,
    size: u32,
    token: u64,
    required_bytes: u32,
    written_bytes: u32,
    clear: u8,
    status: u8,
    reserved: [6]u8,
};

pub const HintRecord = extern struct {
    target_offset: u32,
    target_length: u32,
    row: u16,
    start_column: u16,
    end_column: u16,
    label_length: u8,
    label: [8]u8,
    reserved: [5]u8,
};

pub const HintResult = extern struct {
    version: u32,
    size: u32,
    required_hints: u32,
    required_bytes: u32,
    written_hints: u32,
    written_bytes: u32,
    status: u8,
    reserved: [7]u8,
};

pub const KeyEvent = extern struct {
    version: u32,
    size: u32,
    key_code: u16,
    modifiers: u16,
    consumed_modifiers: u16,
    utf8_length: u16,
    action: u8,
    reserved0: [3]u8,
    unshifted_codepoint: u32,
    utf8: ?[*]const u8,
    reserved: [8]u8,
};

pub const RenderFrame = extern struct {
    version: u32,
    size: u32,
    foreground_rgb: u32,
    background_rgb: u32,
    cursor_rgb: u32,
    cursor_x: u16,
    cursor_y: u16,
    cursor_columns: u8,
    cursor_style: u8,
    cursor_visible: u8,
    cursor_has_position: u8,
    images_skipped: u8,
    reserved: [7]u8,
};

pub const RenderCell = extern struct {
    version: u32,
    size: u32,
    text_offset: u32,
    text_length: u32,
    foreground_rgb: u32,
    background_rgb: u32,
    underline_rgb: u32,
    x: u16,
    y: u16,
    occupancy: u8,
    underline_style: u8,
    bold: u8,
    italic: u8,
    faint: u8,
    strikethrough: u8,
    overline: u8,
    selected: u8,
    background_is_default: u8,
    search_highlight: u8,
    reserved: [6]u8,
};

pub const SearchStatus = extern struct {
    version: u32,
    size: u32,
    matches: u32,
    active: i32,
    status: u8,
    scanning: u8,
    reserved: [6]u8,
};

pub const RenderSnapshotResult = extern struct {
    version: u32,
    size: u32,
    required_cells: u32,
    written_cells: u32,
    required_text_bytes: u32,
    written_text_bytes: u32,
    required_rows: u32,
    written_rows: u32,
    viewport_offset: u64,
    status: u8,
    reserved: [7]u8,
};

pub const RenderImage = extern struct {
    version: u32,
    size: u32,
    image_id: u32,
    generation: u64,
    data_offset: u32,
    data_length: u32,
    width: u32,
    height: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
    pixel_width: u32,
    pixel_height: u32,
    viewport_column: i32,
    viewport_row: i32,
    z: i32,
    x_offset: u32,
    y_offset: u32,
    reserved: [8]u8,
};

pub const ImageGeneration = extern struct {
    image_id: u32,
    reserved: u32,
    generation: u64,
};

pub const RenderImagesResult = extern struct {
    version: u32,
    size: u32,
    required_images: u32,
    written_images: u32,
    required_data_bytes: u32,
    written_data_bytes: u32,
    status: u8,
    reserved: [7]u8,
};

pub const TerminalTheme = extern struct {
    version: u32,
    size: u32,
    foreground_rgb: u32,
    background_rgb: u32,
    cursor_rgb: u32,
    ansi_rgb: [16]u32,
    reserved: [8]u8,
};

pub const Progress = extern struct {
    version: u32,
    size: u32,
    generation: u64,
    active: u8,
    state: u8,
    value: u8,
    reserved: [5]u8,
};

fn rgb(color: theme.Color) u32 {
    return (@as(u32, color.red) << 16) | (@as(u32, color.green) << 8) | color.blue;
}

fn colorFromRgb(value: u32) theme.Color {
    return .{ .red = @truncate(value >> 16), .green = @truncate(value >> 8), .blue = @truncate(value) };
}

fn titleChanged(context: ?*anyopaque, title: []const u8) void {
    const self: *Core = @ptrCast(@alignCast(context orelse return));
    if (!std.unicode.utf8ValidateSlice(title)) return;
    if (title.len == 0) {
        self.title_len = 0;
        self.title_explicit = false;
        return;
    }
    var count = @min(title.len, self.title.len);
    while (count > 0 and !std.unicode.utf8ValidateSlice(title[0..count])) count -= 1;
    @memcpy(self.title[0..count], title[0..count]);
    self.title_len = @intCast(count);
    self.title_explicit = true;
}

fn desktopNotification(context: ?*anyopaque, title: []const u8, body: []const u8) void {
    const self: *Core = @ptrCast(@alignCast(context orelse return));
    if (!std.unicode.utf8ValidateSlice(title) or !std.unicode.utf8ValidateSlice(body)) return;
    const length = std.math.add(usize, title.len, body.len) catch return;
    if (length > notification_max_bytes or title.len > std.math.maxInt(u16)) return;
    const payload = std.heap.c_allocator.alloc(u8, length) catch return;
    @memcpy(payload[0..title.len], title);
    @memcpy(payload[title.len..], body);
    if (self.notifications.items.len == notification_queue_capacity) {
        std.heap.c_allocator.free(self.notifications.orderedRemove(0).payload);
        self.notifications.appendAssumeCapacity(.{ .payload = payload, .title_len = @intCast(title.len) });
    } else self.notifications.append(std.heap.c_allocator, .{ .payload = payload, .title_len = @intCast(title.len) }) catch std.heap.c_allocator.free(payload);
}

fn clipboardWrite(context: ?*anyopaque, operation: Terminal.ClipboardWriteOperation) Terminal.ClipboardWriteResult {
    const self: *Core = @ptrCast(@alignCast(context orelse return .io_error));
    if (!self.clipboard_enabled) return .denied;
    const clear = switch (operation) {
        .clear => true,
        .text => false,
    };
    const text = switch (operation) {
        .clear => "",
        .text => |value| value,
    };
    if (text.len > self.clipboard_max_bytes or std.mem.indexOfScalar(u8, text, 0) != null or !std.unicode.utf8ValidateSlice(text)) return .invalid_data;
    if (self.clipboard_writes.items.len >= clipboard_queue_capacity) return .busy;
    const payload = std.heap.c_allocator.dupe(u8, text) catch return .io_error;
    self.clipboard_writes.append(std.heap.c_allocator, .{ .payload = payload, .token = self.next_clipboard_token, .clear = clear }) catch {
        std.heap.c_allocator.free(payload);
        return .io_error;
    };
    self.next_clipboard_token +%= 1;
    if (self.next_clipboard_token == 0) self.next_clipboard_token = 1;
    return .success;
}

fn progressReport(context: ?*anyopaque, update: Terminal.ProgressUpdate) void {
    const self: *Core = @ptrCast(@alignCast(context orelse return));
    switch (update) {
        .remove => self.progress_active = false,
        .report => |report| {
            self.progress_active = true;
            self.progress_state = report.state;
            self.progress_value = report.value orelse if (report.state == .normal) 0 else self.progress_value;
        },
    }
    self.progress_generation +%= 1;
}

// Called by terminal.feed while mutex is held. Only serialize the PTY write;
// acquiring the terminal mutex here would deadlock.
fn terminalWritePty(context: ?*anyopaque, bytes: []const u8) void {
    const self: *Core = @ptrCast(@alignCast(context orelse return));
    writeSerialized(self, bytes);
}

export fn zigonaut_core_create(helper_path: ?[*:0]const u8, shell_path: ?[*:0]const u8, working_directory: ?[*:0]const u8, shell_integration: bool, shell_integration_path: ?[*:0]const u8, wake: Wake, context: ?*anyopaque) ?*Core {
    const helper = helper_path orelse return null;
    const shell = shell_path orelse return null;
    if (shell[0] != '/') return null;
    const allocator = std.heap.c_allocator;
    const self = allocator.create(Core) catch return null;
    self.* = .{ .terminal = Terminal.init(80, 24, theme.rasmus) catch {
        allocator.destroy(self);
        return null;
    }, .master = -1, .cancel_read = -1, .cancel_write = -1, .child = -1, .wake = wake, .context = context };
    const shell_name = std.fs.path.basename(std.mem.span(shell));
    const initial_title = if (shell_name.len == 0) "Terminal" else shell_name;
    self.default_title_len = @intCast(@min(initial_title.len, self.default_title.len));
    @memcpy(self.default_title[0..self.default_title_len], initial_title[0..self.default_title_len]);
    self.terminal.setTitleChanged(titleChanged, self) catch return failCreate(self, -1);
    self.terminal.setWritePty(terminalWritePty, self) catch return failCreate(self, -1);
    self.terminal.setDesktopNotification(desktopNotification, self) catch return failCreate(self, -1);
    self.terminal.setClipboardWrite(clipboardWrite, self) catch return failCreate(self, -1);
    self.terminal.setProgressReport(progressReport, self) catch return failCreate(self, -1);
    var slave: c_int = -1;
    var size = c.winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (openpty(&self.master, &slave, null, null, &size) != 0) {
        self.terminal.deinit();
        allocator.destroy(self);
        return null;
    }
    var cancel: [2]c_int = undefined;
    if (c.pipe(&cancel) != 0) return failCreate(self, slave);
    self.cancel_read = cancel[0];
    self.cancel_write = cancel[1];
    if (!setCloexec(self.master) or !setCloexec(slave) or !setCloexec(cancel[0]) or !setCloexec(cancel[1])) return failCreate(self, slave);
    var actions: std.c.posix_spawn_file_actions_t = undefined;
    if (std.c.posix_spawn_file_actions_init(&actions) != 0) return failCreate(self, slave);
    defer _ = std.c.posix_spawn_file_actions_destroy(&actions);
    if (addSlaveAction(&actions, slave) != 0) return failCreate(self, slave);
    // A source descriptor may itself be 10. Closing it after dup2 would close
    // the child-side PTY target rather than the original descriptor.
    const close_fds = [_]c_int{ slave, self.master, self.cancel_read, self.cancel_write };
    for (close_fds) |fd| if (fd != 10 and std.c.posix_spawn_file_actions_addclose(&actions, fd) != 0) return failCreate(self, slave);
    if (working_directory) |directory| if (directory[0] != '/') return failCreate(self, slave);
    const empty: [*:0]const u8 = "";
    const integration_path = if (shell_integration and shell_integration_path != null and shell_integration_path.?[0] == '/')
        shell_integration_path.?
    else
        empty;
    var argv = [_:null]?[*:0]u8{
        @constCast(helper),
        @constCast(shell),
        @constCast(working_directory orelse empty),
        @constCast(integration_path),
    };
    if (std.c.posix_spawn(&self.child, helper, &actions, null, &argv, environ) != 0) return failCreate(self, slave);
    _ = c.close(slave);
    const flags = c.fcntl(self.master, c.F_GETFL);
    if (flags >= 0) _ = c.fcntl(self.master, c.F_SETFL, flags | c.O_NONBLOCK);
    self.thread = std.Thread.spawn(.{}, readLoop, .{self}) catch {
        zigonaut_core_destroy(self);
        return null;
    };
    return self;
}

const SlaveAction = enum { inherit, duplicate };

fn slaveAction(fd: c_int) SlaveAction {
    return if (fd == 10) .inherit else .duplicate;
}

fn addSlaveAction(actions: *std.c.posix_spawn_file_actions_t, slave: c_int) c_int {
    return switch (slaveAction(slave)) {
        .inherit => std.c.posix_spawn_file_actions_addinherit_np(actions, slave),
        .duplicate => std.c.posix_spawn_file_actions_adddup2(actions, slave, 10),
    };
}

fn setCloexec(fd: c_int) bool {
    const flags = c.fcntl(fd, c.F_GETFD);
    return flags >= 0 and c.fcntl(fd, c.F_SETFD, flags | c.FD_CLOEXEC) == 0;
}

fn failCreate(self: *Core, slave: c_int) ?*Core {
    _ = c.close(slave);
    if (self.master >= 0) _ = c.close(self.master);
    if (self.cancel_read >= 0) _ = c.close(self.cancel_read);
    if (self.cancel_write >= 0) _ = c.close(self.cancel_write);
    self.terminal.deinit();
    std.heap.c_allocator.destroy(self);
    return null;
}

fn wakeHost(self: *Core) void {
    self.callback_mutex.lock();
    defer self.callback_mutex.unlock();
    const wake = if (!self.stopping.load(.acquire)) self.wake else null;
    if (wake) |callback| callback(self.context);
}

fn readLoop(self: *Core) void {
    var buffer: [16384]u8 = undefined;
    var fds = [_]c.pollfd{
        .{ .fd = self.master, .events = c.POLLIN, .revents = 0 },
        .{ .fd = self.cancel_read, .events = c.POLLIN, .revents = 0 },
    };
    while (true) {
        self.mutex.lock();
        const timeout: c_int = if (self.synchronized_output.remaining(monotonicMillis())) |remaining| @intCast(remaining) else -1;
        self.mutex.unlock();
        const ready = c.poll(&fds, fds.len, timeout);
        if (ready < 0) {
            if (c.__error().* == c.EINTR) continue;
            break;
        }
        if (ready == 0) {
            self.mutex.lock();
            const expired = self.synchronized_output.remaining(monotonicMillis()) == 0;
            if (expired) {
                self.terminal.setSynchronizedOutput(false) catch {};
                _ = self.synchronized_output.clear();
            }
            self.mutex.unlock();
            if (expired) wakeHost(self);
            continue;
        }
        if (fds[1].revents != 0) break;
        if (fds[0].revents == 0) continue;
        const count = c.read(self.master, &buffer, buffer.len);
        if (count < 0) {
            const err = c.__error().*;
            if (err == c.EINTR or err == c.EAGAIN or err == c.EWOULDBLOCK) continue;
            break;
        }
        if (count == 0) break;
        self.mutex.lock();
        self.terminal.feed(buffer[0..@intCast(count)]);
        self.output_generation +%= 1;
        const synchronized = self.terminal.synchronizedOutput();
        const mode_changed = self.synchronized_output.update(synchronized, monotonicMillis());
        self.mutex.unlock();
        if (!synchronized or mode_changed) wakeHost(self);
    }
    if (self.stopping.load(.acquire)) return;
    self.exited.store(true, .release);
    self.mutex.lock();
    _ = self.synchronized_output.clear();
    self.mutex.unlock();
    wakeHost(self);
}

export fn zigonaut_core_resize(self: ?*Core, columns: u16, rows: u16, pixel_width: u16, pixel_height: u16, cell_width: u32, cell_height: u32) void {
    const core = self orelse return;
    var size = c.winsize{ .ws_row = rows, .ws_col = columns, .ws_xpixel = pixel_width, .ws_ypixel = pixel_height };
    core.mutex.lock();
    const synchronized = core.synchronized_output.clear();
    if (synchronized) core.terminal.setSynchronizedOutput(false) catch {};
    core.terminal.resize(columns, rows, cell_width, cell_height) catch {};
    core.mutex.unlock();
    _ = c.ioctl(core.master, c.TIOCSWINSZ, &size);
    if (synchronized) wakeHost(core);
}

export fn zigonaut_core_request_stop(self: ?*Core) void {
    const core = self orelse return;
    if (!core.stopping.swap(true, .acq_rel)) _ = c.write(core.cancel_write, "x", 1);
}

export fn zigonaut_core_write(self: ?*Core, bytes: ?[*]const u8, len: usize) void {
    const core = self orelse return;
    if (len == 0) return;
    const input = bytes orelse return;
    core.mutex.lock();
    const viewport_changed = core.terminal.scrollToBottom() catch false;
    core.mutex.unlock();
    if (viewport_changed) wakeHost(core);
    writeSerialized(core, input[0..len]);
}

export fn zigonaut_core_set_focused(self: ?*Core, focused: bool) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.setFocused(focused);
}

fn macKey(key_code: u16) ?Terminal.Key {
    return switch (key_code) {
        0 => .a,
        1 => .s,
        2 => .d,
        3 => .f,
        4 => .h,
        5 => .g,
        6 => .z,
        7 => .x,
        8 => .c,
        9 => .v,
        10 => .intl_backslash,
        11 => .b,
        12 => .q,
        13 => .w,
        14 => .e,
        15 => .r,
        16 => .y,
        17 => .t,
        18 => .digit_1,
        19 => .digit_2,
        20 => .digit_3,
        21 => .digit_4,
        22 => .digit_6,
        23 => .digit_5,
        24 => .equal,
        25 => .digit_9,
        26 => .digit_7,
        27 => .minus,
        28 => .digit_8,
        29 => .digit_0,
        30 => .bracket_right,
        31 => .o,
        32 => .u,
        33 => .bracket_left,
        34 => .i,
        35 => .p,
        36 => .enter,
        37 => .l,
        38 => .j,
        39 => .quote,
        40 => .k,
        41 => .semicolon,
        42 => .backslash,
        43 => .comma,
        44 => .slash,
        45 => .n,
        46 => .m,
        47 => .period,
        48 => .tab,
        49 => .space,
        50 => .backquote,
        51 => .backspace,
        53 => .escape,
        54 => .meta_right,
        55 => .meta_left,
        56 => .shift_left,
        57 => .caps_lock,
        58 => .alt_left,
        59 => .control_left,
        60 => .shift_right,
        61 => .alt_right,
        62 => .control_right,
        65 => .numpad_decimal,
        67 => .numpad_multiply,
        69 => .numpad_add,
        71 => .num_lock,
        75 => .numpad_divide,
        76 => .numpad_enter,
        78 => .numpad_subtract,
        81 => .numpad_separator,
        82 => .numpad_0,
        83 => .numpad_1,
        84 => .numpad_2,
        85 => .numpad_3,
        86 => .numpad_4,
        87 => .numpad_5,
        88 => .numpad_6,
        89 => .numpad_7,
        91 => .numpad_8,
        92 => .numpad_9,
        93 => .intl_yen,
        94 => .intl_ro,
        95 => .numpad_separator,
        102 => .non_convert,
        104 => .kana_mode,
        96 => .f5,
        97 => .f6,
        98 => .f7,
        99 => .f3,
        100 => .f8,
        101 => .f9,
        103 => .f11,
        105 => .f13,
        106 => .f16,
        107 => .f14,
        109 => .f10,
        111 => .f12,
        113 => .f15,
        114 => .help,
        115 => .home,
        116 => .page_up,
        117 => .delete,
        118 => .f4,
        119 => .end,
        120 => .f2,
        121 => .page_down,
        122 => .f1,
        123 => .arrow_left,
        124 => .arrow_right,
        125 => .arrow_down,
        126 => .arrow_up,
        131 => .f17,
        132 => .f18,
        133 => .f19,
        134 => .f20,
        else => null,
    };
}

export fn zigonaut_core_key(self: ?*Core, event: ?*const KeyEvent) bool {
    const core = self orelse return false;
    const value = event orelse return false;
    if (value.version != 1 or value.size < @sizeOf(KeyEvent) or value.action > 2 or
        value.utf8_length > key_utf8_max_bytes or value.modifiers & ~@as(u16, 0xf) != 0 or
        value.consumed_modifiers & ~@as(u16, 0xf) != 0) return false;
    const key = macKey(value.key_code) orelse return false;
    const utf8 = if (value.utf8_length == 0) "" else (value.utf8 orelse return false)[0..value.utf8_length];
    if (!std.unicode.utf8ValidateSlice(utf8)) return false;
    var buffer: [128]u8 = undefined;
    core.mutex.lock();
    const encoded = core.terminal.encodeKey(key, switch (value.action) {
        0 => .press,
        1 => .repeat,
        2 => .release,
        else => unreachable,
    }, value.modifiers, value.consumed_modifiers, utf8, value.unshifted_codepoint, &buffer) catch {
        core.mutex.unlock();
        return false;
    };
    const viewport_changed = value.action != 2 and encoded.len != 0 and (core.terminal.scrollToBottom() catch false);
    core.mutex.unlock();
    if (viewport_changed) wakeHost(core);
    writeSerialized(core, encoded);
    return true;
}

fn writeSerialized(core: *Core, input: []const u8) void {
    if (input.len == 0 or core.stopping.load(.acquire)) return;
    core.write_mutex.lock();
    defer core.write_mutex.unlock();
    var offset: usize = 0;
    while (offset < input.len) {
        const n = c.write(core.master, input.ptr + offset, input.len - offset);
        if (n < 0) {
            const err = c.__error().*;
            if (err == c.EINTR) continue;
            if (err == c.EAGAIN or err == c.EWOULDBLOCK) {
                var fds = [_]c.pollfd{
                    .{ .fd = core.master, .events = c.POLLOUT, .revents = 0 },
                    .{ .fd = core.cancel_read, .events = c.POLLIN, .revents = 0 },
                };
                while (c.poll(&fds, fds.len, -1) < 0) {
                    if (c.__error().* != c.EINTR) return;
                }
                if (fds[1].revents != 0 or core.stopping.load(.acquire)) return;
                continue;
            }
            return;
        }
        if (n == 0) continue;
        offset += @intCast(n);
    }
}

/// Copies a bounded UTF-8 viewport into caller-owned memory.
export fn zigonaut_core_snapshot(self: ?*Core, output: ?[*]u8, capacity: usize) usize {
    const core = self orelse return 0;
    const destination = output orelse return 0;
    if (capacity == 0) return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    return (core.terminal.writeViewportText(destination[0..capacity]) catch return 0).len;
}

const SnapshotCollector = struct {
    frame: *RenderFrame,
    cells: []RenderCell,
    text: []u8,
    result: *RenderSnapshotResult,
    search_matches: []const search.Match = &.{},
    search_active: ?usize = null,
    viewport_offset: u64 = 0,
    truncated: bool = false,
    dirty_rows: []const bool = &.{},
    emit_row: bool = true,

    pub fn beginFrame(self: *SnapshotCollector, frame: Terminal.Frame) void {
        self.frame.* = .{
            .version = 1,
            .size = @sizeOf(RenderFrame),
            .foreground_rgb = rgb(frame.foreground),
            .background_rgb = rgb(frame.background),
            .cursor_rgb = rgb(frame.cursor),
            .cursor_x = frame.cursor_x,
            .cursor_y = frame.cursor_y,
            .cursor_columns = frame.cursor_columns,
            .cursor_style = @intFromEnum(frame.cursor_style),
            .cursor_visible = @intFromBool(frame.cursor_visible),
            .cursor_has_position = @intFromBool(frame.cursor_has_position),
            .images_skipped = 0,
            .reserved = @splat(0),
        };
    }
    pub fn endFrame(_: *SnapshotCollector, _: Terminal.Frame) void {}
    pub fn beginRow(self: *SnapshotCollector, row: u16) void {
        self.emit_row = row >= self.dirty_rows.len or self.dirty_rows[row];
    }
    pub fn endRow(_: *SnapshotCollector, _: u16) void {}
    pub fn drawImage(_: *SnapshotCollector, _: Terminal.Image) void {}
    pub fn drawCell(self: *SnapshotCollector, cell: Terminal.Cell) void {
        if (!self.emit_row) return;
        var length: usize = 0;
        for (cell.codepoints) |codepoint| {
            const scalar = std.math.cast(u21, codepoint) orelse {
                self.truncated = true;
                return;
            };
            length += std.unicode.utf8CodepointSequenceLength(scalar) catch {
                self.truncated = true;
                return;
            };
        }
        self.result.required_cells +|= 1;
        self.result.required_text_bytes +|= @intCast(length);
        const cell_index = self.result.written_cells;
        const text_offset = self.result.written_text_bytes;
        if (cell_index >= self.cells.len or text_offset + length > self.text.len) {
            self.truncated = true;
            return;
        }
        var encoded_offset: usize = text_offset;
        for (cell.codepoints) |codepoint| {
            const scalar: u21 = @intCast(codepoint);
            encoded_offset += std.unicode.utf8Encode(scalar, self.text[encoded_offset..]) catch unreachable;
        }
        self.cells[cell_index] = .{
            .version = 1,
            .size = @sizeOf(RenderCell),
            .text_offset = text_offset,
            .text_length = @intCast(length),
            .foreground_rgb = rgb(cell.foreground),
            .background_rgb = rgb(cell.background),
            .underline_rgb = rgb(cell.underline_color),
            .x = cell.x,
            .y = cell.y,
            .occupancy = @intFromEnum(cell.occupancy),
            .underline_style = cell.underline,
            .bold = @intFromBool(cell.bold),
            .italic = @intFromBool(cell.italic),
            .faint = @intFromBool(cell.faint),
            .strikethrough = @intFromBool(cell.strikethrough),
            .overline = @intFromBool(cell.overline),
            .selected = @intFromBool(cell.selected),
            .background_is_default = @intFromBool(cell.background_is_default),
            .search_highlight = search.highlight(self.search_matches, self.search_active, self.viewport_offset + cell.y, cell.x),
            .reserved = @splat(0),
        };
        self.result.written_cells += 1;
        self.result.written_text_bytes += @intCast(length);
    }
};

const RenderSelectionRange = struct {
    start: u32 = 0,
    end: u32 = 0,
    present: bool = false,
};

const SelectionCollector = struct {
    ranges: []RenderSelectionRange,

    pub fn beginFrame(_: *SelectionCollector, _: Terminal.Frame) void {}
    pub fn endFrame(_: *SelectionCollector, _: Terminal.Frame) void {}
    pub fn beginRow(_: *SelectionCollector, _: u16) void {}
    pub fn endRow(_: *SelectionCollector, _: u16) void {}
    pub fn drawImage(_: *SelectionCollector, _: Terminal.Image) void {}
    pub fn drawCell(self: *SelectionCollector, cell: Terminal.Cell) void {
        if (!cell.selected or cell.y >= self.ranges.len) return;
        const range = &self.ranges[cell.y];
        const start: u32 = cell.x;
        const span: u32 = if (cell.occupancy == .wide) 2 else 1;
        const end = start + span;
        if (!range.present) {
            range.* = .{ .start = start, .end = end, .present = true };
            return;
        }
        range.start = @min(range.start, start);
        range.end = @max(range.end, end);
    }
};

fn dirtyRows(previous: []const u64, current: []const u64, dirty: []bool) void {
    std.debug.assert(dirty.len == current.len);
    for (current, 0..) |hash, row| dirty[row] = previous.len != current.len or previous[row] != hash;
}

fn hashSelectionRange(seed: u64, range: RenderSelectionRange) u64 {
    var value = seed;
    const present: u8 = @intFromBool(range.present);
    value = std.hash.Wyhash.hash(value, std.mem.asBytes(&present));
    value = std.hash.Wyhash.hash(value, std.mem.asBytes(&range.start));
    return std.hash.Wyhash.hash(value, std.mem.asBytes(&range.end));
}

fn hashSelectionContext(seed: u64, row: usize, ranges: []const RenderSelectionRange) u64 {
    var value = seed;
    value = hashSelectionRange(value, if (row > 0) ranges[row - 1] else .{});
    value = hashSelectionRange(value, ranges[row]);
    return hashSelectionRange(value, if (row + 1 < ranges.len) ranges[row + 1] else .{});
}

fn visualRowHashes(snapshot: *const Terminal.RenderSnapshot, selection_ranges: []const RenderSelectionRange, matches: []const search.Match, active: ?usize, viewport_offset: u64, output: []u64) void {
    const frame = snapshot.frame;
    for (snapshot.row_hashes.items, 0..) |base, y| {
        var value = hashSelectionContext(base, y, selection_ranges);
        if (frame) |current| {
            if (current.cursor_visible and current.cursor_has_position and current.cursor_y == y) {
                value = std.hash.Wyhash.hash(value, std.mem.asBytes(&current.cursor_x));
                value = std.hash.Wyhash.hash(value, std.mem.asBytes(&current.cursor_columns));
                value = std.hash.Wyhash.hash(value, std.mem.asBytes(&current.cursor_style));
                value = std.hash.Wyhash.hash(value, std.mem.asBytes(&current.cursor));
            }
        }
        const row_matches = search.matchesForRow(matches, viewport_offset + y);
        for (row_matches.matches, row_matches.start_index..) |match, index| {
            value = std.hash.Wyhash.hash(value, std.mem.asBytes(&match.start));
            value = std.hash.Wyhash.hash(value, std.mem.asBytes(&match.end));
            const highlight: u2 = if (active == index) 2 else 1;
            value = std.hash.Wyhash.hash(value, std.mem.asBytes(&highlight));
        }
        output[y] = value;
    }
}

/// Writes one coherent viewport into caller-owned arrays. Cell text refers to
/// `text_arena` by offset/length and remains valid only while the caller retains it.
/// Status 3 leaves the retained native frame untouched during synchronized output.
export fn zigonaut_core_render_snapshot(self: ?*Core, previous_hashes: ?[*]const u64, previous_count: u32, frame: ?*RenderFrame, cells: ?[*]RenderCell, cell_capacity: u32, text_arena: ?[*]u8, text_capacity: u32, current_hashes: ?[*]u64, hash_capacity: u32, result: ?*RenderSnapshotResult) void {
    const output = result orelse return;
    output.* = .{ .version = 1, .size = @sizeOf(RenderSnapshotResult), .required_cells = 0, .written_cells = 0, .required_text_bytes = 0, .written_text_bytes = 0, .required_rows = 0, .written_rows = 0, .viewport_offset = 0, .status = 2, .reserved = @splat(0) };
    const core = self orelse return;
    const output_frame = frame orelse return;
    var empty_cells: [0]RenderCell = .{};
    var empty_text: [0]u8 = .{};
    const cell_slice = if (cells) |pointer| pointer[0..cell_capacity] else if (cell_capacity == 0) empty_cells[0..] else return;
    const text_slice = if (text_arena) |pointer| pointer[0..text_capacity] else if (text_capacity == 0) empty_text[0..] else return;
    core.mutex.lock();
    defer core.mutex.unlock();
    if (core.terminal.synchronizedOutput()) {
        output.status = 3;
        return;
    }
    var collector = SnapshotCollector{ .frame = output_frame, .cells = cell_slice, .text = text_slice, .result = output };
    collector.search_matches = core.search.matches.items;
    collector.search_active = core.search.active;
    collector.viewport_offset = if (core.terminal.scrollbar()) |state| state.offset else |_| 0;
    output.viewport_offset = collector.viewport_offset;
    core.render_snapshot.capture(std.heap.c_allocator, &core.terminal) catch return;
    const row_count = core.render_snapshot.row_hashes.items.len;
    output.required_rows = @intCast(row_count);
    const visual = std.heap.c_allocator.alloc(u64, row_count) catch return;
    defer std.heap.c_allocator.free(visual);
    const dirty = std.heap.c_allocator.alloc(bool, row_count) catch return;
    defer std.heap.c_allocator.free(dirty);
    const selection_ranges = std.heap.c_allocator.alloc(RenderSelectionRange, row_count) catch return;
    defer std.heap.c_allocator.free(selection_ranges);
    @memset(selection_ranges, .{});
    if (core.terminal.hasSelection()) {
        var selection_collector = SelectionCollector{ .ranges = selection_ranges };
        core.render_snapshot.replay(&selection_collector);
    }
    visualRowHashes(&core.render_snapshot, selection_ranges, core.search.matches.items, core.search.active, collector.viewport_offset, visual);
    const previous = if (previous_hashes) |pointer| pointer[0..previous_count] else &.{};
    dirtyRows(previous, visual, dirty);
    collector.dirty_rows = dirty;
    core.render_snapshot.replay(&collector);
    if (collector.truncated or hash_capacity < row_count or (row_count != 0 and current_hashes == null)) {
        output.status = 1;
        output.written_cells = 0;
        output.written_text_bytes = 0;
        return;
    }
    if (current_hashes) |destination| @memcpy(destination[0..row_count], visual);
    output.written_rows = @intCast(row_count);
    output.status = 0;
}

test "dirty rows select changes and force a complete snapshot after resize" {
    const current = [_]u64{ 10, 20, 30 };
    var dirty: [3]bool = undefined;
    dirtyRows(&.{ 10, 21, 30 }, &current, &dirty);
    try std.testing.expectEqualSlices(bool, &.{ false, true, false }, &dirty);

    dirtyRows(&current, &current, &dirty);
    try std.testing.expectEqualSlices(bool, &.{ false, false, false }, &dirty);

    dirtyRows(&.{ 10, 20 }, &current, &dirty);
    try std.testing.expectEqualSlices(bool, &.{ true, true, true }, &dirty);
}

test "selection context invalidates the changed row and its neighbours" {
    const bases = [_]u64{ 10, 20, 30, 40 };
    const before = [_]RenderSelectionRange{ .{}, .{}, .{}, .{} };
    const after = [_]RenderSelectionRange{ .{}, .{ .start = 2, .end = 5, .present = true }, .{}, .{} };
    for (bases, 0..) |base, row| {
        const previous = hashSelectionContext(base, row, &before);
        const current = hashSelectionContext(base, row, &after);
        if (row <= 2) {
            try std.testing.expect(previous != current);
        } else {
            try std.testing.expectEqual(previous, current);
        }
    }
}

const ImageCollector = struct {
    images: []RenderImage,
    rgba: []u8,
    known: []const ImageGeneration,
    result: *RenderImagesResult,
    truncated: bool = false,

    fn needsPayload(self: *const ImageCollector, image_id: u32, generation: u64) bool {
        for (self.known) |key| {
            if (key.image_id == image_id and key.generation == generation) return false;
        }
        for (self.images[0..self.result.written_images]) |record| {
            if (record.image_id == image_id and record.generation == generation) return false;
        }
        return true;
    }

    pub fn beginFrame(_: *ImageCollector, _: Terminal.Frame) void {}
    pub fn endFrame(_: *ImageCollector, _: Terminal.Frame) void {}
    pub fn beginRow(_: *ImageCollector, _: u16) void {}
    pub fn endRow(_: *ImageCollector, _: u16) void {}
    pub fn drawCell(_: *ImageCollector, _: Terminal.Cell) void {}
    pub fn drawImage(self: *ImageCollector, image: Terminal.Image) void {
        self.result.required_images +|= 1;
        const include_payload = self.needsPayload(image.image_id, image.generation);
        if (include_payload) self.result.required_data_bytes +|= @intCast(image.pixels.len);
        const image_index = self.result.written_images;
        const data_offset = self.result.written_data_bytes;
        const available_data = self.rgba.len -| data_offset;
        if (image_index >= self.images.len or (include_payload and image.pixels.len > available_data)) {
            self.truncated = true;
            return;
        }
        if (include_payload) @memcpy(self.rgba[data_offset..][0..image.pixels.len], image.pixels);
        self.images[image_index] = .{
            .version = 1,
            .size = @sizeOf(RenderImage),
            .image_id = image.image_id,
            .generation = image.generation,
            .data_offset = data_offset,
            .data_length = if (include_payload) @intCast(image.pixels.len) else 0,
            .width = image.width,
            .height = image.height,
            .source_x = image.source_x,
            .source_y = image.source_y,
            .source_width = image.source_width,
            .source_height = image.source_height,
            .pixel_width = image.pixel_width,
            .pixel_height = image.pixel_height,
            .viewport_column = image.viewport_col,
            .viewport_row = image.viewport_row,
            .z = image.z,
            .x_offset = image.x_offset,
            .y_offset = image.y_offset,
            .reserved = @splat(0),
        };
        self.result.written_images += 1;
        if (include_payload) self.result.written_data_bytes += @intCast(image.pixels.len);
    }
};

/// Replays current placements and emits one RGBA payload for each generation not
/// listed by the host. All arrays are bounded and each placement is atomic.
export fn zigonaut_core_render_images(self: ?*Core, known_generations: ?[*]const ImageGeneration, known_count: u32, images: ?[*]RenderImage, image_capacity: u32, rgba_arena: ?[*]u8, rgba_capacity: u32, result: ?*RenderImagesResult) void {
    const output = result orelse return;
    output.* = .{ .version = 1, .size = @sizeOf(RenderImagesResult), .required_images = 0, .written_images = 0, .required_data_bytes = 0, .written_data_bytes = 0, .status = 2, .reserved = @splat(0) };
    const core = self orelse return;
    var empty_images: [0]RenderImage = .{};
    var empty_rgba: [0]u8 = .{};
    var empty_known: [0]ImageGeneration = .{};
    const known_slice = if (known_generations) |pointer| pointer[0..known_count] else if (known_count == 0) empty_known[0..] else return;
    const image_slice = if (images) |pointer| pointer[0..image_capacity] else if (image_capacity == 0) empty_images[0..] else return;
    const rgba_slice = if (rgba_arena) |pointer| pointer[0..rgba_capacity] else if (rgba_capacity == 0) empty_rgba[0..] else return;
    core.mutex.lock();
    defer core.mutex.unlock();
    var collector = ImageCollector{ .images = image_slice, .rgba = rgba_slice, .known = known_slice, .result = output };
    core.render_snapshot.replay(&collector);
    output.status = if (collector.truncated) 1 else 0;
}

export fn zigonaut_core_set_theme(self: ?*Core, value: ?*const TerminalTheme) bool {
    const core = self orelse return false;
    const input = value orelse return false;
    if (input.version != 1 or input.size < @sizeOf(TerminalTheme)) return false;
    var terminal_theme = theme.Theme{
        .foreground = colorFromRgb(input.foreground_rgb),
        .background = colorFromRgb(input.background_rgb),
        .cursor = colorFromRgb(input.cursor_rgb),
        .ansi = undefined,
    };
    for (input.ansi_rgb, 0..) |ansi, index| terminal_theme.ansi[index] = colorFromRgb(ansi);
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.setTheme(terminal_theme) catch return false;
    return true;
}

export fn zigonaut_core_set_scrollback(self: ?*Core, lines: u32) bool {
    const core = self orelse return false;
    if (lines > 1_000_000) return false;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.setScrollbackSize(lines) catch return false;
    return true;
}

export fn zigonaut_core_set_intense_text_style(self: ?*Core, style: u8) bool {
    const core = self orelse return false;
    if (style > @intFromEnum(Terminal.IntenseTextStyle.bright)) return false;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.setIntenseTextStyle(@enumFromInt(style));
    return true;
}

export fn zigonaut_core_progress(self: ?*Core, result: ?*Progress) void {
    const output = result orelse return;
    output.* = .{ .version = 1, .size = @sizeOf(Progress), .generation = 0, .active = 0, .state = 0, .value = 0, .reserved = @splat(0) };
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    output.generation = core.progress_generation;
    output.active = @intFromBool(core.progress_active);
    output.state = @intFromEnum(core.progress_state);
    output.value = core.progress_value;
}

fn foregroundProcessName(core: *Core, buffer: []u8) []const u8 {
    if (core.master < 0 or buffer.len == 0) return &.{};
    const foreground = c.tcgetpgrp(core.master);
    if (foreground <= 0) return &.{};
    const length = proc_name(foreground, buffer.ptr, @intCast(buffer.len));
    if (length <= 0) return &.{};
    const name = buffer[0..@intCast(length)];
    return if (std.unicode.utf8ValidateSlice(name)) name else &.{};
}

fn isForegroundJob(shell_process_group: c.pid_t, foreground_process_group: c.pid_t) bool {
    return shell_process_group > 0 and foreground_process_group > 0 and
        shell_process_group != foreground_process_group;
}

/// Returns true only when the PTY foreground process group is not the login
/// shell's process group. A missing shell or unavailable PTY state is treated
/// as idle so an already-exited terminal never blocks closing.
export fn zigonaut_core_has_foreground_job(self: ?*Core) bool {
    const core = self orelse return false;
    if (core.master < 0) return false;
    return isForegroundJob(core.child, c.tcgetpgrp(core.master));
}

export fn zigonaut_core_exited(self: ?*Core) bool {
    const core = self orelse return false;
    return core.exited.load(.acquire);
}

export fn zigonaut_core_output_generation(self: ?*Core) u64 {
    const core = self orelse return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    return core.output_generation;
}

/// Returns an explicit OSC title, or the foreground process name when the
/// shell/application has not supplied one. Copies at most `capacity` bytes.
export fn zigonaut_core_title(self: ?*Core, output: ?[*]u8, capacity: u32) u32 {
    const core = self orelse return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    var process_name: [256]u8 = undefined;
    const foreground = foregroundProcessName(core, &process_name);
    const title = if (core.title_explicit)
        core.title[0..core.title_len]
    else if (foreground.len > 0)
        foreground
    else
        core.default_title[0..core.default_title_len];
    const count = @min(capacity, title.len);
    if (output) |destination| @memcpy(destination[0..count], title[0..count]);
    return @intCast(title.len);
}

/// Returns the required URI length, copies a bounded allowed-scheme URI, and
/// reports the coherent viewport-column range occupied by the link.
export fn zigonaut_core_link_at(self: ?*Core, column: u16, row: u16, output: ?[*]u8, capacity: u32, start_column: ?*u16, end_column: ?*u16) u32 {
    const core = self orelse return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    const found = core.terminal.linkAtAlloc(std.heap.c_allocator, .{ .x = column, .y = row }) catch return 0;
    const link = found orelse return 0;
    defer std.heap.c_allocator.free(link.uri);
    if (start_column) |start| start.* = link.start_column;
    if (end_column) |end| end.* = link.end_column;
    const count = @min(capacity, link.uri.len);
    if (output) |destination| @memcpy(destination[0..count], link.uri[0..count]);
    return @intCast(@min(link.uri.len, std.math.maxInt(u32)));
}

export fn zigonaut_core_hint_snapshot(self: ?*Core, records: ?[*]HintRecord, record_capacity: u32, bytes: ?[*]u8, byte_capacity: u32, result: ?*HintResult) void {
    const output = result orelse return;
    output.* = .{ .version = 1, .size = @sizeOf(HintResult), .required_hints = 0, .required_bytes = 0, .written_hints = 0, .written_bytes = 0, .status = 2, .reserved = @splat(0) };
    const core = self orelse return;
    if ((records == null and record_capacity != 0) or (bytes == null and byte_capacity != 0)) return;
    core.mutex.lock();
    defer core.mutex.unlock();
    const candidates = core.terminal.linkHintsAlloc(std.heap.c_allocator) catch return;
    defer hint.deinitCandidates(std.heap.c_allocator, candidates);
    output.required_hints = @intCast(@min(candidates.len, std.math.maxInt(u32)));
    for (candidates) |candidate| output.required_bytes +|= @intCast(candidate.target.len);
    if (record_capacity < output.required_hints or byte_capacity < output.required_bytes or (output.required_hints != 0 and records == null) or (output.required_bytes != 0 and bytes == null)) {
        output.status = 1;
        return;
    }
    var offset: u32 = 0;
    for (candidates, 0..) |candidate, index| {
        if (bytes) |destination| @memcpy(destination[offset..][0..candidate.target.len], candidate.target);
        records.?[index] = .{
            .target_offset = offset,
            .target_length = @intCast(candidate.target.len),
            .row = candidate.row,
            .start_column = candidate.start_column,
            .end_column = candidate.end_column,
            .label_length = candidate.label_len,
            .label = candidate.label,
            .reserved = @splat(0),
        };
        offset += @intCast(candidate.target.len);
    }
    output.written_hints = output.required_hints;
    output.written_bytes = offset;
    output.status = 0;
}

/// Takes ownership from the core queue and frees it after copying. Status is
/// 0 when taken, 1 when empty, 2 for an invalid handle or buffer combination.
export fn zigonaut_core_take_notification(self: ?*Core, title: ?[*]u8, title_capacity: u32, body: ?[*]u8, body_capacity: u32, result: ?*NotificationResult) void {
    const output = result orelse return;
    output.* = .{ .version = 1, .size = @sizeOf(NotificationResult), .required_title = 0, .written_title = 0, .required_body = 0, .written_body = 0, .status = 2, .reserved = @splat(0) };
    const core = self orelse return;
    if ((title == null and title_capacity != 0) or (body == null and body_capacity != 0)) return;
    core.mutex.lock();
    defer core.mutex.unlock();
    if (core.notifications.items.len == 0) {
        output.status = 1;
        return;
    }
    const item = core.notifications.orderedRemove(0);
    defer std.heap.c_allocator.free(item.payload);
    const title_bytes = item.payload[0..item.title_len];
    const body_bytes = item.payload[item.title_len..];
    output.required_title = @intCast(title_bytes.len);
    output.required_body = @intCast(body_bytes.len);
    output.written_title = @min(title_capacity, output.required_title);
    output.written_body = @min(body_capacity, output.required_body);
    if (title) |destination| @memcpy(destination[0..output.written_title], title_bytes[0..output.written_title]);
    if (body) |destination| @memcpy(destination[0..output.written_body], body_bytes[0..output.written_body]);
    output.status = 0;
}

export fn zigonaut_core_set_clipboard_write(self: ?*Core, enabled: bool, max_bytes: u32) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.clipboard_enabled = enabled;
    core.clipboard_max_bytes = max_bytes;
    if (!enabled) while (core.clipboard_writes.pop()) |item| std.heap.c_allocator.free(item.payload);
    if (enabled) {
        var index: usize = 0;
        while (index < core.clipboard_writes.items.len) {
            if (core.clipboard_writes.items[index].payload.len > max_bytes) {
                std.heap.c_allocator.free(core.clipboard_writes.orderedRemove(index).payload);
            } else index += 1;
        }
    }
}

export fn zigonaut_core_take_clipboard_write(self: ?*Core, bytes: ?[*]u8, capacity: u32, result: ?*ClipboardResult) void {
    const output = result orelse return;
    output.* = .{ .version = 1, .size = @sizeOf(ClipboardResult), .token = 0, .required_bytes = 0, .written_bytes = 0, .clear = 0, .status = 2, .reserved = @splat(0) };
    const core = self orelse return;
    if (bytes == null and capacity != 0) return;
    core.mutex.lock();
    defer core.mutex.unlock();
    if (core.clipboard_writes.items.len == 0) {
        output.status = 1;
        return;
    }
    const item = core.clipboard_writes.items[0];
    output.token = item.token;
    output.required_bytes = @intCast(item.payload.len);
    output.clear = @intFromBool(item.clear);
    if (bytes == null or capacity < output.required_bytes) {
        output.status = 3;
        return;
    }
    _ = core.clipboard_writes.orderedRemove(0);
    defer std.heap.c_allocator.free(item.payload);
    output.written_bytes = output.required_bytes;
    if (bytes) |destination| @memcpy(destination[0..output.written_bytes], item.payload);
    output.status = 0;
}

export fn zigonaut_core_paste(self: ?*Core, bytes: ?[*]const u8, len: usize) void {
    const core = self orelse return;
    const input = bytes orelse return;
    if (len == 0) return;
    core.mutex.lock();
    const encoded = core.terminal.encodePasteAlloc(std.heap.c_allocator, @constCast(input[0..len])) catch {
        core.mutex.unlock();
        return;
    };
    core.mutex.unlock();
    defer std.heap.c_allocator.free(encoded);
    zigonaut_core_write(core, encoded.ptr, encoded.len);
}

export fn zigonaut_core_scroll(self: ?*Core, rows: isize) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.scrollViewport(rows);
}

const maximum_search_query_bytes = 256;

fn fillSearchStatus(core: *Core, output: *SearchStatus, status: u8) void {
    output.* = .{
        .version = 1,
        .size = @sizeOf(SearchStatus),
        .matches = @intCast(@min(core.search.matches.items.len, std.math.maxInt(u32))),
        .active = if (core.search.active) |active| @intCast(active) else -1,
        .status = status,
        .scanning = @intFromBool(core.search.scanning),
        .reserved = @splat(0),
    };
}

/// Replaces the query without scanning history. The host advances the scan with
/// bounded `search_tick` calls so PTY parsing and snapshots can take the lock.
export fn zigonaut_core_search_set(self: ?*Core, bytes: ?[*]const u8, len: usize, result: ?*SearchStatus) void {
    const output = result orelse return;
    output.* = std.mem.zeroes(SearchStatus);
    output.version = 1;
    output.size = @sizeOf(SearchStatus);
    output.active = -1;
    output.status = 2;
    const core = self orelse return;
    const input: []const u8 = if (len == 0) "" else (bytes orelse return)[0..len];
    if (len > maximum_search_query_bytes or !std.unicode.utf8ValidateSlice(input[0..len])) {
        output.status = 3;
        return;
    }
    core.mutex.lock();
    defer core.mutex.unlock();
    if (core.search.saved_offset == null) {
        if (core.terminal.scrollbar()) |state| core.search.saved_offset = state.offset else |_| {}
    }
    core.search.query.clearRetainingCapacity();
    core.search.reset();
    core.search.scanned_generation = core.output_generation;
    core.search_cache.clear(std.heap.c_allocator);
    core.search.query.appendSlice(std.heap.c_allocator, input[0..len]) catch return;
    core.search.scanning = len != 0;
    fillSearchStatus(core, output, 0);
}

export fn zigonaut_core_search_tick(self: ?*Core, time_budget_ns: u64, result: ?*SearchStatus) void {
    const output = result orelse return;
    output.* = std.mem.zeroes(SearchStatus);
    output.version = 1;
    output.size = @sizeOf(SearchStatus);
    output.active = -1;
    output.status = 2;
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    if (core.search.scanned_generation != core.output_generation) {
        core.search.reset();
        core.search.scanned_generation = core.output_generation;
        core.search_cache.clear(std.heap.c_allocator);
    }
    if (!core.search.scanning) {
        fillSearchStatus(core, output, 0);
        return;
    }
    const total = core.terminal.totalRows() catch {
        fillSearchStatus(core, output, 2);
        return;
    };
    const start_ns = monotonicNanos();
    var scanned: usize = 0;
    while (core.search.next_row < total) {
        core.terminal.searchRowCached(std.heap.c_allocator, &core.search_cache, core.search.next_row, core.search.query.items, &core.search.matches) catch {
            core.search.scanning = false;
            fillSearchStatus(core, output, 2);
            return;
        };
        core.search.next_row += 1;
        scanned += 1;
        if (scanned != 0 and monotonicNanos() -| start_ns >= time_budget_ns) break;
    }
    core.search.scanning = core.search.next_row < total;
    fillSearchStatus(core, output, 0);
}

export fn zigonaut_core_search_status(self: ?*Core, result: ?*SearchStatus) void {
    const output = result orelse return;
    output.* = std.mem.zeroes(SearchStatus);
    output.version = 1;
    output.size = @sizeOf(SearchStatus);
    output.active = -1;
    output.status = 2;
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    fillSearchStatus(core, output, 0);
}

export fn zigonaut_core_search_navigate(self: ?*Core, forward: bool, result: ?*SearchStatus) void {
    const core = self orelse {
        zigonaut_core_search_status(null, result);
        return;
    };
    core.mutex.lock();
    defer core.mutex.unlock();
    if (core.search.navigate(forward)) |match| {
        const state = core.terminal.scrollbar() catch null;
        if (state) |scrollbar| {
            const target = @min(@as(u64, match.row), scrollbar.total -| scrollbar.len);
            const delta: isize = if (target >= scrollbar.offset) @intCast(target - scrollbar.offset) else -@as(isize, @intCast(scrollbar.offset - target));
            core.terminal.scrollViewport(delta);
        }
    }
    if (result) |output| fillSearchStatus(core, output, 0);
}

export fn zigonaut_core_search_clear(self: ?*Core) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    if (core.search.saved_offset) |target| if (core.terminal.scrollbar()) |state| {
        const delta: isize = if (target >= state.offset) @intCast(target - state.offset) else -@as(isize, @intCast(state.offset - target));
        core.terminal.scrollViewport(delta);
    } else |_| {};
    core.search.saved_offset = null;
    core.search.query.clearRetainingCapacity();
    core.search.reset();
    core.search_cache.clear(std.heap.c_allocator);
}

export fn zigonaut_core_navigate_prompt(self: ?*Core, forward: bool) bool {
    const core = self orelse return false;
    core.mutex.lock();
    defer core.mutex.unlock();
    return core.terminal.navigatePrompt(forward) catch false;
}

export fn zigonaut_core_last_command_output(self: ?*Core, output: ?[*]u8, capacity: usize) usize {
    const core = self orelse return 0;
    if (output == null and capacity != 0) return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    const value = (core.terminal.lastCommandOutputAlloc(std.heap.c_allocator) catch return 0) orelse return 0;
    defer std.heap.c_allocator.free(value);
    if (completeCopyFits(value.len, output != null, capacity)) @memcpy(output.?[0..value.len], value);
    return value.len;
}

export fn zigonaut_core_working_directory(self: ?*Core, output: ?[*]u8, capacity: usize) usize {
    const core = self orelse return 0;
    if (output == null and capacity != 0) return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    const value = (core.terminal.pwdAlloc(std.heap.c_allocator) catch return 0) orelse return 0;
    defer std.heap.c_allocator.free(value);
    if (completeCopyFits(value.len, output != null, capacity)) @memcpy(output.?[0..value.len], value);
    return value.len;
}

export fn zigonaut_core_selection_begin(self: ?*Core, column: u16, row: u16, unit: u8, rectangle: bool) void {
    const core = self orelse return;
    if (unit > @intFromEnum(Terminal.SelectionUnit.logical_line)) return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.selection_unit = @enumFromInt(unit);
    core.selection_rectangle = rectangle and core.selection_unit == .cell;
    core.terminal.beginSelectionAnchor(.{ .x = column, .y = row }) catch {};
    core.terminal.setDerivedSelection(.{ .x = column, .y = row }, core.selection_unit, core.selection_rectangle) catch {};
}

export fn zigonaut_core_selection_update(self: ?*Core, column: u16, row: u16) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.setDerivedSelection(.{ .x = column, .y = row }, core.selection_unit, core.selection_rectangle) catch {};
}

export fn zigonaut_core_selection_end(self: ?*Core) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.endSelectionAnchor();
}

export fn zigonaut_core_selection_clear(self: ?*Core) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.endSelectionAnchor();
    core.terminal.setSelection(null) catch {};
}

export fn zigonaut_core_has_selection(self: ?*Core) bool {
    const core = self orelse return false;
    core.mutex.lock();
    defer core.mutex.unlock();
    return core.terminal.hasSelection();
}

export fn zigonaut_core_copy_selection(self: ?*Core, output: ?[*]u8, capacity: usize) usize {
    const core = self orelse return 0;
    if (output == null and capacity != 0) return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    const selected = core.terminal.selectedTextAlloc(std.heap.c_allocator) catch return 0;
    defer std.heap.c_allocator.free(selected);
    if (completeCopyFits(selected.len, output != null, capacity))
        @memcpy(output.?[0..selected.len], selected);
    return selected.len;
}

export fn zigonaut_core_mouse_tracking(self: ?*Core) bool {
    const core = self orelse return false;
    core.mutex.lock();
    defer core.mutex.unlock();
    return core.terminal.mouseTracking();
}

/// action: press=0, release=1, motion=2. button follows Terminal.MouseButton.
export fn zigonaut_core_mouse(self: ?*Core, action: u8, button: u8, x: i32, y: i32, screen_width: u32, screen_height: u32, cell_width: u32, cell_height: u32, padding_top: u32, padding_bottom: u32, padding_left: u32, padding_right: u32, modifiers: u16, any_button_pressed: bool) bool {
    const core = self orelse return false;
    if (action > @intFromEnum(Terminal.MouseAction.motion) or button > @intFromEnum(Terminal.MouseButton.wheel_right)) return false;
    const mouse_action: Terminal.MouseAction = @enumFromInt(action);
    const mouse_button: Terminal.MouseButton = @enumFromInt(button);
    var buffer: [128]u8 = undefined;
    core.mutex.lock();
    const encoded = core.terminal.encodeMouse(mouse_action, mouse_button, .{ .x = x, .y = y }, modifiers, .{
        .screen_width = screen_width,
        .screen_height = screen_height,
        .cell_width = cell_width,
        .cell_height = cell_height,
        .padding_top = padding_top,
        .padding_bottom = padding_bottom,
        .padding_left = padding_left,
        .padding_right = padding_right,
    }, any_button_pressed, &buffer) catch {
        core.mutex.unlock();
        return false;
    };
    const length = encoded.len;
    core.mutex.unlock();
    writeSerialized(core, buffer[0..length]);
    return true;
}

export fn zigonaut_core_destroy(self: ?*Core) void {
    const core = self orelse return;
    zigonaut_core_request_stop(core);
    if (core.thread) |thread| thread.join();
    core.callback_mutex.lock();
    core.wake = null;
    core.context = null;
    core.callback_mutex.unlock();
    _ = c.close(core.cancel_read);
    _ = c.close(core.cancel_write);
    _ = c.close(core.master);
    reapBounded(core.child);
    core.search_cache.deinit(std.heap.c_allocator);
    core.search.deinit(std.heap.c_allocator);
    for (core.notifications.items) |item| std.heap.c_allocator.free(item.payload);
    core.notifications.deinit(std.heap.c_allocator);
    for (core.clipboard_writes.items) |item| std.heap.c_allocator.free(item.payload);
    core.clipboard_writes.deinit(std.heap.c_allocator);
    core.render_snapshot.deinit(std.heap.c_allocator);
    core.terminal.deinit();
    std.heap.c_allocator.destroy(core);
}

fn reapBounded(child: c.pid_t) void {
    var child_reaped = false;
    const signals = [_]c_int{ c.SIGHUP, c.SIGTERM, c.SIGKILL };
    for (signals) |signal| {
        // The helper creates a session whose process group ID is its PID.
        _ = c.kill(-child, signal);
        var attempts: usize = 0;
        while (attempts < 20) : (attempts += 1) {
            if (!child_reaped) {
                const result = c.waitpid(child, null, c.WNOHANG);
                if (result == child or (result < 0 and c.__error().* == c.ECHILD)) child_reaped = true;
            }
            if (!processGroupExists(child)) return;
            _ = c.usleep(10 * 1000);
        }
    }
    if (!child_reaped) _ = c.waitpid(child, null, c.WNOHANG);
}

fn processGroupExists(pgid: c.pid_t) bool {
    if (c.kill(-pgid, 0) == 0) return true;
    return c.__error().* != c.ESRCH;
}

fn completeCopyFits(required: usize, has_output: bool, capacity: usize) bool {
    return has_output and capacity >= required;
}

fn expectAbiCompatible(comptime ZigType: type, comptime CType: type) !void {
    try std.testing.expectEqual(@sizeOf(CType), @sizeOf(ZigType));
    try std.testing.expectEqual(@alignOf(CType), @alignOf(ZigType));
    inline for (@typeInfo(ZigType).@"struct".fields) |field| {
        if (!@hasField(CType, field.name)) @compileError("public ABI field is missing: " ++ field.name);
        try std.testing.expectEqual(@offsetOf(CType, field.name), @offsetOf(ZigType, field.name));
    }
}

test "Zig ABI records match the public C header" {
    try expectAbiCompatible(RenderFrame, public_abi.zigonaut_render_frame_v1);
    try expectAbiCompatible(RenderCell, public_abi.zigonaut_render_cell_v1);
    try expectAbiCompatible(RenderImage, public_abi.zigonaut_render_image_v1);
    try expectAbiCompatible(ImageGeneration, public_abi.zigonaut_image_generation_v1);
    try expectAbiCompatible(RenderSnapshotResult, public_abi.zigonaut_render_snapshot_result_v1);
    try expectAbiCompatible(RenderImagesResult, public_abi.zigonaut_render_images_result_v1);
    try expectAbiCompatible(TerminalTheme, public_abi.zigonaut_terminal_theme_v1);
    try expectAbiCompatible(Progress, public_abi.zigonaut_progress_v1);
    try expectAbiCompatible(SearchStatus, public_abi.zigonaut_search_status_v1);
    try expectAbiCompatible(NotificationResult, public_abi.zigonaut_notification_result_v1);
    try expectAbiCompatible(ClipboardResult, public_abi.zigonaut_clipboard_result_v1);
    try expectAbiCompatible(KeyEvent, public_abi.zigonaut_key_event_v1);
    try expectAbiCompatible(PseudographicsResult, public_abi.zigonaut_pseudographics_result_v1);
}

test "null ABI handles are safe" {
    zigonaut_core_resize(null, 80, 24, 800, 600, 10, 25);
    zigonaut_core_request_stop(null);
    try std.testing.expect(!zigonaut_core_has_foreground_job(null));
    try std.testing.expect(!zigonaut_core_exited(null));
    try std.testing.expectEqual(@as(u64, 0), zigonaut_core_output_generation(null));
    try std.testing.expect(!zigonaut_core_has_selection(null));
    zigonaut_core_write(null, null, 0);
    zigonaut_core_selection_begin(null, 0, 0, 0, false);
    try std.testing.expectEqual(@as(u32, 0), zigonaut_core_link_at(null, 0, 0, null, 0, null, null));
    var notification = std.mem.zeroes(NotificationResult);
    zigonaut_core_take_notification(null, null, 0, null, 0, &notification);
    try std.testing.expectEqual(@as(u8, 2), notification.status);
    zigonaut_core_set_clipboard_write(null, true, 1024);
    var clipboard = std.mem.zeroes(ClipboardResult);
    zigonaut_core_take_clipboard_write(null, null, 0, &clipboard);
    try std.testing.expectEqual(@as(u8, 2), clipboard.status);
    var images = std.mem.zeroes(RenderImagesResult);
    zigonaut_core_render_images(null, null, 0, null, 0, null, 0, &images);
    try std.testing.expectEqual(@as(u8, 2), images.status);
    var terminal_theme = std.mem.zeroes(TerminalTheme);
    try std.testing.expect(!zigonaut_core_set_theme(null, &terminal_theme));
    try std.testing.expect(!zigonaut_core_set_scrollback(null, 10_000));
    try std.testing.expect(!zigonaut_core_set_intense_text_style(null, 1));
    var progress = std.mem.zeroes(Progress);
    zigonaut_core_progress(null, &progress);
    try std.testing.expectEqual(@as(u8, 0), progress.active);
    zigonaut_core_destroy(null);
}

test "foreground job classification distinguishes the login shell process group" {
    try std.testing.expect(!isForegroundJob(42, 42));
    try std.testing.expect(isForegroundJob(42, 84));
    try std.testing.expect(!isForegroundJob(42, -1));
    try std.testing.expect(!isForegroundJob(42, 0));
    try std.testing.expect(!isForegroundJob(-1, 84));
    try std.testing.expect(!isForegroundJob(0, 84));
}

test "notification and clipboard policies are bounded" {
    try std.testing.expectEqual(@as(usize, 32), notification_queue_capacity);
    try std.testing.expectEqual(@as(usize, 4096), notification_max_bytes);
    try std.testing.expectEqual(@as(usize, 16), clipboard_queue_capacity);
    try std.testing.expectEqual(@as(u32, 1024 * 1024), clipboard_default_max_bytes);
}

test "sized values require a complete destination before copying" {
    try std.testing.expect(!completeCopyFits(4, false, 0));
    try std.testing.expect(!completeCopyFits(4, true, 3));
    try std.testing.expect(completeCopyFits(4, true, 4));
    try std.testing.expect(completeCopyFits(0, true, 0));
}

test "fd 10 is inherited instead of duplicated onto itself" {
    try std.testing.expectEqual(SlaveAction.inherit, slaveAction(10));
    try std.testing.expectEqual(SlaveAction.duplicate, slaveAction(9));
}

test "Apple virtual key codes cover ANSI ISO JIS keypad navigation and functions" {
    try std.testing.expectEqual(Terminal.Key.a, macKey(0).?);
    try std.testing.expectEqual(Terminal.Key.intl_backslash, macKey(10).?);
    try std.testing.expectEqual(Terminal.Key.intl_yen, macKey(93).?);
    try std.testing.expectEqual(Terminal.Key.intl_ro, macKey(94).?);
    try std.testing.expectEqual(Terminal.Key.numpad_7, macKey(89).?);
    try std.testing.expectEqual(Terminal.Key.arrow_left, macKey(123).?);
    try std.testing.expectEqual(Terminal.Key.f20, macKey(134).?);
    try std.testing.expectEqual(@as(?Terminal.Key, null), macKey(63));
}

test "mapped Mac keys preserve repeat and protocol release actions" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();
    terminal.feed("\x1b[>2u");
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("a", try terminal.encodeKey(macKey(0).?, .press, 0, 0, "a", 'a', &buffer));
    try std.testing.expectEqualStrings("a", try terminal.encodeKey(macKey(0).?, .repeat, 0, 0, "a", 'a', &buffer));
    try std.testing.expectEqualStrings("\x1b[97;1:3u", try terminal.encodeKey(macKey(0).?, .release, 0, 0, "", 'a', &buffer));
}

test "mapped Mac control keys use logical text rather than AppKit commands or control characters" {
    var terminal = try Terminal.init(20, 3, theme.rasmus);
    defer terminal.deinit();
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("\x03", try terminal.encodeKey(macKey(8).?, .press, 2, 0, "c", 'c', &buffer));
    try std.testing.expectEqualStrings("\x04", try terminal.encodeKey(macKey(2).?, .press, 2, 0, "d", 'd', &buffer));
}

test "snapshot with null handle is bounded" {
    var bytes = [_]u8{0xaa};
    try std.testing.expectEqual(@as(usize, 0), zigonaut_core_snapshot(null, &bytes, 1));
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[0]);
}

test "styled snapshot collector preserves UTF-8 styles and reports bounds" {
    var frame = std.mem.zeroes(RenderFrame);
    var cells: [1]RenderCell = undefined;
    var text: [4]u8 = undefined;
    var result = std.mem.zeroes(RenderSnapshotResult);
    var collector = SnapshotCollector{ .frame = &frame, .cells = &cells, .text = &text, .result = &result };
    const codepoints = [_]u32{ 0x1f642, 0x301 };
    const cell = Terminal.Cell{
        .x = 3,
        .y = 4,
        .occupancy = .wide,
        .codepoints = &codepoints,
        .foreground = .{ .red = 1, .green = 2, .blue = 3 },
        .background = .{ .red = 4, .green = 5, .blue = 6 },
        .underline_color = .{ .red = 7, .green = 8, .blue = 9 },
        .bold = true,
        .italic = true,
        .faint = false,
        .strikethrough = true,
        .overline = true,
        .underline = 2,
        .selected = true,
    };
    collector.drawCell(cell);
    try std.testing.expect(collector.truncated);
    try std.testing.expectEqual(@as(u32, 1), result.required_cells);
    try std.testing.expectEqual(@as(u32, 6), result.required_text_bytes);
    try std.testing.expectEqual(@as(u32, 0), result.written_cells);

    var large_text: [8]u8 = undefined;
    collector.text = &large_text;
    collector.truncated = false;
    collector.drawCell(cell);
    try std.testing.expectEqualStrings("🙂́", large_text[0..6]);
    try std.testing.expectEqual(@as(u32, 0x010203), cells[0].foreground_rgb);
    try std.testing.expectEqual(@as(u8, 1), cells[0].bold);
    try std.testing.expectEqual(@as(u8, 2), cells[0].underline_style);
    try std.testing.expectEqual(@as(u8, 1), cells[0].selected);
}

test "styled snapshot accounts for and writes graphemes larger than 64 bytes" {
    var frame = std.mem.zeroes(RenderFrame);
    var cells: [1]RenderCell = undefined;
    var short_text: [64]u8 = undefined;
    var result = std.mem.zeroes(RenderSnapshotResult);
    var collector = SnapshotCollector{ .frame = &frame, .cells = &cells, .text = &short_text, .result = &result };
    const codepoints = [_]u32{0x1f642} ** 20;
    const cell = Terminal.Cell{ .x = 0, .y = 0, .occupancy = .narrow, .codepoints = &codepoints, .foreground = theme.rasmus.foreground, .background = theme.rasmus.background, .underline_color = theme.rasmus.foreground, .bold = false, .italic = false, .faint = false, .strikethrough = false, .overline = false, .underline = 0, .selected = false };
    collector.drawCell(cell);
    try std.testing.expectEqual(@as(u32, 80), result.required_text_bytes);
    try std.testing.expectEqual(@as(u32, 0), result.written_text_bytes);
    var text: [80]u8 = undefined;
    collector.text = &text;
    collector.truncated = false;
    collector.drawCell(cell);
    try std.testing.expectEqual(@as(u32, 80), result.written_text_bytes);
    try std.testing.expectEqualStrings("🙂" ** 20, &text);
}

test "image collector preserves placements and rejects partial RGBA copies" {
    const pixels = [_]u8{ 1, 2, 3, 4 };
    const image = Terminal.Image{
        .image_id = 7,
        .generation = 9,
        .pixels = &pixels,
        .width = 1,
        .height = 1,
        .source_x = 0,
        .source_y = 0,
        .source_width = 1,
        .source_height = 1,
        .pixel_width = 20,
        .pixel_height = 30,
        .viewport_col = -1,
        .viewport_row = 2,
        .x_offset = 3,
        .y_offset = 4,
        .z = 5,
    };
    var records: [1]RenderImage = undefined;
    var short_rgba: [3]u8 = undefined;
    var result = std.mem.zeroes(RenderImagesResult);
    var collector = ImageCollector{ .images = &records, .rgba = &short_rgba, .known = &.{}, .result = &result };
    collector.drawImage(image);
    try std.testing.expect(collector.truncated);
    try std.testing.expectEqual(@as(u32, 1), result.required_images);
    try std.testing.expectEqual(@as(u32, 4), result.required_data_bytes);
    try std.testing.expectEqual(@as(u32, 0), result.written_images);

    var rgba: [4]u8 = undefined;
    result = std.mem.zeroes(RenderImagesResult);
    collector = .{ .images = &records, .rgba = &rgba, .known = &.{}, .result = &result };
    collector.drawImage(image);
    try std.testing.expectEqualSlices(u8, &pixels, &rgba);
    try std.testing.expectEqual(@as(u32, 7), records[0].image_id);
    try std.testing.expectEqual(@as(u64, 9), records[0].generation);
    try std.testing.expectEqual(@as(i32, -1), records[0].viewport_column);
    try std.testing.expectEqual(@as(u32, 20), records[0].pixel_width);
    try std.testing.expectEqual(@as(i32, 5), records[0].z);
}

test "image collector emits unknown generations once and always emits placements" {
    const pixels = [_]u8{ 1, 2, 3, 4 };
    const base = Terminal.Image{ .image_id = 7, .generation = 9, .pixels = &pixels, .width = 1, .height = 1, .source_x = 0, .source_y = 0, .source_width = 1, .source_height = 1, .pixel_width = 1, .pixel_height = 1, .viewport_col = 0, .viewport_row = 0, .x_offset = 0, .y_offset = 0, .z = 0 };
    var records: [3]RenderImage = undefined;
    var rgba: [8]u8 = undefined;
    var result = std.mem.zeroes(RenderImagesResult);
    const known = [_]ImageGeneration{.{ .image_id = 8, .reserved = 0, .generation = 1 }};
    var collector = ImageCollector{ .images = &records, .rgba = &rgba, .known = &known, .result = &result };
    collector.drawImage(base);
    var duplicate = base;
    duplicate.viewport_col = 2;
    collector.drawImage(duplicate);
    var cached = base;
    cached.image_id = 8;
    cached.generation = 1;
    collector.drawImage(cached);
    try std.testing.expectEqual(@as(u32, 3), result.written_images);
    try std.testing.expectEqual(@as(u32, 4), result.required_data_bytes);
    try std.testing.expectEqual(@as(u32, 4), records[0].data_length);
    try std.testing.expectEqual(@as(u32, 0), records[1].data_length);
    try std.testing.expectEqual(@as(u32, 0), records[2].data_length);
}

test "null search and mouse APIs and bounded queries are safe" {
    var status = std.mem.zeroes(SearchStatus);
    zigonaut_core_search_status(null, &status);
    try std.testing.expectEqual(@as(u8, 2), status.status);
    zigonaut_core_search_set(null, null, 0, &status);
    zigonaut_core_search_navigate(null, true, &status);
    zigonaut_core_search_clear(null);
    try std.testing.expect(!zigonaut_core_navigate_prompt(null, true));
    try std.testing.expectEqual(@as(usize, 0), zigonaut_core_last_command_output(null, null, 0));
    try std.testing.expectEqual(@as(usize, 0), zigonaut_core_working_directory(null, null, 0));
    try std.testing.expect(!zigonaut_core_mouse_tracking(null));
    try std.testing.expect(!zigonaut_core_mouse(null, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, false));
    try std.testing.expectEqual(@as(usize, 256), maximum_search_query_bytes);
}

test "title callback validates and bounds UTF-8 storage" {
    var core: Core = undefined;
    core.title_len = 0;
    core.title_explicit = false;
    titleChanged(&core, "shell");
    try std.testing.expectEqualStrings("shell", core.title[0..core.title_len]);
    try std.testing.expect(core.title_explicit);
    titleChanged(&core, "");
    try std.testing.expect(!core.title_explicit);
    titleChanged(&core, "shell");
    var oversized: [5000]u8 = @splat('x');
    titleChanged(&core, &oversized);
    try std.testing.expectEqual(@as(u32, 4096), core.title_len);
    oversized[0] = 0xff;
    titleChanged(&core, &oversized);
    try std.testing.expectEqual(@as(u32, 4096), core.title_len);
}
pub const PseudographicsResult = extern struct {
    version: u16,
    size: u16,
    status: i32,
    width: u32,
    height: u32,
    stride: u32,
    offset_x: i32,
    offset_y: i32,
    required_bytes: usize,
    written_bytes: usize,
};

pub export fn zigonaut_pseudographics_covers(codepoint: u32) bool {
    return codepoint <= std.math.maxInt(u21) and pseudographics.covers(@intCast(codepoint));
}

/// Render one full-cell physical-pixel A8 mask. Result version 1 has no
/// trimmed offsets; callers cache using codepoint and all three metrics.
pub export fn zigonaut_pseudographics_render(
    codepoint: u32,
    width: u32,
    height: u32,
    thickness: u32,
    stride: u32,
    output: ?[*]u8,
    capacity: usize,
    result: ?*PseudographicsResult,
) callconv(.c) i32 {
    const r = result orelse return -1;
    const supplied_version = r.version;
    const supplied_size = r.size;
    r.* = .{ .version = 1, .size = @sizeOf(PseudographicsResult), .status = -1, .width = width, .height = height, .stride = stride, .offset_x = 0, .offset_y = 0, .required_bytes = 0, .written_bytes = 0 };
    if (supplied_version != 1 or supplied_size < @sizeOf(PseudographicsResult)) return -1;
    if (codepoint > std.math.maxInt(u21) or width > std.math.maxInt(u16) or height > std.math.maxInt(u16) or thickness > std.math.maxInt(u8)) return -1;
    const metrics: pseudographics.Metrics = .{ .width = @intCast(width), .height = @intCast(height), .thickness = @intCast(thickness) };
    const needed = pseudographics.requiredBytes(metrics, stride) catch return -1;
    r.required_bytes = needed;
    if (!pseudographics.covers(@intCast(codepoint))) return -2;
    if (capacity < needed or output == null) {
        r.status = 1;
        return 1;
    }
    _ = pseudographics.render(@intCast(codepoint), metrics, stride, output.?[0..capacity]) catch return -1;
    r.written_bytes = needed;
    r.status = 0;
    return 0;
}

test "pseudographics ABI validates and reports capacity" {
    var result = std.mem.zeroes(PseudographicsResult);
    try std.testing.expectEqual(@as(i32, -1), zigonaut_pseudographics_render(0x2588, 8, 8, 0, 8, null, 0, null));
    try std.testing.expectEqual(@as(i32, -1), zigonaut_pseudographics_render(0x2588, 8, 8, 1, 8, null, 0, &result));
    result.version = 1;
    result.size = @sizeOf(PseudographicsResult) - 1;
    try std.testing.expectEqual(@as(i32, -1), zigonaut_pseudographics_render(0x2588, 8, 8, 1, 8, null, 0, &result));
    result.version = 1;
    result.size = @sizeOf(PseudographicsResult);
    try std.testing.expectEqual(@as(i32, 1), zigonaut_pseudographics_render(0x2588, 8, 8, 0, 8, null, 0, &result));
    try std.testing.expectEqual(@as(usize, 64), result.required_bytes);
    result.version = 1;
    result.size = @sizeOf(PseudographicsResult);
    try std.testing.expectEqual(@as(i32, -2), zigonaut_pseudographics_render(0x2600, 8, 8, 0, 8, null, 0, &result));
    var bytes: [64]u8 = undefined;
    result.version = 1;
    result.size = @sizeOf(PseudographicsResult);
    try std.testing.expectEqual(@as(i32, 0), zigonaut_pseudographics_render(0x2588, 8, 8, 0, 8, &bytes, bytes.len, &result));
    try std.testing.expectEqual(@as(usize, 64), result.written_bytes);
    for (bytes) |alpha| try std.testing.expectEqual(@as(u8, 255), alpha);
}
