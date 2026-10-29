const std = @import("std");
const builtin = @import("builtin");
const package = @import("build.zig.zon");
const Translator = @import("translate_c").Translator;
const app_version = package.version;

comptime {
    const required_zig_version = std.SemanticVersion.parse(package.minimum_zig_version) catch
        @compileError("build.zig.zon minimum_zig_version must be valid semantic versioning");
    if (builtin.zig_version.order(required_zig_version) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "unsupported Zig version: expected {}, found {}",
            .{ required_zig_version, builtin.zig_version },
        ));
    }
}

pub fn build(b: *std.Build) void {
    const fmt = b.addFmt(.{ .paths = &.{ b.path("build.zig"), b.path("src") }, .check = true });
    const fmt_step = b.step("test:fmt", "Check Zig formatting");
    fmt_step.dependOn(&fmt.step);

    var target_query = b.standardTargetOptionsQueryOnly(.{});
    const target_os = target_query.os_tag orelse b.graph.host.result.os.tag;
    if (target_os == .macos and target_query.os_version_min == null) {
        target_query.os_version_min = .{ .semver = .{ .major = 15, .minor = 0, .patch = 0 } };
    }
    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});
    const debug_info = b.option(bool, "debug-info", "Retain debug information in optimized Windows builds") orelse false;
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    build_options.addOption([]const u8, "git_hash", gitHash(b));
    const ghostty = b.dependency("ghostty", .{
        .target = target,
        .optimize = optimize,
        .@"emit-lib-vt" = true,
        .simd = true,
    });
    const apple_sdk = findAppleSdk(b, target);
    const shared_module = b.createModule(.{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared_module.link_libc = true;
    configureGhostty(shared_module, ghostty);
    const shared_test_step = addSharedTests(b, target, optimize, ghostty, apple_sdk);

    // Keep native products in separate build graphs: the macOS embedded core
    // must never inherit Win32 resources, C++ sources, or system libraries.
    if (target.result.os.tag == .macos) {
        buildMacos(b, target, optimize, ghostty, shared_module, shared_test_step, fmt_step, apple_sdk);
        return;
    }
    if (target.result.os.tag == .linux) {
        buildLinux(b, target, optimize, ghostty, shared_module, shared_test_step, fmt_step);
        return;
    }
    if (target.result.os.tag != .windows) {
        const unsupported = b.addFail("Zigonaut supports only Windows, macOS, and Linux targets");
        b.getInstallStep().dependOn(&unsupported.step);
        return;
    }

    const app_module = b.createModule(.{
        .root_source_file = b.path("src/windows/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize != .debug and !debug_info,
    });
    app_module.addImport("shared", shared_module);
    app_module.addOptions("build_options", build_options);
    app_module.addIncludePath(b.path("winui"));
    configureGhostty(app_module, ghostty);
    configureWindowsHeaders(app_module);

    const exe = b.addExecutable(.{
        .name = "zigonaut",
        .root_module = app_module,
        .win32_manifest = generatedManifest(b, app_version),
    });
    const debug_build = optimize == .debug;
    const icon_path = if (debug_build)
        "assets/icons/zigonaut-debug.ico"
    else
        "assets/icons/zigonaut.ico";
    const icon_bytes = b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        b.pathJoin(&.{ b.root.sub_path, icon_path }),
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
    exe.subsystem = .windows;
    exe.root_module.link_libc = true;
    exe.root_module.link_libcpp = true;
    exe.root_module.addIncludePath(b.path("src/windows"));
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/windows/directwrite_renderer.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    exe.root_module.addCSourceFile(.{
        .file = b.path("src/windows/scroll_trace.cpp"),
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
    exe.root_module.linkSystemLibrary("wtsapi32", .{});
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
    const install_shell_integration = b.addInstallDirectory(.{
        .source_dir = b.path("assets/shell-integration/powershell"),
        .install_dir = .bin,
        .install_subdir = "shell-integration",
    });
    b.getInstallStep().dependOn(&install_shell_integration.step);

    const installed_exe: std.Build.LazyPath = .{ .relative = .{ .base = .install_bin, .sub_path = "zigonaut.exe" } };
    const run_cmd = b.addRunFile(installed_exe);
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

    const tab_rendering_test = b.addSystemCommand(&.{ "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File" });
    tab_rendering_test.addFileArg(b.path("winui/test-tab-rendering.ps1"));
    tab_rendering_test.addArg("-Executable");
    tab_rendering_test.addFileArg(installed_exe);
    tab_rendering_test.step.dependOn(winui_step);
    const tab_rendering_test_step = b.step("test-winui-tabs", "Verify terminal rendering and input after changing tabs");
    tab_rendering_test_step.dependOn(&tab_rendering_test.step);

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
    tests.root_module.addCSourceFile(.{
        .file = b.path("src/windows/scroll_trace.cpp"),
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN" },
    });
    tests.root_module.linkSystemLibrary("user32", .{});
    tests.root_module.linkSystemLibrary("gdi32", .{});
    tests.root_module.linkSystemLibrary("d2d1", .{});
    tests.root_module.linkSystemLibrary("d3d11", .{});
    tests.root_module.linkSystemLibrary("d3dcompiler_47", .{});
    tests.root_module.linkSystemLibrary("dwrite", .{});
    tests.root_module.linkSystemLibrary("dxgi", .{});
    tests.root_module.linkSystemLibrary("advapi32", .{});
    tests.root_module.linkSystemLibrary("kernel32", .{});
    tests.root_module.linkSystemLibrary("wtsapi32", .{});
    tests.root_module.linkSystemLibrary("windowscodecs", .{});
    tests.root_module.linkSystemLibrary("ole32", .{});
    configureGhostty(tests.root_module, ghostty);
    configureWindowsHeaders(tests.root_module);
    const windows_test_step = b.step("test-windows", "Run Windows client unit tests");
    windows_test_step.dependOn(&b.addRunArtifact(tests).step);
    const test_step = b.step("test", "Run all supported tests");
    test_step.dependOn(shared_test_step);
    test_step.dependOn(windows_test_step);
    addCiStep(b, check_step, test_step, fmt_step);

    const conpty_test = b.addExecutable(.{
        .name = "conpty-resize-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/windows/conpty_resize_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    conpty_test.root_module.link_libc = true;
    configureWindowsHeaders(conpty_test.root_module);
    conpty_test.root_module.addIncludePath(b.path("src/windows"));
    conpty_test.root_module.addIncludePath(b.path("winui"));
    conpty_test.root_module.linkSystemLibrary("kernel32", .{});
    const install_conpty_test = b.addInstallArtifact(conpty_test, .{});
    const run_conpty_test = b.addRunFile(.{ .relative = .{ .base = .install_bin, .sub_path = "conpty-resize-test.exe" } });
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
        .flags = &.{ "-std=c++17", "-DUNICODE", "-D_UNICODE", "-DWIN32_LEAN_AND_MEAN", "-DZIGONAUT_BENCHMARK_PRESENT" },
    });
    benchmark.root_module.linkSystemLibrary("user32", .{});
    benchmark.root_module.linkSystemLibrary("gdi32", .{});
    benchmark.root_module.linkSystemLibrary("d2d1", .{});
    benchmark.root_module.linkSystemLibrary("d3d11", .{});
    benchmark.root_module.linkSystemLibrary("d3dcompiler_47", .{});
    benchmark.root_module.linkSystemLibrary("dcomp", .{});
    benchmark.root_module.linkSystemLibrary("dwrite", .{});
    benchmark.root_module.linkSystemLibrary("dxgi", .{});
    benchmark.root_module.linkSystemLibrary("kernel32", .{});
    benchmark.root_module.linkSystemLibrary("windowscodecs", .{});
    benchmark.root_module.linkSystemLibrary("ole32", .{});
    configureGhostty(benchmark.root_module, ghostty);
    configureWindowsHeaders(benchmark.root_module);
    const benchmark_step = b.step("benchmark", "Benchmark terminal feed and render traversal");
    benchmark_step.dependOn(&b.addRunArtifact(benchmark).step);
    const install_benchmark = b.addInstallArtifact(benchmark, .{});
    const run_conpty_benchmark = b.addRunFile(.{ .relative = .{ .base = .install_bin, .sub_path = "zigonaut-benchmark.exe" } });
    run_conpty_benchmark.addArg("--conpty");
    run_conpty_benchmark.step.dependOn(&install_benchmark.step);
    run_conpty_benchmark.step.dependOn(winui_step);
    const conpty_benchmark_step = b.step("benchmark-conpty", "Benchmark end-to-end ConPTY transport and terminal parsing");
    conpty_benchmark_step.dependOn(&run_conpty_benchmark.step);
}

fn addSharedTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, ghostty: *std.Build.Dependency, apple_sdk: ?AppleSdk) *std.Build.Step {
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/shared/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    tests.root_module.link_libc = true;
    configureGhostty(tests.root_module, ghostty);
    applyAppleSdk(tests, apple_sdk);
    const test_step = b.step("test-shared", "Run shared terminal kernel tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    return test_step;
}

fn buildMacos(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, ghostty: *std.Build.Dependency, shared_module: *std.Build.Module, shared_test_step: *std.Build.Step, fmt_step: *std.Build.Step, apple_sdk: ?AppleSdk) void {
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
    configurePtyHeaders(helper.root_module);
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
    configureMacosHeaders(module);
    const library = b.addLibrary(.{ .name = "zigonaut-core", .root_module = module, .linkage = .dynamic });
    applyAppleSdk(library, apple_sdk);
    b.installArtifact(library);
    const core_step = b.step("macos-core", "Build the macOS embedded Zig core");
    core_step.dependOn(&library.step);
    const check_step = b.step("check", "Compile Zigonaut without installing it");
    check_step.dependOn(&helper.step);
    check_step.dependOn(&library.step);

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
    configureMacosHeaders(tests.root_module);
    applyAppleSdk(tests, apple_sdk);
    const core_test_step = b.step("test-macos-core", "Run macOS Zig core and ABI tests");
    core_test_step.dependOn(&b.addRunArtifact(tests).step);
    const helper_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/macos/pty_helper.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    helper_tests.root_module.link_libc = true;
    configurePtyHeaders(helper_tests.root_module);
    core_test_step.dependOn(&b.addRunArtifact(helper_tests).step);
    const shell_integration_tests = b.addSystemCommand(&.{"python3"});
    shell_integration_tests.addFileArg(b.path("assets/shell-integration/test_shell_integration.py"));
    shell_integration_tests.addArtifactArg(helper);
    core_test_step.dependOn(&shell_integration_tests.step);
    const abi_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/macos/abi_test.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    abi_tests.root_module.link_libc = true;
    abi_tests.root_module.addIncludePath(b.path("macos/include"));
    const public_abi = translateHeaders(abi_tests.root_module, "public-abi", "#include <zigonaut_core.h>\n");
    public_abi.addIncludePath(b.path("macos/include"));
    const run_abi_tests = b.addRunArtifact(abi_tests);
    run_abi_tests.step.dependOn(b.getInstallStep());
    core_test_step.dependOn(&run_abi_tests.step);

    const swift_configuration: []const u8 = if (optimize == .debug) "debug" else "release";
    // Swift Build can stamp the deployment target as the linked SDK version.
    // Supply both explicitly so AppKit adopts the selected SDK's appearance.
    const swift_sdk_args: []const []const u8 = if (apple_sdk) |sdk| &.{
        "--sdk",    sdk.root,
        "-Xlinker", "-platform_version",
        "-Xlinker", "macos",
        "-Xlinker", "15.0",
        "-Xlinker", std.mem.trim(u8, b.run(&.{ "xcrun", "--sdk", sdk.root, "--show-sdk-version" }), " \t\r\n"),
    } else &.{};
    const swift_tests = b.addSystemCommand(&.{
        "xcrun",
        "--sdk",
        "macosx",
        "swift",
        "test",
        "--package-path",
        "macos",
        "--configuration",
        swift_configuration,
    });
    swift_tests.addArgs(swift_sdk_args);
    swift_tests.step.dependOn(b.getInstallStep());
    const ui_test_step = b.step("test-macos-ui", "Run macOS Swift unit tests");
    ui_test_step.dependOn(&swift_tests.step);
    const test_step = b.step("test", "Run all supported tests");
    test_step.dependOn(shared_test_step);
    test_step.dependOn(core_test_step);
    test_step.dependOn(ui_test_step);
    addCiStep(b, check_step, test_step, fmt_step);

    const swift = b.addSystemCommand(&.{
        "xcrun",
        "--sdk",
        "macosx",
        "swift",
        "build",
        "--package-path",
        "macos",
        "--configuration",
        swift_configuration,
    });
    swift.addArgs(swift_sdk_args);
    swift.step.dependOn(b.getInstallStep());
    const bundle = b.addSystemCommand(&.{ "sh", "macos/assemble.sh", swift_configuration });
    bundle.addDirectoryArg(b.path(if (optimize == .debug)
        "assets/icons/macos/ZigonautDebug.icon"
    else
        "assets/icons/macos/Zigonaut.icon"));
    bundle.step.dependOn(&swift.step);
    const app_step = b.step("macos-app", "Build the native macOS frontend");
    app_step.dependOn(&bundle.step);
    const run = b.addSystemCommand(&.{ "open", "-n", "zig-out/Zigonaut.app" });
    run.step.dependOn(&bundle.step);
    const run_step = b.step("macos-run", "Run the native macOS frontend");
    run_step.dependOn(&run.step);
}

fn buildLinux(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, ghostty: *std.Build.Dependency, shared_module: *std.Build.Module, shared_test_step: *std.Build.Step, fmt_step: *std.Build.Step) void {
    const dependencies = b.addSystemCommand(&.{
        "pkg-config", "--print-errors", "--exists", "gtk4 >= 4.18", "libadwaita-1 >= 1.7", "glib-2.0 >= 2.84", "libpng >= 1.6.48",
    });
    const module = b.createModule(.{
        .root_source_file = b.path("src/linux/core.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    module.addImport("shared", shared_module);
    module.addIncludePath(b.path("src/linux"));
    configureGhostty(module, ghostty);
    configureLinuxHeaders(module, ghostty);
    // The dependency check above requires pkg-config. Zig 0.17's .force also
    // rejects GTK's architecture flags (-mfpmath=sse, -msse, -msse2).
    module.linkSystemLibrary("gtk4", .{});
    module.linkSystemLibrary("libadwaita-1", .{});
    // Debian 13's API baseline, including when building with newer headers.
    module.addCMacro("GDK_VERSION_MIN_REQUIRED", "GDK_VERSION_4_18");
    module.addCMacro("GDK_VERSION_MAX_ALLOWED", "GDK_VERSION_4_18");
    module.addCMacro("ADW_VERSION_MIN_REQUIRED", "ADW_VERSION_1_7");
    module.addCMacro("ADW_VERSION_MAX_ALLOWED", "ADW_VERSION_1_7");
    module.addCMacro("GLIB_VERSION_MIN_REQUIRED", "GLIB_VERSION_2_84");
    module.addCMacro("GLIB_VERSION_MAX_ALLOWED", "GLIB_VERSION_2_84");
    module.addCMacro("ZIGONAUT_VERSION", b.fmt("\"{s}\"", .{app_version}));
    module.addCSourceFile(.{
        .file = b.path("src/linux/gtk.c"),
        .flags = &.{ "-std=c11", "-D_GNU_SOURCE", "-Wall", "-Wextra", "-Werror" },
    });
    module.addCSourceFile(.{
        .file = b.path("src/linux/settings.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
    });
    module.addAnonymousImport("fluent-light", .{ .root_source_file = b.path("themes/fluent-light.json") });
    module.addAnonymousImport("fluent-dark", .{ .root_source_file = b.path("themes/fluent-dark.json") });
    module.linkSystemLibrary("libpng", .{ .use_pkg_config = .force });
    const exe = b.addExecutable(.{ .name = "zigonaut", .root_module = module });
    exe.step.dependOn(&dependencies.step);
    b.installArtifact(exe);
    b.installFile("src/linux/com.spiralpoint.zigonaut.desktop", "share/applications/com.spiralpoint.zigonaut.desktop");
    b.installFile("assets/icons/windows/zigonaut-256.png", "share/icons/hicolor/256x256/apps/com.spiralpoint.zigonaut.png");
    for ([_][]const u8{ "bash", "zsh", "fish" }) |shell| {
        const resources = b.addInstallDirectory(.{
            .source_dir = b.path(b.fmt("assets/shell-integration/{s}", .{shell})),
            .install_dir = .prefix,
            .install_subdir = b.fmt("share/zigonaut/shell-integration/{s}", .{shell}),
        });
        b.getInstallStep().dependOn(&resources.step);
    }
    const check_step = b.step("check", "Compile Zigonaut without installing it");
    check_step.dependOn(&exe.step);
    // Run the installed layout, including shell startup resources.
    const installed_exe: std.Build.LazyPath = .{ .relative = .{ .base = .install_bin, .sub_path = "zigonaut" } };
    const run = b.addRunFile(installed_exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the native GTK frontend").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/linux/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    tests.step.dependOn(&dependencies.step);
    tests.root_module.addImport("shared", shared_module);
    tests.root_module.addIncludePath(b.path("src/linux"));
    tests.root_module.addAnonymousImport("fluent-light", .{ .root_source_file = b.path("themes/fluent-light.json") });
    tests.root_module.addAnonymousImport("fluent-dark", .{ .root_source_file = b.path("themes/fluent-dark.json") });
    configureGhostty(tests.root_module, ghostty);
    configureLinuxHeaders(tests.root_module, ghostty);
    tests.root_module.linkSystemLibrary("cairo", .{ .use_pkg_config = .force });
    tests.root_module.linkSystemLibrary("libpng", .{ .use_pkg_config = .force });
    const linux_tests = b.step("test-linux", "Run Linux frontend contract tests");
    linux_tests.dependOn(&b.addRunArtifact(tests).step);
    const shell_tests = b.step("test-linux-shell-integration", "Test real Bash, Zsh and fish PTYs (requires all three shells)");
    const zsh_tests = b.addSystemCommand(&.{"python3"});
    zsh_tests.addFileArg(b.path("assets/shell-integration/test_shell_integration.py"));
    zsh_tests.addFileArg(installed_exe);
    zsh_tests.addArg("--linux");
    zsh_tests.step.dependOn(b.getInstallStep());
    shell_tests.dependOn(&zsh_tests.step);
    const additional_shell_tests = b.addSystemCommand(&.{"python3"});
    additional_shell_tests.addFileArg(b.path("assets/shell-integration/test_additional_shells.py"));
    additional_shell_tests.addFileArg(installed_exe);
    additional_shell_tests.addArgs(&.{ "/bin/bash", "/usr/bin/fish", "--linux" });
    additional_shell_tests.step.dependOn(b.getInstallStep());
    shell_tests.dependOn(&additional_shell_tests.step);
    const test_step = b.step("test", "Run all supported tests");
    test_step.dependOn(shared_test_step);
    test_step.dependOn(linux_tests);
    addCiStep(b, check_step, test_step, fmt_step);

    const ui_tests = b.addSystemCommand(&.{"python3"});
    ui_tests.addFileArg(b.path("src/linux/test_ui.py"));
    ui_tests.addFileArg(installed_exe);
    ui_tests.step.dependOn(b.getInstallStep());
    b.step("test-linux-ui", "Test the GTK frontend on an X11 display (requires xdotool)").dependOn(&ui_tests.step);
    const settings_tests = b.addSystemCommand(&.{ "dbus-run-session", "--", "/usr/bin/python3" });
    settings_tests.addFileArg(b.path("src/linux/test_settings_ui.py"));
    settings_tests.addFileArg(installed_exe);
    settings_tests.step.dependOn(b.getInstallStep());
    b.step("test-linux-settings-ui", "Test native settings and profiles (requires python3-pyatspi and X11)").dependOn(&settings_tests.step);
    const image_tests = b.addSystemCommand(&.{"/usr/bin/python3"});
    image_tests.addFileArg(b.path("src/linux/test_images_ui.py"));
    image_tests.addFileArg(installed_exe);
    image_tests.step.dependOn(b.getInstallStep());
    b.step("test-linux-images-ui", "Test Kitty pixels and pane lifetimes at 2x (requires python3-pil and X11)").dependOn(&image_tests.step);
    const pointer_tests = b.addSystemCommand(&.{ "dbus-run-session", "--", "/usr/bin/python3" });
    pointer_tests.addFileArg(b.path("src/linux/test_pointer_ui.py"));
    pointer_tests.addFileArg(installed_exe);
    pointer_tests.step.dependOn(b.getInstallStep());
    b.step("test-linux-pointer-ui", "Test native mouse reporting and links (requires python3-pyatspi and X11)").dependOn(&pointer_tests.step);
}

fn addCiStep(b: *std.Build, check_step: *std.Build.Step, test_step: *std.Build.Step, fmt_step: *std.Build.Step) void {
    const ci_step = b.step("ci", "Run all required checks");
    ci_step.dependOn(check_step);
    ci_step.dependOn(test_step);
    ci_step.dependOn(fmt_step);
}

fn configureGhostty(module: *std.Build.Module, ghostty: *std.Build.Dependency) void {
    module.addIncludePath(ghostty.path("include"));
    module.addCMacro("GHOSTTY_STATIC", "1");
    module.linkLibrary(ghostty.artifact("ghostty-vt-static"));
    const b = module.owner;
    // Shared terminal code and native PNG decoders must use one module for
    // the generated file; Zig rejects the same file in separate modules.
    if (b.modules.get("ghostty-vt")) |vt| {
        module.addImport("ghostty-vt", vt);
        return;
    }
    const vt = translateHeaders(module, "ghostty-vt", "#define GHOSTTY_STATIC 1\n#include <ghostty/vt.h>\n");
    vt.addIncludePath(ghostty.path("include"));
    b.modules.put(b.allocator, "ghostty-vt", vt.mod) catch @panic("OOM");
}

fn translateHeaders(module: *std.Build.Module, name: []const u8, source: []const u8) Translator {
    const b = module.owner;
    const sdk = findAppleSdk(b, module.resolved_target.?);
    const translated = Translator.init(b.dependency("translate_c", .{}), .{
        .name = name,
        .c_source_file = b.addWriteFiles().add(b.fmt("{s}.h", .{name}), source),
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
        .libc_file = if (sdk) |apple| apple.libc else null,
    });
    module.addImport(name, translated.mod);
    return translated;
}

fn configureWindowsHeaders(module: *std.Build.Module) void {
    const headers = translateHeaders(module, "win32-c",
        \\#define UNICODE 1
        \\#define _UNICODE 1
        \\#define _WIN32_WINNT 0x0A00
        \\#define WIN32_LEAN_AND_MEAN 1
        \\#define _FORTIFY_SOURCE 0
        \\#include <windows.h>
        \\#include <commctrl.h>
        \\#include <dwmapi.h>
        \\#include <shellapi.h>
        \\#include <wtsapi32.h>
        \\#include <bridge.h>
        \\#include <directwrite_renderer.h>
        \\#include <scroll_trace.h>
        \\
    );
    headers.addIncludePath(module.owner.path("winui"));
    headers.addIncludePath(module.owner.path("src/windows"));
}

fn configureLinuxHeaders(module: *std.Build.Module, ghostty: *std.Build.Dependency) void {
    const b = module.owner;
    const headers = Translator.init(b.dependency("translate_c", .{}), .{
        .name = "linux-images",
        .c_source_file = b.addWriteFiles().add("linux-images.h",
            \\#define GHOSTTY_STATIC 1
            \\#include <images.h>
            \\#include <ghostty/vt.h>
            \\#include <png.h>
            \\
        ),
        .target = module.resolved_target.?,
        .optimize = module.optimize.?,
        .link_system_libs = &.{
            .{ .name = "cairo", .options = .{ .use_pkg_config = .force } },
            .{ .name = "libpng", .options = .{ .use_pkg_config = .force } },
        },
    });
    module.addImport("linux-images", headers.mod);
    headers.addIncludePath(b.path("src/linux"));
    headers.addIncludePath(ghostty.path("include"));
}

fn configureMacosHeaders(module: *std.Build.Module) void {
    _ = translateHeaders(module, "macos-c",
        \\#include <errno.h>
        \\#include <fcntl.h>
        \\#include <poll.h>
        \\#include <signal.h>
        \\#include <sys/ioctl.h>
        \\#include <sys/wait.h>
        \\#include <time.h>
        \\#include <unistd.h>
        \\
    );
    const abi = translateHeaders(module, "public-abi", "#include <zigonaut_core.h>\n");
    abi.addIncludePath(module.owner.path("macos/include"));
}

fn configurePtyHeaders(module: *std.Build.Module) void {
    _ = translateHeaders(module, "pty-c",
        \\#include <errno.h>
        \\#include <fcntl.h>
        \\#include <poll.h>
        \\#include <pwd.h>
        \\#include <signal.h>
        \\#include <stdlib.h>
        \\#include <sys/ioctl.h>
        \\#include <sys/stat.h>
        \\#include <sys/wait.h>
        \\#include <termios.h>
        \\#include <unistd.h>
        \\
    );
}

const AppleSdk = struct {
    root: []const u8,
    libc: std.Build.LazyPath,
    framework: []const u8,
    system_include: []const u8,
    library: []const u8,
};

fn findAppleSdk(b: *std.Build, resolved_target: std.Build.ResolvedTarget) ?AppleSdk {
    if (comptime builtin.os.tag != .macos) return null;
    if (resolved_target.result.os.tag != .macos) return null;

    var target = resolved_target.result;
    const libc = std.zig.LibCInstallation.findNative(
        b.allocator,
        b.graph.io,
        .{
            .environ_map = &b.graph.environ_map,
            .target = &target,
            .verbose = false,
        },
    ) catch return null;

    var stream: std.Io.Writer.Allocating = .init(b.allocator);
    defer stream.deinit();
    libc.render(&stream.writer) catch @panic("unable to render the Apple SDK libc configuration");
    const libc_file = b.addWriteFiles().add("macos-libc.txt", stream.written());

    const sdk_usr = std.fs.path.dirname(libc.sys_include_dir.?) orelse
        @panic("Apple SDK system include directory has no parent");
    const sdk_root = std.fs.path.dirname(sdk_usr) orelse
        @panic("Apple SDK usr directory has no parent");

    return .{
        .root = sdk_root,
        .libc = libc_file,
        .framework = b.pathJoin(&.{ sdk_root, "System", "Library", "Frameworks" }),
        .system_include = libc.sys_include_dir.?,
        .library = b.pathJoin(&.{ sdk_usr, "lib" }),
    };
}

fn applyAppleSdk(step: *std.Build.Step.Compile, apple_sdk: ?AppleSdk) void {
    const sdk = apple_sdk orelse return;
    step.setLibCFile(sdk.libc);
    step.root_module.addCMacro("_LIBCPP_HAS_VENDOR_AVAILABILITY_ANNOTATIONS", "1");
    step.root_module.addSystemFrameworkPath(.{ .cwd_relative = sdk.framework });
    step.root_module.addSystemIncludePath(.{ .cwd_relative = sdk.system_include });
    step.root_module.addLibraryPath(.{ .cwd_relative = sdk.library });
}

fn generatedManifest(b: *std.Build, version: []const u8) std.Build.LazyPath {
    const source = b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        b.pathJoin(&.{ b.root.sub_path, "zigonaut.manifest" }),
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
