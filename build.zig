const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
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
    configureGhostty(app_module, ghostty);

    const exe = b.addExecutable(.{
        .name = "zigonaut",
        .root_module = app_module,
        .win32_manifest = b.path("zigonaut.manifest"),
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
    exe.linkSystemLibrary("gdi32");
    exe.linkSystemLibrary("d2d1");
    exe.linkSystemLibrary("dwrite");
    exe.linkSystemLibrary("dwmapi");
    exe.linkSystemLibrary("advapi32");
    exe.linkSystemLibrary("kernel32");
    const install_exe = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install_exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run Zigonaut");
    run_step.dependOn(&run_cmd.step);

    const winui_step = b.step("winui", "Build and deploy the x64 WinUI 3 shell");
    if (target.result.cpu.arch == .x86_64 and target.result.os.tag == .windows) {
        const winui_cmd = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
        winui_cmd.addFileArg(b.path("winui/build.ps1"));
        winui_cmd.addArgs(&.{ "-TargetArch", @tagName(target.result.cpu.arch), "-Configuration", "Release" });
        winui_cmd.step.dependOn(&install_exe.step);
        winui_step.dependOn(&winui_cmd.step);
        b.getInstallStep().dependOn(&winui_cmd.step);
    } else {
        const unsupported = b.addFail("the WinUI shell currently supports only x86_64-windows targets");
        winui_step.dependOn(&unsupported.step);
        b.getInstallStep().dependOn(&unsupported.step);
    }

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/app.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.linkLibC();
    tests.linkLibCpp();
    tests.addIncludePath(b.path("src"));
    tests.addCSourceFile(.{
        .file = b.path("src/directwrite_renderer.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    tests.linkSystemLibrary("user32");
    tests.linkSystemLibrary("gdi32");
    tests.linkSystemLibrary("d2d1");
    tests.linkSystemLibrary("dwrite");
    tests.linkSystemLibrary("kernel32");
    configureGhostty(tests.root_module, ghostty);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn configureGhostty(module: *std.Build.Module, ghostty: *std.Build.Dependency) void {
    module.addIncludePath(ghostty.path("include"));
    module.addCMacro("GHOSTTY_STATIC", "1");
    module.linkLibrary(ghostty.artifact("ghostty-vt-static"));
}
