# Zigonaut

Zigonaut is an early-stage Windows terminal application built with Zig 0.15.2. The intended stack is:

- Win32 / WinUI 3 for the native application shell
- Windows ConPTY for PowerShell and WSL processes
- libghostty-vt for VT parsing and terminal/render state
- one isolated terminal surface per tab

## Current milestone

The repository contains a runnable native Win32 application shell and a tested tab/session model. Each PowerShell and WSL tab owns an isolated Windows ConPTY process and `libghostty-vt` terminal. A background reader feeds ConPTY output into Ghostty, and the UI paints synchronized, themed cell render-state snapshots rather than displaying unparsed process output. The built-in Rasmus theme supplies the default, cursor, and ANSI colors while preserving application-defined RGB colors. Windows Unicode text input is sent to ConPTY as UTF-8, while navigation keys use Ghostty's mode-aware key encoder. Window resizing measures the active monospace font and keeps every Ghostty grid and ConPTY session synchronized to the available viewport.

Terminal painting, focus, input, refresh, and grid sizing are isolated in a dedicated Win32 child-window class. The top-level window owns only application chrome and tab commands. An optional C++/WinRT bridge hosts genuine WinUI 3 controls in a `DesktopWindowXamlSource` above the terminal sibling. The bridge forwards commands to Zig and owns no session behavior. If its DLL is absent or initialization fails, the existing hand-painted Win32 chrome remains active.

The dependency is pinned to Ghostty commit `ae52f97dcac558735cfa916ea3965f247e5c6e9e`, matching the upstream Ghostling reference application and Zig 0.15.2. Full `libghostty` surfaces currently have no Win32 platform renderer, so Zigonaut uses the supported cross-platform VT library and owns its Windows rendering.

## Build

```powershell
zig build
zig build test
zig build run
```

The build uses the Windows subsystem and links only Windows SDK libraries available with Zig. No Visual Studio project generation is required for this milestone.

### Optional WinUI 3 chrome

Install the x64 Windows App Runtime 1.8 once on development and target machines:

```powershell
winget install -e --id Microsoft.WindowsAppRuntime.1.8
```

Then restore, build, and deploy the x64 bridge with VS 2022 and run the application:

```powershell
zig build winui
zig build run
```

The `winui` build step discovers MSBuild through Visual Studio Installer, builds the bridge, deploys its DLL, bootstrap DLL, and compiled XAML resource index, and verifies that the x64 runtime is installed. It fails clearly for non-x64 targets. The DLL disables automatic Windows App SDK bootstrap/deployment initialization, bootstraps the installed 1.8 runtime on the Zig STA UI thread, and must be called only from that owner thread. Zig loads it dynamically, so the normal `zig build` has no Visual Studio or Windows App SDK dependency.

## MVP path

1. Add full physical-key mapping, key releases, and IME composition support.
2. Complete Ghostty cell style rendering, then move text shaping from GDI to DirectWrite.
3. Add WinUI 3 packaging/chrome where it improves the native shell without coupling terminal state to XAML controls.
