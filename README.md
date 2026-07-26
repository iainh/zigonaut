# Zigonaut

Zigonaut is an early-stage Windows terminal application built with Zig 0.15.2. The stack is:

- WinUI 3 for the native application shell
- Windows ConPTY for PowerShell and WSL processes
- libghostty-vt for VT parsing and terminal/render state
- one isolated terminal surface per tab

## Current milestone

The repository contains a runnable WinUI 3 application shell and a tested tab/session model. Each PowerShell and WSL tab owns an isolated Windows ConPTY process and `libghostty-vt` terminal. A background reader feeds ConPTY output into Ghostty, and the UI paints synchronized, themed cell render-state snapshots rather than displaying unparsed process output. The built-in Rasmus theme supplies the default, cursor, and ANSI colors while preserving application-defined RGB colors. Windows Unicode text input is sent to ConPTY as UTF-8, while navigation keys use Ghostty's mode-aware key encoder. Window resizing measures the active monospace font with DirectWrite and keeps every Ghostty grid and ConPTY session synchronized to the available viewport.

The UI is a full, code-first `Microsoft.UI.Xaml.Window` owned by WinUI's application lifetime and dispatcher. Its C++/WinRT shell uses native Fluent controls for the custom title bar, tabs, menus, dialogs, and scrollback. The terminal is composed into the same visual tree with a `SwapChainPanel`; the bridge translates WinUI focus, keyboard, and pointer events into Zig's terminal input boundary while owning no session behavior.

The terminal surface uses a hardware-accelerated D3D11/DXGI composition swap chain with Direct2D and DirectWrite. Rendering is invalidation-driven and coalesced on the UI thread rather than continuously polling. Ghostty's physical narrow, wide, and spacer cells remain authoritative: compatible row spans are contextually shaped with system font fallback, then each DirectWrite glyph cluster is fitted back to its exact terminal-column span. The renderer supports bold, italic, faint, underline variants, strikethrough, overline, and layered COLR/CPAL color glyphs while preserving per-cell backgrounds and cursor geometry.

The dependency is pinned to Ghostty commit `ae52f97dcac558735cfa916ea3965f247e5c6e9e`, matching the upstream Ghostling reference application and Zig 0.15.2. Full `libghostty` surfaces currently have no Win32 platform renderer, so Zigonaut uses the supported cross-platform VT library and owns its Windows rendering.

## Build

Install Visual Studio 2022 with **Desktop development with C++**, then install Windows App Runtime 2.3.1 for your target architecture once. Replace `x64` with `arm64` when building for ARM64.

```powershell
$installer = "$env:TEMP\WindowsAppRuntimeInstall.exe"
Invoke-WebRequest https://aka.ms/windowsappsdk/2.3/2.3.1/windowsappruntimeinstall-x64.exe -OutFile $installer
& $installer
```

```powershell
zig build
zig build test
zig build run
zig build benchmark -Doptimize=ReleaseFast
```

The benchmark feeds a fixed colorized transcript into a 120×40 terminal and measures
VT ingestion and render-state traversal without relying on interactive timing.

## Configuration

On first launch Zigonaut creates `%APPDATA%\spiralpoint\zigonaut\zigonaut.conf`:

```ini
font_family=Cascadia Mono
font_size=18
dark_theme=rasmus
light_theme=campbell-light
color_scheme=system
padding_horizontal=8
padding_vertical=8
background_opacity=100
backdrop=mica
default_profile=PowerShell
profile.PowerShell=powershell|powershell.exe
profile.PowerShell 7=powershell|pwsh.exe
profile.Command Prompt=windows|cmd.exe
profile.WSL=wsl|wsl.exe
working_directory=
hold_on_exit=false
randomize_tab_background=true
```

Themes are loaded at startup from the `themes` directory beside `zigonaut.exe`. Each JSON
filename is its theme name; the bundled themes are `campbell`, `campbell-light`, and
`solarized-dark`. Rasmus is built in and is used whenever the configured theme cannot be found
or no JSON themes can be loaded. A theme JSON file contains `foreground`, `background`, and
`cursor` `#RRGGBB` strings plus an `ansi` array of exactly 16 colors.
`dark_theme` and `light_theme` follow the Windows application theme; high contrast always
uses Windows system colors and disables the configured `none`, `mica`, or `acrylic`
backdrop. Set `color_scheme` to `light` or `dark` to override the Windows application
theme for both the window and terminal, or leave it as `system` to follow Windows.
`background_opacity` is a percentage, and horizontal and vertical terminal
padding are configured independently. Override palette entries with `foreground`,
`background`, `cursor`, and `ansi0` through `ansi15`, using `#RRGGBB` values.
The legacy `theme` key remains an alias for `dark_theme`. Profiles are ordered `profile.<name>`
entries whose values contain a shell type and complete CreateProcess command line separated by
`|`. The supported shell types are `powershell`, `windows`, and `wsl`; they control how dropped
file paths are quoted. Add, remove, rename, or reorder profile entries to control the new-tab
menu, and set `default_profile` to the name used for the initial tab and Ctrl+Shift+T. If that
name does not exist, the first configured profile is used. Up to 32 profiles are supported.
`working_directory` sets the current directory for new processes;
leave it empty to inherit Zigonaut's directory. Set `hold_on_exit=true` to retain newly created
tabs after a clean process exit. Reloading these settings affects subsequent sessions only.
Use **Open Settings** and **Reload Settings** from the title-bar
menu to edit and apply changes without restarting Zigonaut. Reloading also rebuilds the new-tab
menu from the configured profiles.
By default, each new tab receives a random background hue with the same perceived
darkness as the configured theme background. Set `randomize_tab_background=false`
to use the theme background unchanged for every tab.

Use Ctrl+Plus or Ctrl+Minus to zoom the terminal font (main keyboard and numpad keys
are supported), and Ctrl+0 to restore the configured font size. Zoom is kept between
6 and 72 points and does not rewrite the configuration file.

## Terminal workflows

- `Ctrl+Shift+F` searches live scrollback; Enter/`Ctrl+N` and Shift+Enter/`Ctrl+P`
  move through matches.
- `Ctrl+Shift+Up` and `Ctrl+Shift+Down` move between OSC 133 shell prompts.
- `Ctrl+Shift+G` copies the most recent OSC 133 command output.
- OSC 9;4 progress from the active tab appears in the Windows taskbar, including
  paused, error, and indeterminate states; stale reports clear after 15 seconds.
- OSC 9 and OSC 777 desktop notifications use the emitting tab's title and return
  to that tab when activated during the same Zigonaut process.
- Hold Ctrl while hovering or clicking a terminal link to identify or open it.
- Drag to select and automatically copy; hold Alt for a rectangular selection.
  Double-click selects words and triple-click selects logical lines, and either may be
  extended by dragging. Selection drags autoscroll beyond the top or bottom edge.
- Programs that enable terminal mouse reporting receive clicks, motion, and wheel input.
  Hold Shift to override mouse reporting and select or scroll local scrollback instead;
  Ctrl+click links retains priority.
- `Ctrl+Shift+V` and Shift+Insert paste the clipboard. Dropped files are quoted for
  the active PowerShell, CMD, WSL, or custom profile.

The default build discovers MSBuild through Visual Studio Installer, builds the WinUI shell, and deploys its DLL, bootstrap DLL, and compiled XAML resource index beside the executable. It supports x64 and ARM64 Windows targets and verifies that the matching Windows App Runtime 2.3.1 architecture is installed. The DLL disables automatic Windows App SDK bootstrap/deployment initialization, bootstraps the installed runtime selected by Windows App SDK 2.3.1 on the Zig STA UI thread, and must be called only from that owner thread.

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
requires the matching Windows App Runtime 2.3.1 architecture to be installed.

The release workflow can also be run manually with a version to exercise the clean-runner
build and smoke tests without creating a tag or GitHub Release.

## MVP path

1. Add IME composition support.
2. Add terminal links and clipboard paste on top of the fixed-grid renderer.
3. Add WinUI 3 packaging without coupling terminal state to XAML controls.
