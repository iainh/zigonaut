# Zigonaut

Zigonaut is an early-stage Windows terminal application built with Zig 0.15.2. The intended stack is:

- Win32 / WinUI 3 for the native application shell
- Windows ConPTY for PowerShell and WSL processes
- libghostty for VT parsing, terminal state, and rendering support
- one isolated terminal surface per tab

## Current milestone

The repository currently contains a runnable native Win32 application shell and a tested tab/session model. PowerShell and WSL tabs can be created, selected, and closed. The terminal viewport is intentionally a placeholder until the ConPTY lifecycle and libghostty surface are connected; it does not claim to emulate a terminal by printing unparsed process output.

## Build

```powershell
zig build
zig build test
zig build run
```

The build uses the Windows subsystem and links only Windows SDK libraries available with Zig. No Visual Studio project generation is required for this milestone.

## MVP path

1. Own a ConPTY process and its input/output handles per session.
2. Feed ConPTY output into a libghostty surface and forward encoded keyboard input back to ConPTY.
3. Render and resize the active surface, preserving inactive tab state.
4. Add WinUI 3 packaging/chrome where it improves the native shell without coupling terminal state to XAML controls.
