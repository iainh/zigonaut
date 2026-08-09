const std = @import("std");
const package = @import("build.zig.zon");
const app_version = package.version;

pub fn build(b: *std.Build) void {
    var target_query = b.standardTargetOptionsQueryOnly(.{});
    const target_os = target_query.os_tag orelse b.graph.host.result.os.tag;
    if (target_os == .macos and target_query.os_version_min == null) {
        target_query.os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } };
    }
    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption([]const u8, "git_hash", gitHash(b));
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .simd = true,
    });
    const shared_module = b.createModule(.{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_module.link_libc = true;
    configureGhostty(shared_module, ghostty);
    const shared_test_step = addSharedTests(b, target, optimize, ghostty);

    // Keep native products in separate build graphs: the macOS embedded core
    // must never inherit Win32 resources, C++ sources, or system libraries.
    if (target.result.os.tag == .macos) {
        buildMacos(b, target, optimize, ghostty, shared_module, shared_test_step);
        return;
    }
    if (target.result.os.tag != .windows) {
        const unsupported = b.addFail("Zigonaut supports only Windows and macOS targets");
        b.getInstallStep().dependOn(&unsupported.step);
        return;
    }

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/windows/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .Debug,
    });
    app_module.addImport("shared", shared_module);
    app_module.addOptions("build_options", build_options);
    app_module.addIncludePath(b.path("winui"));
    configureGhostty(app_module, ghostty);

    const exe = b.addExecutable(.{
        .name = "zigonaut",
        .root_module = app_module,
        .win32_manifest = generatedManifest(b, app_version),
    });
    const debug_build = optimize == .Debug;
    const icon_path = if (debug_build)
        "assets/icons/zigonaut-debug.ico"
    else
        "assets/icons/zigonaut.ico";
    const icon_bytes = b.build_root.handle.readFileAlloc(
        b.graph.io,
        icon_path,
        b.allocator,
        .limited(1024 * 1024),
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
    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;
    exe.root_module.addIncludePath(b.path("src/windows"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/windows/directwrite_renderer.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    exe.root_module.linkSystemLibrary("user32", .{});
    exe.root_module.linkSystemLibrary("comctl32", .{});
    exe.root_module.linkSystemLibrary("gdi32", .{});
    exe.root_module.linkSystemLibrary("d2d1", .{});
    exe.root_module.linkSystemLibrary("d3d11", .{});
    exe.root_module.linkSystemLibrary("d3dcompiler_47", .{});
    exe.root_module.linkSystemLibrary("dwrite", .{});
    exe.root_module.linkSystemLibrary("dxgi", .{});
    exe.root_module.linkSystemLibrary("advapi32", .{});
    exe.root_module.linkSystemLibrary("kernel32", .{});
    exe.root_module.linkSystemLibrary("shell32", .{});
    exe.root_module.linkSystemLibrary("windowscodecs", .{});
    exe.root_module.linkSystemLibrary("ole32", .{});
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
            .root_source_file = b.path("src/windows/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests.root_module.addImport("shared", shared_module);
    tests.root_module.addOptions("build_options", build_options);
    tests.root_module.link_libc = true;
    tests.root_module.link_libcpp = true;
    tests.root_module.addIncludePath(b.path("src/windows"));
    tests.root_module.addIncludePath(b.path("winui"));
    tests.root_module.addCSourceFile(.{
        .file = b.path("src/windows/directwrite_renderer.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    tests.root_module.linkSystemLibrary("user32", .{});
    tests.root_module.linkSystemLibrary("gdi32", .{});
    tests.root_module.linkSystemLibrary("d2d1", .{});
    tests.root_module.linkSystemLibrary("d3d11", .{});
    tests.root_module.linkSystemLibrary("d3dcompiler_47", .{});
    tests.root_module.linkSystemLibrary("dwrite", .{});
    tests.root_module.linkSystemLibrary("dxgi", .{});
    tests.root_module.linkSystemLibrary("kernel32", .{});
    tests.root_module.linkSystemLibrary("windowscodecs", .{});
    tests.root_module.linkSystemLibrary("ole32", .{});
    configureGhostty(tests.root_module, ghostty);
    const windows_test_step = b.step("test-windows", "Run Windows client unit tests");
    windows_test_step.dependOn(&b.addRunArtifact(tests).step);
    const test_step = b.step("test", "Run all supported tests");
    test_step.dependOn(shared_test_step);
    test_step.dependOn(windows_test_step);

    const conpty_test = b.addExecutable(.{
        .name = "conpty-resize-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/windows/conpty_resize_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    conpty_test.root_module.link_libc = true;
    conpty_test.root_module.addIncludePath(b.path("src/windows"));
    conpty_test.root_module.addIncludePath(b.path("winui"));
    conpty_test.root_module.linkSystemLibrary("kernel32", .{});
    const install_conpty_test = b.addInstallArtifact(conpty_test, .{});
    const run_conpty_test = b.addSystemCommand(&.{b.getInstallPath(.bin, "conpty-resize-test.exe")});
    run_conpty_test.step.dependOn(&install_conpty_test.step);
    run_conpty_test.step.dependOn(winui_step);
    const conpty_test_step = b.step("test-conpty", "Verify resize does not emit a synthetic ConPTY repaint");
    conpty_test_step.dependOn(&run_conpty_test.step);

    const benchmark = b.addExecutable(.{
        .name = "zigonaut-benchmark",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/windows/benchmark.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    benchmark.root_module.addImport("shared", shared_module);
    benchmark.root_module.link_libc = true;
    benchmark.root_module.link_libcpp = true;
    benchmark.root_module.addIncludePath(b.path("src/windows"));
    benchmark.root_module.addIncludePath(b.path("winui"));
    benchmark.root_module.addCSourceFile(.{
        .file = b.path("src/windows/directwrite_renderer.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    benchmark.root_module.linkSystemLibrary("user32", .{});
    benchmark.root_module.linkSystemLibrary("gdi32", .{});
    benchmark.root_module.linkSystemLibrary("d2d1", .{});
    benchmark.root_module.linkSystemLibrary("d3d11", .{});
    benchmark.root_module.linkSystemLibrary("d3dcompiler_47", .{});
    benchmark.root_module.linkSystemLibrary("dwrite", .{});
    benchmark.root_module.linkSystemLibrary("dxgi", .{});
    benchmark.root_module.linkSystemLibrary("kernel32", .{});
    benchmark.root_module.linkSystemLibrary("windowscodecs", .{});
    benchmark.root_module.linkSystemLibrary("ole32", .{});
    configureGhostty(benchmark.root_module, ghostty);
    const benchmark_step = b.step("benchmark", "Benchmark terminal feed and render traversal");
    benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);
    const install_benchmark = b.addInstallArtifact(benchmark, .{});
    const run_conpty_benchmark = b.addSystemCommand(&.{ b.getInstallPath(.bin, "zigonaut-benchmark.exe"), "--conpty" });
    run_conpty_benchmark.step.dependOn(&install_benchmark.step);
    run_conpty_benchmark.step.dependOn(winui_step);
    const conpty_benchmark_step = b.step("benchmark-conpty", "Benchmark end-to-end ConPTY transport and terminal parsing");
    conpty_benchmark_step.dependOn(&run_conpty_benchmark.step);
}

fn addSharedTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, ghostty: *std.Build.Dependency) *std.Build.Step {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shared/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    tests.root_module.link_libc = true;
    configureGhostty(tests.root_module, ghostty);
    const test_step = b.step("test-shared", "Run shared terminal kernel tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    return test_step;
}

fn buildMacos(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, ghostty: *std.Build.Dependency, shared_module: *std.Build.Module, shared_test_step: *std.Build.Step) void {
    const platform_sync = b.createModule(.{
        .root_source_file = b.path("src/support/platform_sync.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform_sync.link_libc = true;
    const helper = b.addExecutable(.{
        .name = "zigonaut-pty-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/macos/pty_helper.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    helper.root_module.link_libc = true;
    b.installArtifact(helper);
    const module = b.createModule(.{
        .root_source_file = b.path("src/macos/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("shared", shared_module);
    module.addImport("platform_sync", platform_sync);
    module.link_libc = true;
    module.addIncludePath(b.path("macos/include"));
    configureGhostty(module, ghostty);
    const library = b.addLibrary(.{ .name = "zigonaut-core", .root_module = module, .linkage = .dynamic });
    b.installArtifact(library);
    const core_step = b.step("macos-core", "Build the macOS embedded Zig core");
    core_step.dependOn(&library.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/macos/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("shared", shared_module);
    test_module.addImport("platform_sync", platform_sync);
    const tests = b.addTest(.{ .root_module = test_module });
    tests.root_module.link_libc = true;
    tests.root_module.addIncludePath(b.path("macos/include"));
    configureGhostty(tests.root_module, ghostty);
    const core_test_step = b.step("test-macos-core", "Run macOS Zig core and ABI tests");
    core_test_step.dependOn(&b.addRunArtifact(tests).step);
    const helper_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/macos/pty_helper.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    helper_tests.root_module.link_libc = true;
    core_test_step.dependOn(&b.addRunArtifact(helper_tests).step);
    const abi_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/macos/abi_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    abi_tests.root_module.link_libc = true;
    abi_tests.root_module.addIncludePath(b.path("macos/include"));
    const run_abi_tests = b.addRunArtifact(abi_tests);
    run_abi_tests.step.dependOn(b.getInstallStep());
    core_test_step.dependOn(&run_abi_tests.step);

    const swift_tests = b.addSystemCommand(&.{ "swift", "test", "--package-path", "macos" });
    const ui_test_step = b.step("test-macos-ui", "Run macOS Swift unit tests");
    ui_test_step.dependOn(&swift_tests.step);
    const test_step = b.step("test", "Run all supported tests");
    test_step.dependOn(shared_test_step);
    test_step.dependOn(core_test_step);
    test_step.dependOn(ui_test_step);

    const swift = b.addSystemCommand(&.{ "swift", "build", "--package-path", "macos" });
    swift.step.dependOn(b.getInstallStep());
    const bundle = b.addSystemCommand(&.{ "sh", "macos/assemble.sh" });
    bundle.step.dependOn(&swift.step);
    const app_step = b.step("macos-app", "Build the native macOS frontend");
    app_step.dependOn(&bundle.step);
    const run = b.addSystemCommand(&.{ "open", "zig-out/Zigonaut.app" });
    run.step.dependOn(&bundle.step);
    const run_step = b.step("macos-run", "Run the native macOS frontend");
    run_step.dependOn(&run.step);
}

fn configureGhostty(module: *std.Build.Module, ghostty: *std.Build.Dependency) void {
    module.addIncludePath(ghostty.path("include"));
    module.addCMacro("GHOSTTY_STATIC", "1");
    module.linkLibrary(ghostty.artifact("ghostty-vt-static"));
}

fn generatedManifest(b: *std.Build, version: []const u8) std.Build.LazyPath {
    const source = b.build_root.handle.readFileAlloc(
        b.graph.io,
        "zigonaut.manifest",
        b.allocator,
        .limited(64 * 1024),
    ) catch @panic("unable to read application manifest");
    const placeholder = "0.0.0.0";
    if (std.mem.count(u8, source, placeholder) != 1) @panic("application manifest must contain one version placeholder");
    const semantic_version = std.SemanticVersion.parse(version) catch @panic("package version must be valid semantic versioning");
    if (semantic_version.major > std.math.maxInt(u16) or semantic_version.minor > std.math.maxInt(u16) or semantic_version.patch > std.math.maxInt(u16)) {
        @panic("package version components must fit the Windows manifest version format");
    }
    const manifest_version = b.fmt("{d}.{d}.{d}.0", .{ semantic_version.major, semantic_version.minor, semantic_version.patch });
    const contents = std.mem.replaceOwned(u8, b.allocator, source, placeholder, manifest_version) catch @panic("out of memory");
    return b.addWriteFiles().add("zigonaut.manifest", contents);
}

fn gitHash(b: *std.Build) []const u8 {
    var exit_code: u8 = 0;
    const output = b.runAllowFail(
        &.{ "git", "rev-parse", "HEAD" },
        &exit_code,
        .ignore,
    ) catch return "unknown";
    return std.mem.trim(u8, output, " \t\r\n");
}
