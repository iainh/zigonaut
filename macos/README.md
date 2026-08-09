# Zigonaut native macOS frontend

Build with `zig build macos-app`; the unsigned result is `zig-out/Zigonaut.app`. `zig build macos-run` builds and opens it. AppKit owns application lifecycle, Safari-style native window tabs, windows, menus, command routing and persistent `NSView` terminal surfaces. SwiftUI owns recursive split topology, find and settings. Keeping split presentation topology in Swift is an intentional interim boundary; the Zig core continues to own each terminal and PTY.

## Supported now

- Multiple windows, native title-bar tabs, and recursively resizable right/down splits, each with a stable terminal model and AppKit surface.
- New/close/select operations and pane focus cycling.
- Configurable executable absolute shell path for new panes (invalid values visibly fall back to `/bin/zsh`).
- Keyboard terminal input and IME marked-text composition with candidate windows positioned at the terminal cursor.
- Accurate font-derived grid resize and retained Metal presentation. CoreText rasterizes only rows whose core-provided visual hashes changed, preserving native shaping, fallback, colour glyphs, per-cell colours, complete underline variants and terminal cursors; Metal retains and composites the result without an idle display loop.
- Full scrollback find with match/active counts, native match highlights, wrapped previous/next navigation, viewport restoration, and Escape-to-close. Scanning runs on the serialized background queue and queries are limited to 256 UTF-8 bytes.
- OSC 133 prompt navigation and copy-or-pipe command output, with pipe commands started in the OSC 7-reported directory.
- Bounded Kitty graphics snapshots with RGBA image caching, source cropping and Retina-aware placement.
- Precise local scrolling, copy-on-select cell/word/line selection, Option-drag rectangular selection, drag auto-scroll, shell-quoted Finder file drops, and a native terminal context menu. Terminal mouse press, release, drag, and wheel reporting remain available when requested by applications, with Shift forcing local selection.
- Basic bounded text-area accessibility value, label, focus state, and value-change notifications.
- Command-C copy and bracketed Command-V paste.
- Command-hover/click opens only terminal-detected links with schemes accepted by the terminal core.
- Desktop notifications are queued (32, 4096 combined UTF-8 bytes), delivered only while no terminal window is key, and use unique identifiers. Permission is requested once by macOS.
- OSC 9;4 progress from the focused terminal is shown with a native determinate or indeterminate Dock progress indicator, including paused and error states; stale reports expire after 15 seconds.
- A singleton native Settings window with a noncustomizable preference toolbar, restored pane selection, pane-specific sizing, aligned macOS forms, bundled themes, full palette overrides, normal and intense font weights, scrollback limits, initial dimensions, grid alignment, independent padding, edge colours, shell selection, restore defaults, and guarded OSC 52 clipboard settings. Clipboard writes default off, are bounded and only accepted immediately when explicitly enabled; the terminal callback cannot defer a reply for later confirmation.
- Synchronized, bounded C ABI styled snapshots/copy and OSC terminal titles; nonblocking PTY writes on a serial background writer; callback teardown drains the reader before returning.
- A bundled high-resolution application icon, dynamic foreground-process and OSC window-tab titles, standard macOS application menus, frame restoration, and reopen-after-last-window behaviour.

## Shortcuts

| Action | macOS shortcut | Windows-style discoverability |
|---|---|---|
| New tab / window | Command-T / Command-N | Menus expose both actions |
| Split right / down | Control-Shift-O / Control-Shift-E | Matches README |
| Close focused pane/tab | Command-W | Standard macOS convention (Windows uses Control-Shift-W) |
| Next / previous tab | Command-Shift-] / Command-Shift-[ | Standard tab convention |
| Focus right/down or left/up | Control-Option-Arrow | Matches README modifiers; currently presentation-order cycling |
| Find / copy / paste | Command-F / Command-C / Command-V | Standard macOS convention |
| Zoom in/out/reset | Command-Plus / Command-Minus / Command-0 | Standard macOS convention |
| Settings | Command-Comma | Standard macOS convention |

## Remaining parity gaps

This is not feature parity. Missing features include geometric directional pane focus, rich accessibility ranges and editable text semantics, pane restoration, close confirmation, per-notification pane focus policy, advanced keyboard protocol handling, command validation refinements, and release signing and packaging.
