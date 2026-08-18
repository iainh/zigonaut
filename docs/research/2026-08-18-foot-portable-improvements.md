# Research: Portable improvements from foot

**Date**: 2026-08-18
**Question**: Which ideas from the foot terminal emulator would improve Zigonaut on Windows or macOS?
**Status**: Complete; recommendations are implementation candidates, not measured benchmarks

## Conclusion

Foot's best portable ideas for Zigonaut are interaction and scheduling details, not its Linux rendering backend. Zigonaut already has the important rendering foundations: libghostty dirty rows, retained native scenes, compositor-paced Windows presentation, coalesced macOS refreshes, generated pseudographics, enhanced keyboard encoding and native accessibility.

The highest-value remaining work is:

1. bring synchronized-output suppression and its watchdog to macOS;
2. make macOS scrollback search incremental instead of scanning under the terminal lock;
3. add a keyboard-driven link and regex hint mode;
4. add smart-case, logical-line search and richer selection gestures;
5. report focus immediately when an application enables focus reporting;
6. extend native notifications to the tracked OSC 99 protocol;
7. turn foot's failure history into differential tests for the pinned libghostty dependency and Zigonaut's host boundaries.

## Current overlap

Several attractive foot features should not become new Zigonaut projects because equivalent mechanisms already exist.

| Foot idea | Zigonaut status | Evidence |
| --- | --- | --- |
| Dirty rendering | Implemented at row granularity through libghostty dirty state, snapshot hashes and retained native rows | `src/shared/terminal.zig:1394-1603`, `src/windows/terminal_view.zig:875-1054`, `src/macos/core.zig:753-834`, `macos/Sources/TerminalSurface.swift:968-984` |
| Frame coalescing | Windows is paced by the DXGI frame-latency object; macOS coalesces PTY wakes and caps sustained output near 8 ms | `src/windows/terminal_view.zig:875-1054`, `macos/Sources/Models.swift:20-52` |
| Synchronized updates | Complete on Windows, including a one-second fail-safe and resize/teardown release | `src/windows/session.zig:128-154`, `src/windows/session.zig:493-593`, `src/windows/terminal_view.zig:1036-1055` |
| Ordered PTY output | Windows uses one bounded asynchronous operation queue; macOS serializes writes and moves ordinary UI writes off the main thread | `src/windows/session.zig:876-1097`, `src/macos/core.zig:598-625`, `macos/Sources/Models.swift:384` |
| Generated box drawing | Shared pseudographics are rendered on both platforms | `src/shared/pseudographics.zig` |
| Modern keyboard encoding | Physical key, text, consumed modifiers, repeat and release reach libghostty's encoder | `src/shared/terminal.zig:1606-1783`, `src/macos/core.zig:447-596`, `src/windows/input.zig` |
| OSC 7/8/9/52/133 integration | Working directory, links, notifications, guarded clipboard writes, prompt navigation and command-output extraction exist | `src/shared/terminal.zig:1022-1144`, `src/shared/terminal.zig:1260-1385`, `src/windows/session.zig:621-805`, `src/macos/core.zig:1055-1329` |
| Native accessibility | Windows exposes UI Automation text ranges; macOS exposes an immutable AppKit accessibility snapshot | `src/windows/terminal_view.zig:169-352`, `winui/TerminalAutomationPeer.h`, `macos/Accessibility/TerminalAccessibilityLayout.swift`, `macos/Sources/TerminalSurface.swift:101-218` |

## Ranked recommendations

### 1. Complete synchronized output on macOS

Foot suppresses grid presentation while private mode 2026 or the older synchronized-update DCS form is active. It accumulates damage, presents once when the transaction ends and forcibly releases suppression after one second. Resize and teardown also cancel the mode.

Windows Zigonaut already follows this contract. The macOS reader currently feeds output, increments `output_generation` and wakes Swift after every successful read without checking synchronized-output state. The snapshot path can therefore publish an application's intermediate frame.

Port the existing `SynchronizedOutput` state machine to a shared host helper or implement the same small state machine in `src/macos/core.zig`. The wake contract should be:

- wake on entry only to arm the native watchdog, not to render terminal cells;
- suppress subsequent grid refreshes while mode 2026 remains active;
- wake exactly once on exit;
- clear mode and wake after one second;
- clear it on resize, reset, PTY exit and teardown.

This is a correctness fix for TUIs, not merely a performance optimization.

### 2. Make macOS search incremental and improve shared matching

Foot's search mode remains responsive while searching history and adds useful semantics: smart case, all-match highlighting, composed and wide-character handling, query reuse and logical selection extension.

Zigonaut's Windows host already scans with a 2 ms budget and yields between batches. macOS `zigonaut_core_search_set`, by contrast, scans every scrollback row synchronously while holding `Core.mutex`. A large history can block AppKit, PTY parsing and rendering. The shared matcher is byte-exact, case-sensitive and row-local, so a match cannot cross a soft wrap.

Implement this in two stages:

1. move the Windows `SearchCache` and time-budgeted scan state behind a platform-neutral search session used by both hosts;
2. add smart case and reconstruct logical lines across soft wraps, with a byte-to-grid-range map that preserves grapheme and wide-cell boundaries.

Keep the existing all-match highlighting and cancel-to-restore-viewport behaviour. Add previous-query reuse only after the common session owns query history.

### 3. Add keyboard-driven link and regex hints

Foot's URL mode freezes the visible grid, underlines detected and OSC 8 links and assigns short keyboard labels. Labels are assigned bottom-to-top so the newest output keeps the shortest stable keys. OSC 8 links win overlaps, duplicate targets share a key, typed prefixes filter candidates and persistent mode can activate several matches.

Zigonaut currently discovers one link beneath the pointer and requires Ctrl-click on Windows or Command-click on macOS. A shared hint mode would make links usable without precise pointing and would work especially well in dense build and test output.

Build the candidate and label engine in shared Zig. Native clients should own the overlay, shortcut, clipboard and URL launch. Preserve these foot details:

- snapshot visible rows when entering the mode so output cannot move a label;
- map UTF-8 offsets back to grid coordinates, including wide cells;
- prefer OSC 8 ranges over auto-detected overlaps;
- assign labels from bottom to top;
- validate every URI with Zigonaut's existing allowed-scheme policy;
- support copy as well as launch before adding arbitrary regex commands.

Custom regex actions are a useful second phase, but should use named, configured actions rather than execute terminal-provided text.

### 4. Add quote, whitespace and nearest-edge selection

Foot distinguishes character, block, word, whitespace-only word, quote and logical-line selections. Triple-click selects inside enclosing quotes and quadruple-click selects the logical row. Right-click extends the nearest existing edge while preserving the original selection unit. Dragging beyond the viewport scrolls proportionally to distance.

Zigonaut currently exposes only cell, word and line units. On macOS, two clicks select a word and three or more select a line; Windows follows the same core units. Add:

- quote selection with safe handling at row and scrollback boundaries;
- quadruple-click logical-line selection while retaining triple-click line selection if that better matches native expectations;
- whitespace-run selection as an explicit modified gesture;
- nearest-edge extension without discarding the original unit;
- tests for final-column wide characters, soft wraps, reversed rectangular selections and resize during selection.

Do not copy foot's primary-selection policy. Zigonaut's native clipboard behaviour should remain platform-specific.

### 5. Report focus immediately when mode 1004 is enabled

As of foot 1.26, enabling focus reporting sends the current state immediately. This avoids waiting for a future focus transition and lets an application initialize correctly.

Zigonaut sends reports on Windows focus transitions, but `Terminal.encodeFocusReport` has no transition hook when terminal output enables mode 1004. macOS has no host focus-report bridge at all.

Track host keyboard focus per pane and detect a disabled-to-enabled mode transition after feeding output. Queue `CSI I` or `CSI O` through the normal ordered PTY path. Add macOS focus changes to the same contract. Keep window activation, pane visibility and keyboard focus distinct; mode 1004 concerns keyboard focus.

### 6. Add tracked OSC 99 notifications

Foot implements kitty's OSC 99 notification state machine: IDs, replacement, close and alive queries, urgency, expiry, icons, actions and activation/closure reports. This is richer than Zigonaut's current OSC 9/777 title-and-body callback.

Map the protocol-neutral state to Windows app notifications and `UNUserNotificationCenter`. Zigonaut already routes macOS notification clicks to a live pane, which is the right ownership model. Extend it with:

- a bounded notification table keyed by terminal and protocol ID;
- replacement and close operations;
- safe callbacks after a pane has closed;
- action and activation responses serialized back to the PTY;
- focus inhibition by default;
- strict limits on chunks, decoded icon bytes, text and expiry.

This likely requires additions to libghostty's public VT API. Prefer contributing that boundary upstream over parsing OSC 99 a second time in Zigonaut.

**Implementation status (2026-08-18): blocked upstream.** The pinned
libghostty revision and current libghostty `main` recognize OSC 9 and OSC 777,
but don't recognize OSC 99. `GhosttyTerminalDesktopNotification` exposes only
borrowed title and body strings. The unknown-sequence callback reports APC, not
unknown OSC payloads, so Zigonaut cannot safely recover OSC 99 before the
terminal parser discards it. Adding a second OSC parser around the PTY stream
would split parser state and can misinterpret control strings, UTF-8 fragments,
and terminators.

The required upstream boundary is a parsed OSC 99 event with bounded decoded
fields, a terminal-scoped protocol ID, create/replace/close/query operations,
and an API for serializing activation and closure reports. Once libghostty
provides that boundary, Zigonaut can map it to its existing native notification
owners. Both owners already resolve activation through stable pane/session IDs
rather than retaining a terminal pointer: macOS looks up a UUID in the live
window model and Windows validates a process nonce before looking up the
session. A completion arriving after pane destruction therefore has no session
state to dereference.

### 7. Use foot's changelog as a regression corpus

Foot's current unreleased fixes cover malformed percent-encoded URIs, unclamped DECCRA rectangles, huge CHT/CBT counts, zero-length text-size requests, notification callbacks after terminal destruction, wide characters at word boundaries, quote selection at column zero and selection damage after resize. Earlier releases add paste interleaving, OSC 52 replies, focus-mode transitions, enhanced-keyboard releases, reflow and scrollback wrap-around cases.

Because libghostty owns Zigonaut's parser and grid, do not reproduce foot's parser fixes in `src/shared/terminal.zig`. Instead:

1. check each case against the pinned libghostty revision;
2. add a small differential corpus for failures that reproduce;
3. report parser/grid defects upstream and pin the fixed revision;
4. retain Zigonaut tests only where host scheduling, ABI marshaling, rendering or teardown contributes to the failure.

The first host-level cases should be notification completion after pane destruction, mode-2026 timeout during resize, key release after a consumed shortcut, large paste followed immediately by input and selection mutation during reflow.

### 8. Extend latency telemetry before changing render architecture

Foot measures input-to-commit-to-present latency and uses a short coalescing deadline plus a hard upper deadline. Zigonaut has detailed Event Tracing for Windows (ETW) scroll and present events, and macOS already coalesces sustained output at 8 ms, but there is no equivalent macOS presentation trace or common key-to-present measurement.

Add timestamps for input receipt, parser completion, snapshot completion, native raster completion and compositor presentation. On macOS, use signposts and drawable presentation callbacks. On Windows, extend the existing ETW schema rather than add a second logger. Only consider row-parallel rasterization or finer cell damage if these traces show row work is still material.

## Ideas not to port directly

### Wayland shared-memory rendering

Foot's Pixman buffers, `memfd` scrolling, Wayland damage calls, subsurfaces and presentation feedback solve a different backend problem. Preserve their principles: bounded damage, one pending frame and measured presentation. Keep DirectComposition/DirectWrite and AppKit/Metal implementations native.

### Server mode

Foot's server shares fonts and glyph caches across windows, reducing startup time and memory at the cost of one failure domain and shared event-loop contention. Zigonaut already hosts many tabs and panes in one process. A separate daemon would add IPC and lifecycle risk without evidence of a startup problem. Share immutable font metadata and bounded native caches in-process if profiling justifies it.

### Row worker pools

Foot benefits from parallel CPU rasterization. Zigonaut's Windows renderer submits a retained GPU scene and macOS rasterizes only changed retained rows. Parallelizing before measuring would add cache synchronization and native text-stack threading risk. Damage and presentation telemetry should come first.

### XTGETTCAP and parser features in the host

XTGETTCAP, rectangular editing, keyboard-protocol stacks, sixel and other control sequences belong to the terminal library. Zigonaut should expose or improve them through libghostty rather than add a second parser around it.

### Accessibility from foot

Foot has no comparable native accessibility text model. Zigonaut should keep its UI Automation and AppKit implementations and continue deriving both from stable renderer-neutral snapshots.

## Suggested implementation order

1. macOS synchronized-output watchdog and suppression
2. incremental shared search session, then smart case and logical lines
3. mode-1004 immediate focus reporting on both platforms
4. keyboard link hints
5. richer selection semantics
6. differential libghostty regression corpus
7. common latency markers and macOS signposts
8. OSC 99 after the libghostty API boundary is settled

## Upstream sources

- [foot repository](https://codeberg.org/dnkl/foot)
- [foot README](https://codeberg.org/dnkl/foot/src/branch/master/README.md)
- [foot changelog](https://codeberg.org/dnkl/foot/src/branch/master/CHANGELOG.md)
- [foot configuration manual](https://codeberg.org/dnkl/foot/src/branch/master/doc/foot.ini.5.scd)
- [foot control-sequence manual](https://codeberg.org/dnkl/foot/src/branch/master/doc/foot-ctlseqs.7.scd)
- [foot terminal and scheduling implementation](https://codeberg.org/dnkl/foot/src/branch/master/terminal.c)
- [foot rendering implementation](https://codeberg.org/dnkl/foot/src/branch/master/render.c)
- [foot URL mode](https://codeberg.org/dnkl/foot/src/branch/master/url-mode.c)
- [foot search](https://codeberg.org/dnkl/foot/src/branch/master/search.c)
- [foot selection](https://codeberg.org/dnkl/foot/src/branch/master/selection.c)
