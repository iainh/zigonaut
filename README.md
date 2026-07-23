# Zigonaut

Zigonaut is an early-stage Windows terminal application built with Zig 0.15.2. The intended stack is:

- Win32 / WinUI 3 for the native application shell
- Windows ConPTY for PowerShell and WSL processes
- libghostty-vt for VT parsing and terminal/render state
- one isolated terminal surface per tab

## Current milestone

The repository contains a runnable native Win32 application shell and a tested tab/session model. Each PowerShell and WSL tab owns an isolated `libghostty-vt` terminal. ANSI input is parsed by Ghostty and the viewport reads Ghostty's render-state cells rather than displaying unparsed process output.

The dependency is pinned to Ghostty commit `ae52f97dcac558735cfa916ea3965f247e5c6e9e`, matching the upstream Ghostling reference application and Zig 0.15.2. Full `libghostty` surfaces currently have no Win32 platform renderer, so Zigonaut uses the supported cross-platform VT library and owns its Windows rendering.

## Build

```powershell
zig build
zig build test
zig build run
```

The build uses the Windows subsystem and links only Windows SDK libraries available with Zig. No Visual Studio project generation is required for this milestone.

## MVP path

1. Own a ConPTY process and its input/output handles per session.
2. Feed ConPTY output into each libghostty-vt terminal and encode keyboard input back to ConPTY.
3. Render Ghostty cell colors and styles, then move text shaping from GDI to DirectWrite.
4. Add WinUI 3 packaging/chrome where it improves the native shell without coupling terminal state to XAML controls.
