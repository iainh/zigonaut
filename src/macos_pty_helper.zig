const std = @import("std");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

fn validArguments(args: []const []const u8) bool {
    return args.len == 2 and args[1].len > 0 and args[1][0] == '/';
}

pub fn main(init: std.process.Init) u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(init.gpa);
    var iterator = std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa) catch return 71;
    defer iterator.deinit();
    while (iterator.next()) |arg| args.append(init.gpa, arg) catch return 71;
    if (!validArguments(args.items)) return 64;

    if (c.setsid() < 0) return 71;
    var attributes: c.termios = undefined;
    if (c.tcgetattr(10, &attributes) != 0) return 71;
    attributes.c_iflag |= c.IUTF8;
    if (c.tcsetattr(10, c.TCSANOW, &attributes) != 0) return 71;
    if (c.ioctl(10, c.TIOCSCTTY, @as(c_int, 0)) < 0) return 71;
    inline for (0..3) |fd| if (c.dup2(10, fd) < 0) return 71;
    const descriptor_limit = c.sysconf(c._SC_OPEN_MAX);
    if (descriptor_limit < 0) return 71;
    var fd: c_int = 3;
    while (fd < descriptor_limit) : (fd += 1) _ = c.close(fd);

    if (c.getenv("TERM") == null and c.setenv("TERM", "xterm-256color", 0) != 0) return 71;
    if (c.getenv("COLORTERM") == null and c.setenv("COLORTERM", "truecolor", 0) != 0) return 71;
    if (c.setenv("TERM_PROGRAM", "Zigonaut", 1) != 0) return 71;

    const shell = init.gpa.dupeZ(u8, args.items[1]) catch return 71;
    var argv = [_:null]?[*:0]u8{ shell.ptr, @constCast("-l") };
    _ = c.execv(shell.ptr, &argv);
    return 71;
}

test "helper accepts exactly one absolute shell path" {
    try std.testing.expect(validArguments(&.{ "helper", "/bin/zsh" }));
    try std.testing.expect(!validArguments(&.{"helper"}));
    try std.testing.expect(!validArguments(&.{ "helper", "zsh" }));
    try std.testing.expect(!validArguments(&.{ "helper", "/bin/zsh", "extra" }));
}
