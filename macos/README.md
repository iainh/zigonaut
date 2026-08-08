# Zigonaut native macOS frontend

Build with `zig build macos-app`; the unsigned result is `zig-out/Zigonaut.app`. `zig build macos-run` builds and opens it. AppKit owns application lifecycle, Safari-style native window tabs, windows, menus, command routing and persistent `NSView` terminal surfaces. SwiftUI owns recursive split topology, find and settings. Keeping split presentation topology in Swift is an intentional interim boundary; the Zig core continues to own each terminal and PTY.

## Supported now

- Multiple windows, native title-bar tabs, and recursively resizable right/down splits, each with a stable terminal model and AppKit surface.
- New/close/select operations and pane focus cycling; focused panes have a native focus ring.
- Configurable executable absolute shell path for new panes (invalid values visibly fall back to `/bin/zsh`).
- Keyboard terminal input and IME marked-text composition with candidate windows positioned at the terminal cursor.
- Accurate font-derived grid resize, bounded styled-cell CoreText/AppKit rendering, per-cell colours and decoration, terminal cursors, and light/dark colours.
- Full scrollback find with match/active counts, native match highlights, wrapped previous/next navigation, viewport restoration, and Escape-to-close. Scanning runs on the serialized background queue and queries are limited to 256 UTF-8 bytes.
- OSC 133 prompt navigation and copy-or-pipe command output, with pipe commands started in the OSC 7-reported directory.
- Bounded Kitty graphics snapshots with RGBA image caching, source cropping and Retina-aware placement.
- Precise local scroll wheel movement and mouse cell selection; terminal mouse press, release, drag, and wheel reporting when requested by applications, with Shift forcing local selection.
- Basic bounded text-area accessibility value, label, focus state, and value-change notifications.
- Command-C copy and bracketed Command-V paste.
- Command-hover/click opens only terminal-detected links with schemes accepted by the terminal core.
- Desktop notifications are queued (32, 4096 combined UTF-8 bytes), delivered only while no terminal window is key, and use unique identifiers. Permission is requested once by macOS.
- A singleton native Settings window with bundled themes, full palette overrides, normal and intense font weights, scrollback limits, initial dimensions, grid alignment, independent padding, edge colours, shell selection, restore defaults, and guarded OSC 52 clipboard settings. Clipboard writes default off, are bounded and only accepted immediately when explicitly enabled; the terminal callback cannot defer a reply for later confirmation.
- Synchronized, bounded C ABI styled snapshots/copy and OSC terminal titles; nonblocking PTY writes on a serial background writer; callback teardown drains the reader before returning.
- A bundled high-resolution application icon, dynamic shell/OSC window-tab titles, standard macOS application menus, frame restoration, and reopen-after-last-window behaviour.

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

This is not feature parity. The isolated AppKit renderer remains replaceable by Metal. Missing features include geometric directional pane focus, rich accessibility ranges and editable text semantics, pane restoration, close confirmation, per-notification pane focus policy, advanced keyboard protocol handling, command validation refinements, and release signing and packaging.
