# Zigonaut native macOS frontend

Build with `zig build macos-app`; the unsigned result is `zig-out/Zigonaut.app`. `zig build macos-run` builds and opens it. AppKit owns application lifecycle, Safari-style native window tabs, windows, menus, command routing and persistent `NSView` terminal surfaces. SwiftUI owns recursive split topology, find and settings. Keeping split presentation topology in Swift is an intentional interim boundary; the Zig core continues to own each terminal and PTY.

## Supported now

- Multiple windows, native title-bar tabs with inactive-output indicators, and recursively resizable right/down splits, each with a stable terminal model and AppKit surface.
- New/close/select operations and geometric directional pane focus.
- Configurable executable absolute shell path for new panes (invalid values visibly fall back to `/bin/zsh`).
- Physical press/repeat/release input through the core terminal key encoder, including enhanced keyboard protocols, Apple ANSI/ISO/JIS keys, navigation, keypad, modifiers, and F1–F20. AppKit still owns menu equivalents, IME/dead-key composition, and committed text, with candidate windows positioned at the terminal cursor.
- Accurate font-derived grid resize and retained Metal presentation. CoreText shapes text into a bounded GPU-resident glyph texture cache, preserving fallback, colour glyphs and per-cell styles; the CPU redraws only changed backgrounds and procedural pseudographics. Metal composites text, complete underline variants, images, IME and terminal cursors in order, and blits retained rows during viewport scrolling without an idle display loop.
- Full scrollback find with match/active counts, native match highlights, wrapped previous/next navigation, viewport restoration, and Escape-to-close. Scanning runs on the serialized background queue and queries are limited to 256 UTF-8 bytes.
- OSC 133 prompt navigation and copy-or-pipe command output, with pipe commands started in the OSC 7-reported directory.
- Bounded Kitty graphics snapshots with generation-keyed, transfer-once RGBA image caching, GPU-resident Metal textures, source cropping and Retina-aware placement.
- Precise local scrolling, copy-on-select cell/word/line selection, Option-drag rectangular selection, drag auto-scroll, shell-quoted Finder file drops, and a native terminal context menu. Terminal mouse press, release, drag, and wheel reporting remain available when requested by applications, with Shift forcing local selection.
- Bounded native text-area accessibility for the visible terminal viewport, including UTF-16 text and line ranges, selection and cursor position, and screen geometry. The snapshot is immutable during VoiceOver queries and does not synchronously query the PTY or terminal core; terminal input remains intentionally non-settable because it cannot truthfully replace arbitrary document text.
- Command-C copy and bracketed Command-V paste.
- Command-hover underlines terminal-detected links and click opens only schemes accepted by the terminal core.
- Desktop notifications are queued (32, 4096 combined UTF-8 bytes) and delivered only while no terminal window is key. Clicking one activates its live window, native tab, and pane; if that pane has closed, Zigonaut activates without opening a window. Permission is requested once by macOS.
- OSC 9;4 progress from the focused terminal is shown with a native determinate or indeterminate Dock progress indicator, including paused and error states; stale reports expire after 15 seconds.
- A singleton native Settings window with a noncustomizable preference toolbar, restored pane selection, pane-specific sizing, aligned macOS forms, bundled themes, full palette overrides, normal and intense font weights, scrollback limits, initial dimensions, grid alignment, independent padding, edge colours, shell selection, restore defaults, and guarded OSC 52 clipboard settings. Clipboard writes default off, are bounded and only accepted immediately when explicitly enabled; the terminal callback cannot defer a reply for later confirmation.
- Synchronized, bounded C ABI styled snapshots/copy and OSC terminal titles; nonblocking PTY writes on a serial background writer; callback teardown drains the reader before returning.
- A bundled high-resolution application icon, dynamic foreground-process and OSC window-tab titles, standard macOS application menus, and restoration of windows, native tab groups, split ratios/focus, and safe local OSC 7 working directories as fresh shells.

## Shortcuts

| Action | macOS shortcut | Windows-style discoverability |
|---|---|---|
| New tab / window | Command-T / Command-N | Menus expose both actions |
| Split right / down | Control-Shift-O / Control-Shift-E | Matches README |
| Close focused pane/tab | Command-W | Standard macOS convention (Windows uses Control-Shift-W) |
| Next / previous tab | Command-Shift-] / Command-Shift-[ | Standard tab convention |
| Focus left/right/up/down | Control-Option-Arrow | Moves to the nearest pane in that direction |
| Focus previous/next pane | Control-Option-Page Up / Page Down | Wraps through panes in layout order |
| Resize panes | Control-Option-Shift-Arrow | Moves the nearest matching divider by 5% |
| Equalize panes | Control-Option-= | Gives panes equal space along each split axis |
| Toggle focused-pane zoom | Control-Shift-Return | Preserves the underlying layout |
| Find / copy / paste | Command-F / Command-C / Command-V | Standard macOS convention |
| Zoom in/out/reset | Command-Plus / Command-Minus / Command-0 | Standard macOS convention |
| Settings | Command-Comma | Standard macOS convention |

## Remaining parity gaps

This is not feature parity. Closing panes, tabs, windows, or the application now uses native confirmation only when foreground jobs would be terminated. Accessibility covers the current viewport rather than scrollback. Keyboard protocol input is routed through the shared encoder, while full IME/protocol interaction remains dependent on AppKit composition behaviour. CI packages an ad-hoc-signed ARM64 application archive; Developer ID signing and notarization remain outstanding.
