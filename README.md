<div align="center">
  <h1><img src="assets/icons/windows/zigonaut-256.png" width="144" alt="Zigonaut icon" align="center"> Zigonaut</h1>
  <p><strong>A native terminal for Windows, macOS, and Linux, built with Zig.</strong></p>
  <p>
    <a href="https://github.com/iainh/zigonaut/releases">Releases</a>
    ·
    <a href="CHANGELOG.md">Changelog</a>
  </p>
</div>

Zigonaut combines a native Windows interface with a hardware-accelerated terminal renderer. It runs PowerShell, Command Prompt, WSL, and custom commands through Windows ConPTY, while [Ghostty's](https://github.com/ghostty-org/ghostty) VT library provides terminal parsing and state.

The application is written primarily in Zig, with native WinUI 3, macOS, and GTK 4 frontends sharing the same terminal engine. Windows supports x64 and ARM64. The initial Linux frontend is described under [Linux (GTK 4)](#linux-gtk-4); the feature lists below describe the Windows frontend unless noted otherwise.

## Major features

### Terminals and navigation

- Multiple tabs and independently running split panes
- Horizontal and vertical splits with draggable, cell-snapped dividers
- Directional keyboard navigation between panes
- Configurable profiles for PowerShell, Command Prompt, WSL, and custom commands
- Automatic prompt and working-directory integration for directly launched Windows PowerShell 5.1 and PowerShell 7
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
- Configurable fonts, line height, centered grid padding, edge-color extension, opacity, palettes, and working directory
- Bundled Campbell, Campbell Light, Fluent Light, Fluent Dark, Ottosson Light, Ottosson Dark, Solarized Dark, and Rasmus themes
- Full-window Fluent settings page with automatic saving

Line height is adjustable from 75% to 200% under Appearance. The default, 100%,
uses the font’s natural spacing; glyph size stays unchanged. Tight spacing can
clip tall glyphs. Windows stores this as `appearance.font.lineHeightPercent`.

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

Automatic shell integration is enabled by default and can be disabled under Advanced. It applies only to new terminals. Zigonaut injects its bundled script only when a PowerShell profile directly launches `powershell.exe` or `pwsh.exe` with no arguments or with supported startup flags (`-NoLogo`, `-NoProfile`, and PowerShell 7's `-Login`). Commands that run scripts or inline code, Command Prompt, WSL, custom commands, and nested shells are unchanged. Zigonaut never edits PowerShell profiles or bypasses execution policy.

Long-command completion notifications are disabled by default. Enable them under
Advanced on Windows (`terminal.commandCompletionNotifications` in JSON) or
Terminal → Shell on macOS. A shell reporting OSC 133 command boundaries can then
notify you when a command takes at least five seconds and its pane is unfocused
at completion. Alternate-screen changes do not stop the timer. Alerts include
the exit status when available; clicking one activates its live pane. macOS also
suppresses notifications while any terminal window is key. Existing OS
notification permissions still apply. Explicit OSC 9/777 notifications remain
independent; sending one during a command suppresses its automatic completion
alert. Enabling or disabling this setting discards any command already running.

## Keyboard shortcuts

See [Windows keyboard shortcuts](docs/keyboard-shortcuts-windows.md) for the complete Windows reference, including tab selection, clipboard alternatives, and search controls.

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

### macOS

Use Zig 0.17.0 and Xcode 27 or later with the macOS 27 SDK. The application
still supports macOS 15 and later; the newer SDK enables the current native
window controls on macOS 27.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer zig build macos-app -Doptimize=ReleaseSafe
```

The Swift frontend and Zig core use the selected Apple SDK. Bundle assembly
rejects a frontend linked against an SDK older than 27.

### Linux (GTK 4)

The Linux dependency baseline is Debian 13 (trixie): Zig 0.17.0, GTK 4.18+,
libadwaita 1.7+, GLib 2.84+ and libpng 1.6.48+ development libraries,
`pkg-config`, and a Linux desktop session. Other distributions need equivalent
or newer libraries; Debian 12 and Ubuntu 24.04's stock libraries are too old.
GTK chooses Wayland or X11 through its normal backend selection. Automated UI
checks run on Debian 13 with X11.

On Debian 13:

```sh
sudo apt-get install libgtk-4-dev libadwaita-1-dev libpng-dev pkg-config
zig build
zig build run
```

The default Linux build installs `zig-out/bin/zigonaut`, a desktop entry under
`zig-out/share/applications`, an application icon, and shell resources under
`zig-out/share/zigonaut/shell-integration`. Keep the `bin` and `share` layout
together when relocating an installation. For a user-local desktop
installation, run `zig build --prefix "$HOME/.local"` and ensure `~/.local/bin`
is on your desktop session's `PATH`. No Windows or Apple SDK is needed.

The GTK/libadwaita frontend puts reorderable, detachable tabs directly in the
header bar alongside native window controls. It follows the desktop's light/dark
appearance for window chrome, uses Adwaita toasts for failed actions, and includes
native About and Settings dialogs in the main menu.
It provides an independent POSIX PTY per pane, Pango/Cairo text rendering with font fallback,
true colour, text styles, wide characters, scrollback, drag selection, rectangular selection
with `Alt`, clipboard copy/paste, input-method commits, terminal-provided tab
titles, scrollback search, shell-prompt navigation, and font zoom. The initial
Default profile starts `$SHELL` interactively, falling back to `/bin/sh` when it
is unset, relative or not executable, and inherits the launcher's working directory.
Shell exit leaves its final output visible until you close the pane.

Open **Settings** (`Ctrl+,`) to edit font family/size, line height, padding,
colour scheme, light/dark terminal themes (Rasmus or Fluent), intense text,
scrollback, initial window grid, and bounded terminal clipboard writes. Valid edits
save automatically and update every open terminal without restarting shells.
Initial grid dimensions affect new windows; zoom is temporary and `Ctrl+0`
restores the saved font size. System colour scheme follows desktop appearance changes.

The **Profiles** page supports up to 32 named profiles, with add, rename, remove
and default selection. Each profile has an absolute executable shell path, an
optional command and an optional absolute working directory. An empty command
starts `shell -i`; otherwise Zigonaut runs `shell -c command`, so the command may
use that shell's syntax. An empty directory inherits the launcher directory.
Startup and `Ctrl+Shift+T` use the default profile. **New Tab with Profile** in
the main menu launches a selected profile. Edits affect only future sessions.
Names must be unique ignoring case; the last profile cannot be removed.

Linux settings use a versioned GLib key file at
`$XDG_CONFIG_HOME/zigonaut/settings.ini` (normally
`~/.config/zigonaut/settings.ini`). The file is created on the first valid edit,
using an atomic, durable replacement with mode `0600`; new configuration
directories use `0700`. There is no Apply button. Invalid or incomplete edits show an inline
error and leave the last valid settings active and saved until corrected.
Closing Settings retains valid changes and discards invalid edits.
Invalid files at startup produce a warning and defaults without overwriting the
file. Edit files only while Zigonaut is closed: settings
are loaded at startup, not watched, and concurrent instances use last-save-wins.
Windows JSON and macOS preferences are separate and are not imported.

Split the focused pane right with the header's split button, or right/down from
the main menu's **Panes** submenu. Tabs support up to 64 panes, including nested splits. Drag native
GTK dividers to resize panes; dragging snaps to the
focused terminal's cell size. Click a terminal or use directional/cyclic focus
shortcuts to choose a pane. An accent border marks the focused pane, whose shell
title also becomes the tab title. Resize shortcuts move the nearest divider on
that axis by 5%; equalize distributes space among same-axis panes. Pane zoom
shows only the focused pane without closing or stopping its siblings, follows
focus changes and restores the layout when toggled off. Splitting or resizing
exits zoom. Closing a pane collapses its split and focuses the preceding pane
(or the following pane if there is no preceding one); closing the last pane
closes the tab/window. The tab's close button and **Close Tab** menu action close
all its panes. Splits inherit the tab's launch profile and the focused pane's
font size. Profile edits affect new tabs, not existing tabs or their future
splits. An empty profile directory inherits the launcher's directory, not a
running sibling's current directory. Desktop-global shortcuts can reserve
pane key combinations; use the pane menu actions or adjust desktop bindings.

The main menu's **Move Tab to New Window** preserves every running shell, split
ratio, focused/zoomed pane and open search in the tab.

Find keeps a separate query per pane and highlights matches across scrollback,
including soft-wrapped lines. Lowercase ASCII queries ignore ASCII case; an
uppercase ASCII letter makes the query case-sensitive. Queries support UTF-8,
up to 256 bytes. Closing Find restores the previous scroll position and keyboard
focus.

Terminal applications can request mouse buttons, motion and both wheel axes,
including SGR pixel coordinates. Hold `Shift` to select text or scroll history
instead of sending mouse events. `Alt` selects a rectangle. Presses stay with
their original pane and are released when focus or layout visibility changes.
Hold `Ctrl` over an allowed OSC 8 or detected URI to underline it and show its
target; `Ctrl`-click opens it through the desktop's native URI handler. `Shift`
also overrides link activation. Links use the shared supported-scheme policy.

Zigonaut automatically loads its bundled integration for Bash 4.4+, Zsh and
fish 2.7+. It emits prompt/command boundaries (OSC 133) and working-directory
updates (OSC 7), enabling prompt navigation without manual shell configuration.
Shells remain interactive and non-login, inherit the launcher's environment and
working directory, and read their normal startup configuration. Bash loads
`~/.bashrc` before installing hooks, Zsh preserves `ZDOTDIR`, and fish loads its
configuration before integration. Startup files are never edited. Other shell
names, or installations missing the required scripts, launch without injection;
prompt navigation then depends on markers supplied by the shell itself.
Set `ZIGONAUT_SHELL_INTEGRATION=0` in Zigonaut's launch environment to skip
injection (any existing value suppresses setup, matching the bundled integrations).
Nested shells are not automatically injected.

**Copy Last Command Output** (`Ctrl+Shift+G`) copies plain UTF-8 output from the
focused pane's latest OSC 133 command, without the prompt, command line or text
styles. It leaves the clipboard unchanged when no output is available. This
explicit copy works regardless of the terminal clipboard-write permission.
**New Window** (`Ctrl+Shift+N`) starts an independent default-profile session.

| Linux shortcut | Action |
| --- | --- |
| `Ctrl+Shift+T` | Open a tab |
| `Ctrl+Shift+N` | Open a new window with the default profile |
| `Ctrl+Shift+O` / `Ctrl+Shift+E` | Split focused pane right / down |
| `Ctrl+Shift+W` | Close focused pane (last pane closes the tab) |
| `Ctrl+Alt+Arrow` | Focus a pane in that direction |
| `Ctrl+Alt+Page Up` / `Ctrl+Alt+Page Down` | Focus previous / next pane, wrapping |
| `Ctrl+Alt+Shift+Arrow` | Move nearest divider by 5% |
| `Ctrl+Alt+=` | Equalize pane sizes |
| `Ctrl+Shift+Enter` | Toggle focused-pane zoom |
| `Ctrl+Page Up` / `Ctrl+Page Down` | Switch tabs |
| `Ctrl+Shift+Page Up` / `Ctrl+Shift+Page Down` | Reorder the current tab |
| `F10` | Open the main menu |
| `Ctrl+,` | Open Settings |
| `Ctrl+Shift+C` | Copy selected text |
| `Ctrl+Shift+V` / `Shift+Insert` | Paste using the terminal's bracketed-paste mode |
| `Shift+Page Up` / `Shift+Page Down` | Scroll history |
| `Ctrl+Shift+F` | Find in scrollback |
| `Enter` / `Shift+Enter` in Find | Next / previous match, wrapping at either end |
| `Escape` in Find | Close Find and return to the terminal |
| `Ctrl+Shift+Up` / `Ctrl+Shift+Down` | Move to the previous / next shell prompt |
| `Ctrl+Shift+G` | Copy the latest command output from the focused pane |
| `Ctrl+Plus` / `Ctrl+Minus` / `Ctrl+0` | Increase / decrease / reset font size |

This is an initial frontend, not feature parity with Windows or macOS. It does
not yet include a screen-reader text interface.
Settings cover the supported Linux subset, not Windows backdrop materials,
palette overrides, notifications or output piping.
Kitty images use the shared supported subset: in-memory RGBA and PNG transport,
source crops, scaling and Unicode placeholders. Images composite above text and
below the cursor, clipped to each pane's terminal grid; raw RGB-format images
and negative-z placements remain unsupported. Converted Cairo surfaces use a
per-pane cache bounded to eight images and 32 MiB. Shared image transport and
resource limits still apply.
The app keeps GTK's default renderer selection. The image pixel suite defaults
to Cairo for deterministic headless checks.
OSC clipboard writes are disabled by default; enabling them allows terminal
programs to replace your clipboard up to the configured byte limit. Clipboard
reads are not exposed to terminal programs. Explicit copy shortcuts work
regardless of that setting.

```sh
zig build ci
# Real PTY checks for all supported shells (no display needed):
sudo apt-get install bash zsh fish
zig build test-linux-shell-integration
# Real GTK/PTY integration checks, without needing a desktop:
sudo apt-get install xvfb xdotool xclip
xvfb-run -a zig build test-linux-ui
# Native 2x Kitty pixels, alpha, crop, replacement and split/zoom/transfer:
sudo apt-get install python3-pil
xvfb-run -a -s '-screen 0 2200x1500x24' zig build test-linux-images-ui
# Native preferences, persistence, and real profile-launch checks:
sudo apt-get install python3-pyatspi dbus-x11
xvfb-run -a zig build test-linux-settings-ui
# Native mouse protocols, link dispatch, selection and pane routing:
sudo apt-get install imagemagick
xvfb-run -a -s '-screen 0 2400x1800x24' env GDK_SCALE=2 zig build test-linux-pointer-ui
```

Linux sources live in `src/linux`: a small Zig bridge owns the shared terminal
engine and pane tree (also used by Windows), while the C GTK host owns native
split widgets, windows, input, clipboard, rendering and per-pane PTYs.
PTY I/O is nonblocking and event-driven on the GTK main loop. Shells start via
`posix_spawn` and a fresh child process, so no GTK code runs after `fork`.

### Requirements

- Windows 10 version 1809 or later, or Windows 11
- [Zig 0.17.0](https://ziglang.org/download/)
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
