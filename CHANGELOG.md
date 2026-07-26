# Changelog

All notable changes to Zigonaut will be documented in this file.

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

[0.1.0]: https://github.com/iainh/zigonaut/releases/tag/v0.1.0
