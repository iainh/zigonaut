const std = @import("std");
const c = @cImport({
    @cInclude("util.h");
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("spawn.h");
    @cInclude("signal.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});
const Terminal = @import("terminal.zig").Terminal;
const search = @import("search.zig");
const theme = @import("theme.zig");
extern var environ: [*:null]?[*:0]u8;

const notification_queue_capacity = 32;
const notification_max_bytes = 4096;
const clipboard_queue_capacity = 16;
const clipboard_default_max_bytes: u32 = 1024 * 1024;

const QueuedNotification = struct { payload: []u8, title_len: u16 };
const QueuedClipboard = struct { payload: []u8, token: u64, clear: bool };

pub const Wake = ?*const fn (?*anyopaque) callconv(.c) void;
const Core = struct {
    mutex: @import("platform_sync.zig").Mutex = .{},
    write_mutex: @import("platform_sync.zig").Mutex = .{},
    callback_mutex: @import("platform_sync.zig").Mutex = .{},
    terminal: Terminal,
    master: c_int,
    cancel_read: c_int,
    cancel_write: c_int,
    child: c.pid_t,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    wake: Wake,
    context: ?*anyopaque,
    title: [4096]u8 = undefined,
    title_len: u32 = 0,
    notifications: std.ArrayList(QueuedNotification) = .empty,
    clipboard_writes: std.ArrayList(QueuedClipboard) = .empty,
    clipboard_enabled: bool = false,
    clipboard_max_bytes: u32 = clipboard_default_max_bytes,
    next_clipboard_token: u64 = 1,
    search_scratch: Terminal.SearchScratch = .{},
    search_query: std.ArrayList(u8) = .empty,
    search_matches: std.ArrayList(search.Match) = .empty,
    search_active: ?usize = null,
    search_saved_offset: ?u64 = null,
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
    reserved: [7]u8,
};

pub const RenderSnapshotResult = extern struct {
    version: u32,
    size: u32,
    required_cells: u32,
    written_cells: u32,
    required_text_bytes: u32,
    written_text_bytes: u32,
    status: u8,
    reserved: [7]u8,
};

fn rgb(color: theme.Color) u32 {
    return (@as(u32, color.red) << 16) | (@as(u32, color.green) << 8) | color.blue;
}

fn titleChanged(context: ?*anyopaque, title: []const u8) void {
    const self: *Core = @ptrCast(@alignCast(context orelse return));
    if (!std.unicode.utf8ValidateSlice(title)) return;
    var count = @min(title.len, self.title.len);
    while (count > 0 and !std.unicode.utf8ValidateSlice(title[0..count])) count -= 1;
    @memcpy(self.title[0..count], title[0..count]);
    self.title_len = @intCast(count);
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

// Called by terminal.feed while mutex is held. Only serialize the PTY write;
// acquiring the terminal mutex here would deadlock.
fn terminalWritePty(context: ?*anyopaque, bytes: []const u8) void {
    const self: *Core = @ptrCast(@alignCast(context orelse return));
    writeSerialized(self, bytes);
}

export fn zigonaut_core_create(helper_path: ?[*:0]const u8, shell_path: ?[*:0]const u8, wake: Wake, context: ?*anyopaque) ?*Core {
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
    titleChanged(self, initial_title);
    self.terminal.setTitleChanged(titleChanged, self) catch return failCreate(self, -1);
    self.terminal.setWritePty(terminalWritePty, self) catch return failCreate(self, -1);
    self.terminal.setDesktopNotification(desktopNotification, self) catch return failCreate(self, -1);
    self.terminal.setClipboardWrite(clipboardWrite, self) catch return failCreate(self, -1);
    var slave: c_int = -1;
    var size = c.winsize{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    if (c.openpty(&self.master, &slave, null, null, &size) != 0) {
        self.terminal.deinit();
        allocator.destroy(self);
        return null;
    }
    var cancel: [2]c_int = undefined;
    if (c.pipe(&cancel) != 0) return failCreate(self, slave);
    self.cancel_read = cancel[0];
    self.cancel_write = cancel[1];
    if (!setCloexec(self.master) or !setCloexec(slave) or !setCloexec(cancel[0]) or !setCloexec(cancel[1])) return failCreate(self, slave);
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return failCreate(self, slave);
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    if (addSlaveAction(&actions, slave) != 0) return failCreate(self, slave);
    // A source descriptor may itself be 10. Closing it after dup2 would close
    // the child-side PTY target rather than the original descriptor.
    const close_fds = [_]c_int{ slave, self.master, self.cancel_read, self.cancel_write };
    for (close_fds) |fd| if (fd != 10 and c.posix_spawn_file_actions_addclose(&actions, fd) != 0) return failCreate(self, slave);
    var argv = [_:null]?[*:0]u8{ @constCast(helper), @constCast(shell) };
    if (c.posix_spawn(&self.child, helper, &actions, null, &argv, environ) != 0) return failCreate(self, slave);
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

fn addSlaveAction(actions: *c.posix_spawn_file_actions_t, slave: c_int) c_int {
    return switch (slaveAction(slave)) {
        .inherit => c.posix_spawn_file_actions_addinherit_np(actions, slave),
        .duplicate => c.posix_spawn_file_actions_adddup2(actions, slave, 10),
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

fn readLoop(self: *Core) void {
    var buffer: [16384]u8 = undefined;
    var fds = [_]c.pollfd{
        .{ .fd = self.master, .events = c.POLLIN, .revents = 0 },
        .{ .fd = self.cancel_read, .events = c.POLLIN, .revents = 0 },
    };
    while (true) {
        const ready = c.poll(&fds, fds.len, -1);
        if (ready < 0) {
            if (c.__error().* == c.EINTR) continue;
            break;
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
        self.mutex.unlock();
        self.callback_mutex.lock();
        const wake = if (!self.stopping.load(.acquire)) self.wake else null;
        const context = self.context;
        if (wake) |callback| callback(context);
        self.callback_mutex.unlock();
    }
}

export fn zigonaut_core_resize(self: ?*Core, columns: u16, rows: u16) void {
    const core = self orelse return;
    var size = c.winsize{ .ws_row = rows, .ws_col = columns, .ws_xpixel = 0, .ws_ypixel = 0 };
    core.mutex.lock();
    core.terminal.resize(columns, rows, 0, 0) catch {};
    core.mutex.unlock();
    _ = c.ioctl(core.master, c.TIOCSWINSZ, &size);
}

export fn zigonaut_core_request_stop(self: ?*Core) void {
    const core = self orelse return;
    if (!core.stopping.swap(true, .acq_rel)) _ = c.write(core.cancel_write, "x", 1);
}

export fn zigonaut_core_write(self: ?*Core, bytes: ?[*]const u8, len: usize) void {
    const core = self orelse return;
    if (len == 0) return;
    const input = bytes orelse return;
    writeSerialized(core, input[0..len]);
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
    pub fn beginRow(_: *SnapshotCollector, _: u16) void {}
    pub fn endRow(_: *SnapshotCollector, _: u16) void {}
    pub fn drawImage(self: *SnapshotCollector, _: Terminal.Image) void {
        self.frame.images_skipped = 1;
        self.truncated = true;
    }
    pub fn drawCell(self: *SnapshotCollector, cell: Terminal.Cell) void {
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

/// Writes one coherent viewport into caller-owned arrays. Cell text refers to
/// `text_arena` by offset/length and remains valid only while the caller retains it.
export fn zigonaut_core_render_snapshot(self: ?*Core, frame: ?*RenderFrame, cells: ?[*]RenderCell, cell_capacity: u32, text_arena: ?[*]u8, text_capacity: u32, result: ?*RenderSnapshotResult) void {
    const output = result orelse return;
    output.* = .{ .version = 1, .size = @sizeOf(RenderSnapshotResult), .required_cells = 0, .written_cells = 0, .required_text_bytes = 0, .written_text_bytes = 0, .status = 2, .reserved = @splat(0) };
    const core = self orelse return;
    const output_frame = frame orelse return;
    var empty_cells: [0]RenderCell = .{};
    var empty_text: [0]u8 = .{};
    const cell_slice = if (cells) |pointer| pointer[0..cell_capacity] else if (cell_capacity == 0) empty_cells[0..] else return;
    const text_slice = if (text_arena) |pointer| pointer[0..text_capacity] else if (text_capacity == 0) empty_text[0..] else return;
    core.mutex.lock();
    defer core.mutex.unlock();
    var collector = SnapshotCollector{ .frame = output_frame, .cells = cell_slice, .text = text_slice, .result = output };
    collector.search_matches = core.search_matches.items;
    collector.search_active = core.search_active;
    collector.viewport_offset = if (core.terminal.scrollbar()) |state| state.offset else |_| 0;
    core.terminal.renderViewport(&collector) catch return;
    output.status = if (collector.truncated) 1 else 0;
}

/// Returns the required title byte count and copies at most `capacity` bytes.
export fn zigonaut_core_title(self: ?*Core, output: ?[*]u8, capacity: u32) u32 {
    const core = self orelse return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    const count = @min(capacity, core.title_len);
    if (output) |destination| @memcpy(destination[0..count], core.title[0..count]);
    return core.title_len;
}

/// Returns the required URI length and copies a bounded, allowed-scheme URI.
export fn zigonaut_core_link_at(self: ?*Core, column: u16, row: u16, output: ?[*]u8, capacity: u32) u32 {
    const core = self orelse return 0;
    core.mutex.lock();
    defer core.mutex.unlock();
    const found = core.terminal.linkAtAlloc(std.heap.c_allocator, .{ .x = column, .y = row }) catch return 0;
    const link = found orelse return 0;
    defer std.heap.c_allocator.free(link.uri);
    const count = @min(capacity, link.uri.len);
    if (output) |destination| @memcpy(destination[0..count], link.uri[0..count]);
    return @intCast(@min(link.uri.len, std.math.maxInt(u32)));
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
        .matches = @intCast(@min(core.search_matches.items.len, std.math.maxInt(u32))),
        .active = if (core.search_active) |active| @intCast(active) else -1,
        .status = status,
        .reserved = @splat(0),
    };
}

/// Searches the complete current scrollback. Swift invokes this on its serialized
/// worker queue, so large histories never block the AppKit main actor.
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
    if (core.search_saved_offset == null) {
        if (core.terminal.scrollbar()) |state| core.search_saved_offset = state.offset else |_| {}
    }
    core.search_query.clearRetainingCapacity();
    core.search_matches.clearRetainingCapacity();
    core.search_active = null;
    core.search_query.appendSlice(std.heap.c_allocator, input[0..len]) catch return;
    if (len != 0) {
        const total = core.terminal.totalRows() catch return;
        for (0..total) |row| core.terminal.searchRow(std.heap.c_allocator, &core.search_scratch, @intCast(row), core.search_query.items, &core.search_matches) catch return;
    }
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
    if (core.search_matches.items.len != 0) {
        const current = core.search_active orelse if (forward) core.search_matches.items.len - 1 else 0;
        core.search_active = if (forward) (current + 1) % core.search_matches.items.len else if (current == 0) core.search_matches.items.len - 1 else current - 1;
        const match = core.search_matches.items[core.search_active.?];
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
    if (core.search_saved_offset) |target| if (core.terminal.scrollbar()) |state| {
        const delta: isize = if (target >= state.offset) @intCast(target - state.offset) else -@as(isize, @intCast(state.offset - target));
        core.terminal.scrollViewport(delta);
    } else |_| {};
    core.search_saved_offset = null;
    core.search_query.clearRetainingCapacity();
    core.search_matches.clearRetainingCapacity();
    core.search_active = null;
}

export fn zigonaut_core_selection_begin(self: ?*Core, column: u16, row: u16) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.beginSelectionAnchor(.{ .x = column, .y = row }) catch {};
    core.terminal.setDerivedSelection(.{ .x = column, .y = row }, .cell, false) catch {};
}

export fn zigonaut_core_selection_update(self: ?*Core, column: u16, row: u16) void {
    const core = self orelse return;
    core.mutex.lock();
    defer core.mutex.unlock();
    core.terminal.setDerivedSelection(.{ .x = column, .y = row }, .cell, false) catch {};
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
export fn zigonaut_core_mouse(self: ?*Core, action: u8, button: u8, x: i32, y: i32, screen_width: u32, screen_height: u32, cell_width: u32, cell_height: u32, padding: u32, modifiers: u16, any_button_pressed: bool) bool {
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
        .padding_top = padding,
        .padding_bottom = padding,
        .padding_left = padding,
        .padding_right = padding,
    }, any_button_pressed, &buffer) catch {
        core.mutex.unlock();
        return false;
    };
    const length = encoded.len;
    core.mutex.unlock();
    zigonaut_core_write(core, &buffer, length);
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
    core.search_scratch.deinit(std.heap.c_allocator);
    core.search_query.deinit(std.heap.c_allocator);
    core.search_matches.deinit(std.heap.c_allocator);
    for (core.notifications.items) |item| std.heap.c_allocator.free(item.payload);
    core.notifications.deinit(std.heap.c_allocator);
    for (core.clipboard_writes.items) |item| std.heap.c_allocator.free(item.payload);
    core.clipboard_writes.deinit(std.heap.c_allocator);
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

test "null ABI handles are safe" {
    zigonaut_core_resize(null, 80, 24);
    zigonaut_core_request_stop(null);
    zigonaut_core_write(null, null, 0);
    try std.testing.expectEqual(@as(u32, 0), zigonaut_core_link_at(null, 0, 0, null, 0));
    var notification = std.mem.zeroes(NotificationResult);
    zigonaut_core_take_notification(null, null, 0, null, 0, &notification);
    try std.testing.expectEqual(@as(u8, 2), notification.status);
    zigonaut_core_set_clipboard_write(null, true, 1024);
    var clipboard = std.mem.zeroes(ClipboardResult);
    zigonaut_core_take_clipboard_write(null, null, 0, &clipboard);
    try std.testing.expectEqual(@as(u8, 2), clipboard.status);
    zigonaut_core_destroy(null);
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

test "null search and mouse APIs and bounded queries are safe" {
    var status = std.mem.zeroes(SearchStatus);
    zigonaut_core_search_status(null, &status);
    try std.testing.expectEqual(@as(u8, 2), status.status);
    zigonaut_core_search_set(null, null, 0, &status);
    zigonaut_core_search_navigate(null, true, &status);
    zigonaut_core_search_clear(null);
    try std.testing.expect(!zigonaut_core_mouse_tracking(null));
    try std.testing.expect(!zigonaut_core_mouse(null, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, false));
    try std.testing.expectEqual(@as(usize, 256), maximum_search_query_bytes);
}

test "title callback validates and bounds UTF-8 storage" {
    var core: Core = undefined;
    core.title_len = 0;
    titleChanged(&core, "shell");
    try std.testing.expectEqualStrings("shell", core.title[0..core.title_len]);
    var oversized: [5000]u8 = @splat('x');
    titleChanged(&core, &oversized);
    try std.testing.expectEqual(@as(u32, 4096), core.title_len);
    oversized[0] = 0xff;
    titleChanged(&core, &oversized);
    try std.testing.expectEqual(@as(u32, 4096), core.title_len);
}
