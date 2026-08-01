# Changelog

All notable changes to Zigonaut will be documented in this file.

## [0.4.0] - 2026-08-01

### Added

- Native Fluent settings for appearance, terminal behavior, profiles, advanced
  options, and application information, with live previews and updates.
- Configurable initial terminal dimensions, scrollback length, per-profile working
  directories, and normal and intense font weights.
- Windows Terminal-compatible `new-tab` and `split-pane` startup actions, including
  profile, working-directory, split-direction, and chained-action options.
- Explorer integration for opening folders in Zigonaut and a shortcut to Windows'
  default-terminal settings.
- Bundled Fluent Dark and Fluent Light themes, plus theme and palette selectors.
- A native terminal context menu and WinUI find control.
- Windows UI Automation access to terminal text, selections, ranges, and scrolling.
- Inactive-tab activity indicators, tab reordering, middle-click close, tab
  duplication, bulk close commands, and numbered tab shortcuts.
- Safe restoration of window position, size, and maximized state.
- Per-user MSI installers for x64 and ARM64 releases, alongside portable archives.

### Changed

- Replaced the line-oriented `%APPDATA%\spiralpoint\zigonaut\zigonaut.conf` with a
  versioned JSON configuration at
  `%APPDATA%\spiralpoint\zigonaut\zigonaut.json`. The old file is not imported;
  existing users must recreate their settings in the new settings window or JSON
  file.
- Configuration validation now rejects invalid versions, ranges, profile names,
  profile commands, default-profile references, colors, and Windows strings.
- New configurations prefer PowerShell 7 when available. Failed profile launches
  now offer profile settings or fall back to a configured Command Prompt profile.
- Random tab colors now appear in tab headers, remain distinct across open tabs,
  and produce suitable tints for both light and dark themes.
- Closing a window now asks for confirmation only when it contains multiple tabs.
- Updated the title bar, tabs, menus, terminal controls, settings, and About
  experience to follow Fluent 2 conventions.
- Updated source builds to Zig 0.16.0, added Visual Studio 2026 toolset support,
  and use the installed Windows SDK instead of a pinned SDK version.
- Portable packages now include only the OpenConsole components matching their
  target architecture.

### Fixed

- Live theme changes now refresh existing terminal cells and changed theme files.
- Randomized session backgrounds remain stable across settings and theme reloads,
  and render correctly with light themes.
- Terminal resize notifications are processed more responsively.
- Resource discovery now supports long executable and installation paths.
- Profile editing handles WinUI line endings correctly.
- Corrected new-tab button sizing and kept tab interactions working while dragging
  the window or reordering tabs.
- Corrected application icon spacing across Windows icon sizes.

## [0.3.0] - 2026-07-28

### Added

- Direct Kitty graphics protocol rendering for inline PNG images.
- Native IME composition and forwarding of terminal-generated responses to ConPTY.
- Synchronized terminal output and guarded terminal clipboard writes.
- Live terminal working-directory tracking and configurable actions that receive
  command output.

### Changed

- Split panes now preserve model-owned ratios while snapping dividers and minimum
  sizes to terminal cells.
- New terminals open in the user's home directory, and the viewport returns to the
  current input when appropriate.
- Reduced rendering, layout, search, notification, launch-metadata, and snapshot
  overhead through reuse, coalescing, compact storage, and fewer intermediate copies.

### Fixed

- Bundled the matching side-by-side ConPTY components to prevent resize corruption.
- Corrected styled soft-wrap rendering and stale incremental snapshots during reflow.
- Fixed terminal rendering, WinUI bridge builds, and ARM64 C-import collisions.

## [0.1.0] - 2026-07-25

### Added

- Native WinUI 3 terminal shell for Windows on x64 and ARM64.
- Native split terminal panes with directional keyboard focus, pane close, and
  mouse-resizable dividers.
- Configuration-defined ConPTY profiles with user-selected names, commands, ordering,
  shell quoting behavior, and default profile.
- Tabbed terminal sessions with shell-provided titles, keyboard shortcuts, a
  new-tab profile menu, and automatic cleanup when shells exit.
- Direct2D and DirectWrite rendering with Unicode shaping, system font fallback,
  terminal text styles, color glyphs, and fixed-grid cursor geometry.
- Configurable fonts, themes, palettes, padding, opacity, backdrop, working
  directory, default shell, and per-tab background randomization.
- Selection and copy-on-select, bracketed paste, shell-aware file drops,
  clickable links, live scrollback search, and an overlay scrollbar.
- OSC 133 command navigation and output copying, OSC 9/777 desktop
  notifications, and OSC 9;4 taskbar progress reporting.
- Mouse reporting, physical key handling, mode-aware key encoding, font zoom,
  per-monitor DPI awareness, system text rendering settings, and high-contrast
  support.

### Performance and reliability

- Event-driven refreshes, rendering outside the terminal state lock, reused
  DirectWrite row work, bounded output lock latency, and accelerated scrollback
  search.
- Automated tests, a terminal performance benchmark, and Windows x64 and ARM64
  CI and release packaging.

[0.4.0]: https://github.com/iainh/zigonaut/releases/tag/v0.4.0
[0.3.0]: https://github.com/iainh/zigonaut/releases/tag/v0.3.0
[0.1.0]: https://github.com/iainh/zigonaut/releases/tag/v0.1.0
