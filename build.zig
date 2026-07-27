const std = @import("std");

const app_version = "0.2.1";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption([]const u8, "git_hash", gitHash(b));
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .simd = false,
    });

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    app_module.addOptions("build_options", build_options);
    app_module.addIncludePath(b.path("winui"));
    configureGhostty(app_module, ghostty);

    const exe = b.addExecutable(.{
        .name = "zigonaut",
        .root_module = app_module,
        .win32_manifest = b.path("zigonaut.manifest"),
    });
    const debug_build = optimize == .Debug;
    const icon_path = if (debug_build)
        "assets/icons/zigonaut-debug.ico"
    else
        "assets/icons/zigonaut.ico";
    const icon_bytes = b.build_root.handle.readFileAlloc(
        b.allocator,
        icon_path,
        1024 * 1024,
    ) catch @panic("unable to read application icon");
    const icon_hash = std.hash.Wyhash.hash(0, icon_bytes);
    const resource_flags: []const []const u8 = if (debug_build)
        &.{ b.fmt("/DAPP_ICON_HASH={x}", .{icon_hash}), "/DDEBUG_BUILD" }
    else
        &.{b.fmt("/DAPP_ICON_HASH={x}", .{icon_hash})};
    exe.root_module.addWin32ResourceFile(.{
        .file = b.path("zigonaut.rc"),
        // The resource compiler does not report files referenced by an RC file
        // to Zig's cache. Vary a harmless define so icon edits rebuild the RES.
        .flags = resource_flags,
    });
    exe.subsystem = .Windows;
    exe.linkLibC();
    exe.linkLibCpp();
    exe.addIncludePath(b.path("src"));
    exe.addCSourceFile(.{
        .file = b.path("src/directwrite_renderer.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    exe.linkSystemLibrary("user32");
    exe.linkSystemLibrary("comctl32");
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("d2d1");
    exe.linkSystemLibrary("d3d11");
    exe.linkSystemLibrary("dwrite");
    exe.linkSystemLibrary("dxgi");
    exe.linkSystemLibrary("dwmapi");
    exe.linkSystemLibrary("advapi32");
    exe.linkSystemLibrary("kernel32");
    exe.linkSystemLibrary("shell32");
    exe.linkSystemLibrary("windowscodecs");
    exe.linkSystemLibrary("ole32");
    const check_step = b.step("check", "Compile Zigonaut without installing it");
    check_step.dependOn(&exe.step);
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);
    const install_themes = b.addInstallDirectory(.{
        .source_dir = b.path("themes"),
        .install_dir = .bin,
        .install_subdir = "themes",
    });
    b.getInstallStep().dependOn(&install_themes.step);

    const run_cmd = b.addSystemCommand(&.{b.getInstallPath(.bin, "zigonaut.exe")});
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run Zigonaut");
    run_step.dependOn(&run_cmd.step);

    const winui_step = b.step("winui", "Build and deploy the WinUI 3 shell");
    if (target.result.os.tag == .windows and
        (target.result.cpu.arch == .x86_64 or target.result.cpu.arch == .aarch64))
    {
        const winui_cmd = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
        winui_cmd.addFileArg(b.path("winui/build.ps1"));
        const target_arch: []const u8 = if (target.result.cpu.arch == .x86_64) "x86_64" else "arm64";
        winui_cmd.addArgs(&.{ "-TargetArch", target_arch, "-Configuration", "Release" });
        if (debug_build) winui_cmd.addArg("-DebugIcon");
        winui_cmd.step.dependOn(&install_exe.step);
        winui_step.dependOn(&winui_cmd.step);
        b.getInstallStep().dependOn(&winui_cmd.step);
    } else {
        const unsupported = b.addFail("the WinUI shell supports only x86_64-windows and aarch64-windows targets");
        winui_step.dependOn(&unsupported.step);
        b.getInstallStep().dependOn(&unsupported.step);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addOptions("build_options", build_options);
    tests.linkLibC();
    tests.linkLibCpp();
    tests.addIncludePath(b.path("src"));
    tests.root_module.addIncludePath(b.path("winui"));
    tests.addCSourceFile(.{
        .file = b.path("src/directwrite_renderer.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    tests.linkSystemLibrary("user32");
    tests.linkSystemLibrary("gdi32");
    tests.linkSystemLibrary("d2d1");
    tests.linkSystemLibrary("d3d11");
    tests.linkSystemLibrary("dwrite");
    tests.linkSystemLibrary("dxgi");
    tests.linkSystemLibrary("kernel32");
    tests.linkSystemLibrary("windowscodecs");
    tests.linkSystemLibrary("ole32");
    configureGhostty(tests.root_module, ghostty);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);

    const benchmark = b.addExecutable(.{
        .name = "zigonaut-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark.linkLibC();
    benchmark.linkLibCpp();
    benchmark.addIncludePath(b.path("src"));
    benchmark.root_module.addIncludePath(b.path("winui"));
    benchmark.addCSourceFile(.{
        .file = b.path("src/directwrite_renderer.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    benchmark.linkSystemLibrary("user32");
    benchmark.linkSystemLibrary("gdi32");
    benchmark.linkSystemLibrary("d2d1");
    benchmark.linkSystemLibrary("d3d11");
    benchmark.linkSystemLibrary("dwrite");
    benchmark.linkSystemLibrary("dxgi");
    benchmark.linkSystemLibrary("kernel32");
    benchmark.linkSystemLibrary("windowscodecs");
    benchmark.linkSystemLibrary("ole32");
    configureGhostty(benchmark.root_module, ghostty);
    const benchmark_step = b.step("benchmark", "Benchmark terminal feed and render traversal");
    benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);
}

fn configureGhostty(module: *std.Build.Module, ghostty: *std.Build.Dependency) void {
    module.addIncludePath(ghostty.path("include"));
    module.addCMacro("GHOSTTY_STATIC", "1");
    module.linkLibrary(ghostty.artifact("ghostty-vt-static"));
}

fn gitHash(b: *std.Build) []const u8 {
    var exit_code: u8 = 0;
    const output = b.runAllowFail(
        &.{ "git", "rev-parse", "HEAD" },
        &exit_code,
        .Ignore,
    ) catch return "unknown";
    return std.mem.trim(u8, output, " \t\r\n");
}
