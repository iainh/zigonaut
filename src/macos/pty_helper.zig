const std = @import("std");
const c = @cImport({
    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("pwd.h");
    @cInclude("signal.h");
    @cInclude("stdlib.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/wait.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

fn validArguments(args: []const []const u8) bool {
    return args.len == 4 and args[1].len > 0 and args[1][0] == '/' and
        (args[2].len == 0 or args[2][0] == '/') and
        (args[3].len == 0 or args[3][0] == '/');
}

fn isShell(shell: []const u8, name: []const u8) bool {
    return std.mem.eql(u8, std.fs.path.basename(shell), name);
}

fn readableRegularFile(path: [*:0]const u8) bool {
    var status: c.struct_stat = undefined;
    return c.stat(path, &status) == 0 and (status.st_mode & c.S_IFMT) == c.S_IFREG and
        c.access(path, c.R_OK) == 0;
}

fn integrationFile(allocator: std.mem.Allocator, root: []const u8, relative: []const u8) ?[:0]u8 {
    if (root.len == 0 or c.getenv("ZIGONAUT_SHELL_INTEGRATION") != null) return null;
    const path = std.fmt.allocPrintSentinel(allocator, "{s}/{s}", .{ root, relative }, 0) catch return null;
    if (readableRegularFile(path.ptr)) return path;
    allocator.free(path);
    return null;
}

fn configureZshIntegration(allocator: std.mem.Allocator, shell: []const u8, root: []const u8) void {
    if (!isShell(shell, "zsh")) return;
    const trampoline = integrationFile(allocator, root, "zsh/.zshenv") orelse return;
    defer allocator.free(trampoline);
    const directory = std.fs.path.dirname(trampoline) orelse return;
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

fn configureFishIntegration(allocator: std.mem.Allocator, shell: []const u8, root: []const u8) bool {
    if (!isShell(shell, "fish")) return false;
    const script = integrationFile(allocator, root, "fish/zigonaut.fish") orelse return false;
    defer allocator.free(script);
    if (!shellVersionAtLeast(allocator, shell, 2, 7)) return false;
    if (c.setenv("ZIGONAUT_FISH_INTEGRATION", script.ptr, 1) == 0 and
        c.setenv("ZIGONAUT_SHELL_INTEGRATION", "1", 1) == 0) return true;
    _ = c.unsetenv("ZIGONAUT_FISH_INTEGRATION");
    _ = c.unsetenv("ZIGONAUT_SHELL_INTEGRATION");
    return false;
}

fn versionAtLeast(output: []const u8, minimum_major: u16, minimum_minor: u16) bool {
    const marker = "version ";
    const start = (std.mem.indexOf(u8, output, marker) orelse return false) + marker.len;
    const dot = std.mem.indexOfScalarPos(u8, output, start, '.') orelse return false;
    const end = std.mem.indexOfNonePos(u8, output, dot + 1, "0123456789") orelse output.len;
    const major = std.fmt.parseInt(u16, output[start..dot], 10) catch return false;
    const minor = std.fmt.parseInt(u16, output[dot + 1 .. end], 10) catch return false;
    return major > minimum_major or (major == minimum_major and minor >= minimum_minor);
}

fn shellVersionAtLeast(allocator: std.mem.Allocator, shell: []const u8, minimum_major: u16, minimum_minor: u16) bool {
    const shell_z = allocator.dupeZ(u8, shell) catch return false;
    defer allocator.free(shell_z);
    var descriptors: [2]c_int = undefined;
    if (c.pipe(&descriptors) != 0) return false;
    const child = c.fork();
    if (child == 0) {
        _ = c.close(descriptors[0]);
        if (c.dup2(descriptors[1], 1) < 0 or c.dup2(descriptors[1], 2) < 0) c._exit(127);
        _ = c.close(descriptors[1]);
        _ = c.setenv("LC_ALL", "C", 1);
        var argv = [_:null]?[*:0]u8{ shell_z.ptr, @constCast("--version") };
        _ = c.execv(shell_z.ptr, &argv);
        c._exit(127);
    }
    _ = c.close(descriptors[1]);
    if (child < 0) {
        _ = c.close(descriptors[0]);
        return false;
    }
    var output: [128]u8 = undefined;
    var event = c.pollfd{ .fd = descriptors[0], .events = c.POLLIN | c.POLLHUP, .revents = 0 };
    if (c.poll(&event, 1, 1000) <= 0) {
        _ = c.close(descriptors[0]);
        _ = c.kill(child, c.SIGKILL);
        _ = c.waitpid(child, null, 0);
        return false;
    }
    const read = c.read(descriptors[0], &output, output.len);
    _ = c.close(descriptors[0]);
    var status: c_int = 0;
    var waited: c.pid_t = 0;
    for (0..100) |_| {
        waited = c.waitpid(child, &status, c.WNOHANG);
        if (waited != 0) break;
        _ = c.usleep(10_000);
    }
    if (waited == 0) {
        _ = c.kill(child, c.SIGKILL);
        waited = c.waitpid(child, &status, 0);
    }
    if (read <= 0 or waited != child or !c.WIFEXITED(status) or c.WEXITSTATUS(status) != 0) return false;
    return versionAtLeast(output[0..@intCast(read)], minimum_major, minimum_minor);
}

fn configureBashIntegration(allocator: std.mem.Allocator, shell: []const u8, root: []const u8) void {
    if (!isShell(shell, "bash") or std.mem.eql(u8, shell, "/bin/bash")) return;
    const script = integrationFile(allocator, root, "bash/zigonaut.bash") orelse return;
    defer allocator.free(script);
    if (!shellVersionAtLeast(allocator, shell, 4, 4)) return;
    const original_prompt = if (c.getenv("PROMPT_COMMAND")) |value| allocator.dupeZ(u8, std.mem.span(value)) catch return else null;
    defer if (original_prompt) |value| allocator.free(value);
    const inherited = if (original_prompt) |value| value[0..value.len] else "";
    const prompt_command = std.fmt.allocPrintSentinel(
        allocator,
        "builtin source \"$ZIGONAUT_BASH_INTEGRATION\" 2>/dev/null{s}{s}",
        .{ if (inherited.len == 0) "" else ";", inherited },
        0,
    ) catch return;
    defer allocator.free(prompt_command);
    if (c.setenv("ZIGONAUT_BASH_INTEGRATION", script.ptr, 1) == 0 and
        c.setenv("PROMPT_COMMAND", prompt_command.ptr, 1) == 0 and
        c.setenv("ZIGONAUT_SHELL_INTEGRATION", "1", 1) == 0) return;
    if (original_prompt) |value| _ = c.setenv("PROMPT_COMMAND", value.ptr, 1) else _ = c.unsetenv("PROMPT_COMMAND");
    _ = c.unsetenv("ZIGONAUT_BASH_INTEGRATION");
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
    const fish_integration = configureFishIntegration(init.gpa, args.items[1], args.items[3]);
    configureBashIntegration(init.gpa, args.items[1], args.items[3]);

    const shell = init.gpa.dupeZ(u8, args.items[1]) catch return 71;
    if (fish_integration) {
        var argv = [_:null]?[*:0]u8{
            shell.ptr,
            @constCast("-l"),
            @constCast("--init-command=test -r \"$ZIGONAUT_FISH_INTEGRATION\"; and source \"$ZIGONAUT_FISH_INTEGRATION\" 2>/dev/null"),
        };
        _ = c.execv(shell.ptr, &argv);
    } else {
        var argv = [_:null]?[*:0]u8{ shell.ptr, @constCast("-l") };
        _ = c.execv(shell.ptr, &argv);
    }
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

test "shell recognition is exact by basename" {
    try std.testing.expect(isShell("/bin/zsh", "zsh"));
    try std.testing.expect(isShell("/opt/homebrew/bin/bash", "bash"));
    try std.testing.expect(isShell("/usr/local/bin/fish", "fish"));
    try std.testing.expect(!isShell("/bin/bash", "zsh"));
    try std.testing.expect(!isShell("/tmp/zsh-wrapper", "zsh"));
}

test "shell version parsing enforces integration minimums" {
    try std.testing.expect(versionAtLeast("fish, version 2.7.0\n", 2, 7));
    try std.testing.expect(versionAtLeast("GNU bash, version 5.3.15(1)-release\n", 4, 4));
    try std.testing.expect(!versionAtLeast("fish, version 2.6.0\n", 2, 7));
    try std.testing.expect(!versionAtLeast("GNU bash, version 4.3.0\n", 4, 4));
    try std.testing.expect(!versionAtLeast("not a shell\n", 2, 7));
}
