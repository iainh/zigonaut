# Zigonaut

Zigonaut is an early-stage Windows terminal application built with Zig 0.15.2. The stack is:

- WinUI 3 for the native application shell
- Windows ConPTY for PowerShell and WSL processes
- libghostty-vt for VT parsing and terminal/render state
- one isolated terminal surface per tab

## Current milestone

The repository contains a runnable WinUI 3 application shell and a tested tab/session model. Each PowerShell and WSL tab owns an isolated Windows ConPTY process and `libghostty-vt` terminal. A background reader feeds ConPTY output into Ghostty, and the UI paints synchronized, themed cell render-state snapshots rather than displaying unparsed process output. The built-in Rasmus theme supplies the default, cursor, and ANSI colors while preserving application-defined RGB colors. Windows Unicode text input is sent to ConPTY as UTF-8, while navigation keys use Ghostty's mode-aware key encoder. Window resizing measures the active monospace font with DirectWrite and keeps every Ghostty grid and ConPTY session synchronized to the available viewport.

Terminal painting, focus, input, refresh, and grid sizing are isolated in a dedicated Win32 child-window class. A C++/WinRT bridge hosts the WinUI 3 shell in a `DesktopWindowXamlSource` above the terminal sibling. The bridge forwards commands to Zig and owns no session behavior. Zigonaut exits if the required WinUI shell cannot be initialized.

The terminal surface uses Direct2D and DirectWrite. Ghostty's physical narrow, wide, and spacer cells remain authoritative: compatible row spans are contextually shaped with system font fallback, then each DirectWrite glyph cluster is fitted back to its exact terminal-column span. The renderer supports bold, italic, faint, underline variants, strikethrough, overline, and layered COLR/CPAL color glyphs while preserving per-cell backgrounds and cursor geometry. GDI remains available as an initialization fallback.

The dependency is pinned to Ghostty commit `ae52f97dcac558735cfa916ea3965f247e5c6e9e`, matching the upstream Ghostling reference application and Zig 0.15.2. Full `libghostty` surfaces currently have no Win32 platform renderer, so Zigonaut uses the supported cross-platform VT library and owns its Windows rendering.

## Build

Install Visual Studio 2022 with **Desktop development with C++**, then install the Windows App Runtime 1.8 architecture matching your target (x64 or ARM64) once:

```powershell
winget install -e --id Microsoft.WindowsAppRuntime.1.8
```

```powershell
zig build
zig build test
zig build run
```

## Configuration

On first launch Zigonaut creates `%APPDATA%\spiralpoint\zigonaut\zigonaut.conf`:

```ini
font_family=Cascadia Mono
font_size=18
theme=rasmus
default_shell=powershell
randomize_tab_background=true
```

Supported themes are `rasmus`, `campbell`, and `solarized-dark`; `default_shell` may be
`powershell` or `wsl`. Use **Open Settings** and **Reload Settings** from the title-bar
menu to edit and apply changes without restarting Zigonaut. The configured shell is
used for the initial tab and for new tabs opened with Ctrl+Shift+T; the
PowerShell and WSL entries in the new-tab menu open their named profiles.
By default, each new tab receives a random background hue with the same perceived
darkness as the configured theme background. Set `randomize_tab_background=false`
to use the theme background unchanged for every tab.

The default build discovers MSBuild through Visual Studio Installer, builds the WinUI shell, and deploys its DLL, bootstrap DLL, and compiled XAML resource index beside the executable. It supports x64 and ARM64 Windows targets and verifies that the matching Windows App Runtime 1.8 architecture is installed. The DLL disables automatic Windows App SDK bootstrap/deployment initialization, bootstraps the installed 1.8 runtime on the Zig STA UI thread, and must be called only from that owner thread.

## Releases

Releases use semantic versions and are built from tags such as `v0.1.0`. Before tagging,
update both the `.version` field in `build.zig.zon` and the four-part version in
`zigonaut.manifest`. For example, version `0.2.0` uses manifest version `0.2.0.0`.

Push the tag after its commit has passed CI:

```powershell
git tag v0.2.0
git push origin v0.2.0
```

The release workflow tests, builds, packages, and launches the x64 and ARM64 archives on
clean native GitHub-hosted runners. It then creates a draft GitHub Release containing both
portable ZIPs and their SHA-256 checksum files. Download and smoke-test the draft artifacts
on representative Windows machines before publishing the release. The portable build
requires the matching Windows App Runtime 1.8 architecture to be installed.

The release workflow can also be run manually with a version to exercise the clean-runner
build and smoke tests without creating a tag or GitHub Release.

## MVP path

1. Add full physical-key mapping, key releases, and IME composition support.
2. Add terminal links and clipboard paste on top of the fixed-grid renderer.
3. Add WinUI 3 packaging without coupling terminal state to XAML controls.
