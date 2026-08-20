const std = @import("std");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("pwd.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

fn validArguments(args: []const []const u8) bool {
    return args.len == 4 and args[1].len > 0 and args[1][0] == '/' and
        (args[2].len == 0 or args[2][0] == '/') and
        (args[3].len == 0 or args[3][0] == '/');
}

fn isZsh(shell: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(shell), "zsh");
}

fn readableRegularFile(path: [*:0]const u8) bool {
    var status: c.struct_stat = undefined;
    return c.stat(path, &status) == 0 and (status.st_mode & c.S_IFMT) == c.S_IFREG and
        c.access(path, c.R_OK) == 0;
}

fn configureZshIntegration(allocator: std.mem.Allocator, shell: []const u8, directory: []const u8) void {
    if (!isZsh(shell) or directory.len == 0 or c.getenv("ZIGONAUT_SHELL_INTEGRATION") != null) return;
    const trampoline = std.fmt.allocPrintSentinel(allocator, "{s}/.zshenv", .{directory}, 0) catch return;
    defer allocator.free(trampoline);
    if (!readableRegularFile(trampoline.ptr)) return;

    const directory_z = allocator.dupeZ(u8, directory) catch return;
    defer allocator.free(directory_z);
    const original_zdotdir = if (c.getenv("ZDOTDIR")) |value| allocator.dupeZ(u8, std.mem.span(value)) catch return else null;
    defer if (original_zdotdir) |value| allocator.free(value);
    const previous_original = if (c.getenv("ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR")) |value| allocator.dupeZ(u8, std.mem.span(value)) catch return else null;
    defer if (previous_original) |value| allocator.free(value);

    const original_set = if (original_zdotdir) |value|
        c.setenv("ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR", value.ptr, 1) == 0
    else
        c.unsetenv("ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR") == 0;
    if (original_set and c.setenv("ZDOTDIR", directory_z.ptr, 1) == 0 and
        c.setenv("ZIGONAUT_SHELL_INTEGRATION", "1", 1) == 0) return;

    if (original_zdotdir) |value| _ = c.setenv("ZDOTDIR", value.ptr, 1) else _ = c.unsetenv("ZDOTDIR");
    if (previous_original) |value| _ = c.setenv("ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR", value.ptr, 1) else _ = c.unsetenv("ZIGONAUT_ZSH_ORIGINAL_ZDOTDIR");
    _ = c.unsetenv("ZIGONAUT_SHELL_INTEGRATION");
}

fn changeToHomeDirectory() bool {
    if (c.getenv("HOME")) |home| {
        if (home[0] == '/' and c.chdir(home) == 0) return true;
    }
    const account = c.getpwuid(c.getuid()) orelse return false;
    const home = account.*.pw_dir orelse return false;
    return home[0] == '/' and c.chdir(home) == 0;
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
    if (args.items[2].len != 0) {
        const directory = init.gpa.dupeZ(u8, args.items[2]) catch return 71;
        defer init.gpa.free(directory);
        if (c.chdir(directory.ptr) != 0) return 71;
    } else if (!changeToHomeDirectory()) return 71;
    const descriptor_limit = c.sysconf(c._SC_OPEN_MAX);
    if (descriptor_limit < 0) return 71;
    var fd: c_int = 3;
    while (fd < descriptor_limit) : (fd += 1) _ = c.close(fd);

    if (c.getenv("TERM") == null and c.setenv("TERM", "xterm-256color", 0) != 0) return 71;
    if (c.getenv("COLORTERM") == null and c.setenv("COLORTERM", "truecolor", 0) != 0) return 71;
    if (c.setenv("TERM_PROGRAM", "Zigonaut", 1) != 0) return 71;

    configureZshIntegration(init.gpa, args.items[1], args.items[3]);

    const shell = init.gpa.dupeZ(u8, args.items[1]) catch return 71;
    var argv = [_:null]?[*:0]u8{ shell.ptr, @constCast("-l") };
    _ = c.execv(shell.ptr, &argv);
    return 71;
}

test "helper accepts exactly one absolute shell path" {
    try std.testing.expect(validArguments(&.{ "helper", "/bin/zsh", "", "" }));
    try std.testing.expect(validArguments(&.{ "helper", "/bin/zsh", "/tmp", "/resources" }));
    try std.testing.expect(!validArguments(&.{"helper"}));
    try std.testing.expect(!validArguments(&.{ "helper", "zsh", "", "" }));
    try std.testing.expect(!validArguments(&.{ "helper", "/bin/zsh", "relative", "" }));
    try std.testing.expect(!validArguments(&.{ "helper", "/bin/zsh", "", "relative" }));
    try std.testing.expect(!validArguments(&.{ "helper", "/bin/zsh", "", "", "extra" }));
}

test "zsh recognition is exact by basename" {
    try std.testing.expect(isZsh("/bin/zsh"));
    try std.testing.expect(isZsh("/opt/homebrew/bin/zsh"));
    try std.testing.expect(!isZsh("/bin/bash"));
    try std.testing.expect(!isZsh("/tmp/zsh-wrapper"));
}
