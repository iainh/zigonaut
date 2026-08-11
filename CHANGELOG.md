# Changelog

All notable changes to Zigonaut will be documented in this file.

## [0.7.0] - 2026-08-11

### Added

- Drag-and-drop reordering for Windows tabs and panes, with Fluent visual feedback
  for available drop targets and the active destination.

### Changed

- Rendered box-drawing and block-element characters procedurally on Windows and
  macOS for consistent joins and cell coverage across fonts.
- Cached Windows pseudographic masks and reused row-ordering storage to reduce
  per-frame rendering work.

### Fixed

- Preserved macOS pseudographic masks across narrow and wide cell spans and
  corrected mask polarity so foreground strokes render instead of backgrounds.
- Encoded macOS arrow and function keys as terminal input instead of forwarding
  AppKit's private-use Unicode characters.

## [0.6.1] - 2026-08-10

### Fixed

- Suspended Windows rendering while panes, windows, displays, or desktop sessions
  are unavailable, preventing sustained CPU use after RDP disconnects and display
  sleep without reintroducing recurring compositor wakeups.
- Restored terminal keyboard focus and immediate rendering after tab switches, so
  returning to an older tab reliably displays and accepts input.

## [0.6.0] - 2026-08-10

### Added

- A native macOS terminal client with tabs, split panes, native settings, rich
  selection, Kitty graphics, OSC 133 workflows, directional pane focus, workspace
  restoration, notifications, Dock progress, and expanded accessibility.
- macOS validation and release packaging alongside the existing Windows builds.
- Production-paced DirectComposition benchmarks for comparing Windows glyph
  submission backends under real frame presentation.

### Changed

- Separated the shared terminal kernel from the Windows and macOS hosts and added
  platform-specific build and test boundaries.
- Added retained Metal rendering, changed-row updates, row-local render reuse, and
  cached Kitty image payloads to reduce macOS rendering work.
- Reused Windows glyph submission scratch storage, reducing paced D3D11 instancing
  below one millisecond in the benchmark workload.
- Updated libghostty and made the supported Zig version an explicit build
  requirement.
- Consolidated CI validation, pinned external actions, and cancelled superseded
  workflow runs.

### Fixed

- Prevented unattended Windows rendering hangs by bounding presentation retries,
  recovering dropped frame-wait completions, and backing off stalled teardown.
- Made Windows session shutdown more robust after PTY failures and partial pane
  detach, while bounding clipboard, command-worker, scrollback, and search-cache
  resource use.
- Corrected macOS title-bar appearance, natural scrolling, resize anchoring,
  box-drawing joins, shell startup directories, and theme tint lightness.

## [0.5.0] - 2026-08-05

### Added

- Configurable horizontal and vertical terminal padding.
- End-to-end ConPTY throughput and native DirectWrite rendering benchmarks.

### Changed

- Moved glyph rendering to a GPU-instanced atlas and retained terminal scene,
  substantially reducing CPU submission work during drawing and scrolling.
- Pipelined terminal snapshot preparation with frame presentation to reduce UI-thread
  rendering work and improve responsiveness under sustained output.
- Made ConPTY reads and writes ordered, cancellable, and bounded during shutdown.
- Improved the terminal find experience and adopted Ghostty's semantic terminal
  effects.

### Fixed

- Synchronized rendering during terminal resize and retried transient layout failures.
- Prevented stale frames from starving newer renders.
- Corrected enhanced-keyboard punctuation and AltGr key-release handling.
- Prevented settings text mojibake and dark-theme startup flicker.
- Ensured closing the final window terminates the application completely.

## [0.4.1] - 2026-08-01

### Changed

- Improved terminal throughput and responsiveness by batching PTY output, pacing
  rendering with the compositor, and yielding parsing to waiting renders.
- Reduced rendering overhead with row-batched DirectWrite drawing, reused glyph-run
  buffers, and cached Kitty image bitmaps.
- Updated the libghostty dependency.

### Fixed

- Corrected initial tab rendering.

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

[0.7.0]: https://github.com/iainh/zigonaut/releases/tag/v0.7.0
[0.6.1]: https://github.com/iainh/zigonaut/releases/tag/v0.6.1
[0.6.0]: https://github.com/iainh/zigonaut/releases/tag/v0.6.0
[0.5.0]: https://github.com/iainh/zigonaut/releases/tag/v0.5.0
[0.4.1]: https://github.com/iainh/zigonaut/releases/tag/v0.4.1
[0.4.0]: https://github.com/iainh/zigonaut/releases/tag/v0.4.0
[0.3.0]: https://github.com/iainh/zigonaut/releases/tag/v0.3.0
[0.1.0]: https://github.com/iainh/zigonaut/releases/tag/v0.1.0
