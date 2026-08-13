<div align="center">
  <h1><img src="assets/icons/windows/zigonaut-256.png" width="144" alt="Zigonaut icon" align="center"> Zigonaut</h1>
  <p><strong>A fast, native terminal for Windows, built with Zig and WinUI 3.</strong></p>
  <p>
    <a href="https://github.com/iainh/zigonaut/releases">Releases</a>
    ·
    <a href="CHANGELOG.md">Changelog</a>
  </p>
</div>

Zigonaut combines a native Windows interface with a hardware-accelerated terminal renderer. It runs PowerShell, Command Prompt, WSL, and custom commands through Windows ConPTY, while [Ghostty's](https://github.com/ghostty-org/ghostty) VT library provides terminal parsing and state.

The application is written primarily in Zig, with a code-first C++/WinRT bridge for WinUI 3. It supports Windows on x64 and ARM64.

## Major features

### Terminals and navigation

- Multiple tabs and independently running split panes
- Horizontal and vertical splits with draggable, cell-snapped dividers
- Directional keyboard navigation between panes
- Configurable profiles for PowerShell, Command Prompt, WSL, and custom commands
- Shell-provided tab titles and OSC 7 working-directory tracking
- Live scrollback search and OSC 133 prompt navigation

### Rendering and input

- GPU-accelerated D3D11, Direct2D, and DirectWrite rendering
- Unicode shaping, system font fallback, color glyphs, and terminal text styles
- Kitty graphics protocol support for in-memory PNG images, with generation-keyed native image caching
- Native IME composition and per-monitor DPI awareness
- Mouse reporting, mode-aware keyboard input, and configurable font zoom
- High-contrast support and a GDI fallback renderer

### Desktop integration

- Native WinUI 3 title bar, tabs, menus, dialogs, and settings
- Windows taskbar progress from OSC 9;4
- Desktop notifications from OSC 9 and OSC 777
- Clickable terminal links
- Copy-on-select, bracketed paste, and shell-aware file drops
- Optional, size-limited terminal clipboard writes through OSC 52 and OSC 1337 Copy
- Configurable command piping for the latest OSC 133 command output

### Appearance and configuration

- Light, dark, and system color modes
- Mica, acrylic, or opaque window backdrops
- Configurable fonts, centered grid padding, edge-color extension, opacity, palettes, and working directory
- Bundled Campbell, Campbell Light, Fluent Light, Fluent Dark, Solarized Dark, and Rasmus themes
- Full-window Fluent settings page with automatic saving

### Windows integration

The Profiles settings page can add or remove **Open in Zigonaut** for Explorer folders and folder backgrounds, and links to Windows' default-terminal selector. Explorer registration is per-user and follows the current `zigonaut.exe` location.

Zigonaut accepts Windows Terminal-style startup actions:

```text
zigonaut.exe [new-tab|nt] [-p|--profile NAME] [-d|--startingDirectory DIRECTORY]
             [; split-pane|sp [-H|--horizontal|-V|--vertical]
                [-p|--profile NAME] [-d|--startingDirectory DIRECTORY]] ...
```

`--working-directory` remains an alias for `--startingDirectory`. Quote the `;` argument when invoking Zigonaut from PowerShell.

Zigonaut creates its configuration file on first launch at:

```text
%APPDATA%\spiralpoint\zigonaut\zigonaut.json
```

The versioned JSON document is managed by the settings window and uses ordered profile objects so profile definitions can grow without introducing another line-based mini-language.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Ctrl+Shift+T` | Open a tab with the default profile |
| `Ctrl+Shift+N` | Open a new Zigonaut window |
| `Ctrl+Shift+O` | Split the focused pane to the right |
| `Ctrl+Shift+E` | Split the focused pane downward |
| `Ctrl+Alt+Arrow` | Move focus between panes |
| `Ctrl+Alt+Page Up` / `Ctrl+Alt+Page Down` | Cycle focus through panes |
| `Ctrl+Alt+Shift+Arrow` | Resize the nearest pane divider by 5% |
| `Ctrl+Alt+=` | Equalize pane sizes |
| `Ctrl+Shift+Enter` | Toggle focused-pane zoom |
| `Ctrl+Shift+W` | Close the focused pane, tab, or window |
| `Ctrl+Shift+F` | Search scrollback |
| `Ctrl+Shift+Up` / `Ctrl+Shift+Down` | Move between shell prompts |
| `Ctrl+Shift+G` | Copy or pipe the latest command output |
| `Ctrl+Shift+V` / `Shift+Insert` | Paste from the clipboard |
| `Ctrl+Plus` / `Ctrl+Minus` / `Ctrl+0` | Increase, decrease, or reset font size |

Drag to select and copy text automatically. Hold `Alt` for rectangular selection, `Shift` to override terminal mouse reporting, or `Ctrl` while hovering and clicking to identify and open links.

## Compiling

### Requirements

- Windows 10 version 1809 or later, or Windows 11
- [Zig 0.16.0](https://ziglang.org/download/)
- Visual Studio 2022 with the **Desktop development with C++** workload
- Windows App Runtime 2.3.1 for the target architecture

Install the x64 Windows App Runtime from PowerShell:

```powershell
$installer = "$env:TEMP\WindowsAppRuntimeInstall.exe"
Invoke-WebRequest `
  https://aka.ms/windowsappsdk/2.3/2.3.1/windowsappruntimeinstall-x64.exe `
  -OutFile $installer
& $installer
```

For an ARM64 build, replace `x64` in the installer URL with `arm64`.

### Build and run

Clone the repository and run the default build from a PowerShell prompt:

```powershell
git clone https://github.com/iainh/zigonaut.git
Set-Location zigonaut
zig build
zig build run
```

The build automatically locates MSBuild through Visual Studio Installer, restores the WinUI dependencies, compiles the Zig executable and C++/WinRT shell, and deploys the complete application to `zig-out\bin`.

The default command builds for the host architecture. Explicit target commands are:

```powershell
# x64
zig build -Dtarget=x86_64-windows

# ARM64
zig build -Dtarget=aarch64-windows
```

Create an optimized build with:

```powershell
zig build -Doptimize=ReleaseSafe
```

### Tests and benchmark

```powershell
# Run the unit tests
zig build test

# Verify ConPTY resize behavior (requires the complete WinUI build)
zig build test-conpty

# Measure VT ingestion and render-state traversal
zig build benchmark -Doptimize=ReleaseFast
```

The benchmark uses a fixed colorized transcript in a 120-by-40 terminal so results do not depend on interactive timing.

Interactive scroll stalls can be captured with the dormant ETW instrumentation described in [the scroll tracing guide](docs/performance/scroll-tracing.md).

## Architecture

```text
WinUI 3 application shell
        │
        ├── C++/WinRT input and composition bridge
        │           │
        │           └── D3D11 + Direct2D + DirectWrite renderer
        │
        └── Zig application and session model
                    │
                    ├── Ghostty VT parser and terminal state
                    └── Windows ConPTY ── PowerShell / CMD / WSL
```

Each pane owns an isolated ConPTY process and terminal state. Background readers feed process output into the VT parser, while invalidation-driven snapshots are rendered on the WinUI thread. Rendering is coalesced rather than continuously polled.

## Releases

Windows x64 and ARM64 packages and a macOS ARM64 application archive are available from [GitHub Releases](https://github.com/iainh/zigonaut/releases). The matching Windows App Runtime 2.3.1 architecture must be installed before running a Windows release build. The macOS archive is currently ad-hoc signed rather than Developer ID signed and notarized.

## License

Zigonaut is available under the [MIT License](LICENSE). Third-party license notices are in the [licenses](licenses) directory.
