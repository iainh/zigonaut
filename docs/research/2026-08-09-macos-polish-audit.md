# Research: macOS Interface and Performance Polish

**Date**: 2026-08-09
**Question**: What are the ten highest-impact remaining ways to polish Zigonaut's macOS interface and performance?
**Status**: Complete; recommendations are implementation candidates, not measured benchmarks

## Ranking method

Candidates are ranked by user-visible impact and frequency, then implementation risk and likely performance gain. Existing native tabs, preference toolbar, title integration, Metal presentation, event-driven refresh, Retina handling, row hashes, text shaping, Kitty graphics, resize anchoring, and foreground-process titles are treated as completed foundations rather than recommended again.

## Ranked recommendations

| Rank | Recommendation | Area | Impact | Effort |
| --- | --- | --- | --- | --- |
| 1 | Make the Zig-to-Swift render ABI incremental | Performance | Very high | Large |
| 2 | Restore windows, tabs, pane topology, and active pane | Interface | Very high | Large |
| 3 | Confirm destructive closes only when a foreground job is at risk | Interface | High | Medium |
| 4 | Route notification clicks to their originating terminal | Interface | High | Medium |
| 5 | Make pane focus genuinely directional | Interface | High | Medium |
| 6 | Expand VoiceOver text, selection, cursor, and range semantics | Accessibility | High | Large |
| 7 | Avoid transferring unchanged Kitty image pixels across the ABI | Performance | Medium–high | Medium |
| 8 | Retain row-local drawing data to remove whole-scene filtering | Performance | Medium–high | Medium |
| 9 | Complete advanced keyboard protocol and input parity | Input | Medium–high | Large |
| 10 | Refine native menu and context-menu validation | Interface | Medium | Small |

### 1. Make the Zig-to-Swift render ABI incremental

Every refresh currently requests a full cell/text snapshot, creates a Swift `String` and `TerminalRenderCell` for every returned cell, computes overlays, and publishes a complete snapshot. Row hashes prevent unchanged rows from being rasterized and uploaded, but they do not avoid the earlier full snapshot transport and materialization cost.

Add a generation and dirty-row range contract to the ABI. Retain rows in Swift and replace only changed rows, while preserving the current bounded, all-or-nothing buffer semantics. This should be the first performance project because terminal output commonly changes only a small fraction of the viewport.

### 2. Restore windows, tabs, pane topology, and active pane

Launch always creates a fresh terminal and only the native window frame is restored. Persist window/tab grouping, split trees and ratios, active panes, and safe launch context such as working directories. Restore process commands only when product policy explicitly permits relaunching them; scrollback restoration can be a later phase.

This is the largest everyday Mac workflow gap because native applications are expected to preserve the user's workspace across quit, update, and restart.

### 3. Confirm destructive closes only when a foreground job is at risk

Closing a pane currently removes it immediately; window and tab closes can likewise terminate running work. Query the pane's foreground process/job state and use a native alert or sheet only when closing would destroy meaningful work. Idle shells should continue to close without friction. The same policy should cover close-pane, close-tab, close-window, and quit.

### 4. Route notification clicks to their originating terminal

Notifications currently have anonymous UUID request identifiers and no response delegate. Store stable window/tab/pane identity in notification content, install `UNUserNotificationCenterDelegate` before launch completes, and on response activate the application, reveal the correct native tab/window, and focus the originating pane. Expired identities should fall back to opening the most relevant live terminal without creating a new one unexpectedly.

### 5. Make pane focus genuinely directional

The commands labelled right/down and left/up currently cycle through leaf order. Track pane frames and select the nearest candidate in the requested half-plane, scoring primary-axis distance before perpendicular distance. Provide four actual directional commands and keep next/previous cycling as separate commands if desired.

### 6. Expand VoiceOver text, selection, cursor, and range semantics

The terminal currently exposes a bounded text-area value, label, focus state, and value-change notifications. Add selected-text ranges, visible and attributed text ranges, insertion-point/cursor location, bounds for ranges, line/index conversion, and appropriate writable/editable semantics for terminal input. Keep queries bounded and backed by a stable snapshot so accessibility clients cannot stall the PTY/render path.

### 7. Avoid transferring unchanged Kitty image pixels across the ABI

Swift caches decoded images by image ID and generation, but each image refresh still transfers the complete ABI image-data buffer before that cache is consulted. Separate immutable image payload updates from placement updates. Transfer pixel data only for unseen generations, retain it on the host side, and send lightweight placement deltas thereafter.

### 8. Retain row-local drawing data

Dirty-row rasterization currently filters the complete cell array once for every dirty row and draws the complete image list under each row clip. Store cells and overlapping image placements by row when the snapshot changes. Rasterizing one dirty row can then access its data directly, reducing transient arrays, repeated scans, and Core Graphics bookkeeping.

This is distinct from item 1: item 1 reduces core-to-Swift transport and object creation; this item reduces work inside the retained Swift/CoreText renderer.

### 9. Complete advanced keyboard protocol and input parity

Audit the terminal core's supported enhanced keyboard protocols against the AppKit event translation path, then preserve physical key, logical key, modifiers, repeat, and key-up information where the protocol requests them. Include non-US layouts, dead keys, Option behaviour, function/navigation keys, and IME regression tests. Prefer AppKit text-input APIs for text and protocol encoding for non-text keys rather than duplicating layout interpretation.

### 10. Refine native menu and context-menu validation

Basic `NSMenuItemValidation` exists, but commands can be more precise. Disable Copy without a selection, directional focus without a destination, Close Pane when it would actually close a tab/window (and title it accordingly), search navigation without matches, and split commands at any enforced pane limit. Apply the same state rules to the terminal context menu and update dynamic titles before display.

## Evidence in the current implementation

- `macos/Sources/Models.swift:514-594` performs full snapshot transfer and per-cell Swift materialization.
- `src/macos/core.zig:535-553` exports the current complete render snapshot.
- `macos/Sources/TerminalSurface.swift:663-699` uses row hashes to retain raster output, after full model materialization.
- `macos/Sources/TerminalSurface.swift:723-749` filters all cells for each dirty row and redraws all image placements under the clip.
- `macos/Sources/Models.swift:607-670` transfers image data on each retrieval despite generation-keyed decoded-image caching.
- `macos/Sources/main.swift:167-175` requests notification permission and always creates a new window at launch.
- `macos/Sources/main.swift:183-192` creates notifications without source identity or click routing.
- `macos/Sources/Models.swift:1012-1016` implements focus as presentation-order cycling.
- `macos/Sources/Models.swift:1005-1010` closes the focused pane without job-state protection.
- `macos/Sources/TerminalSurface.swift:113-130` exposes the current baseline accessibility value.
- `macos/Sources/main.swift:426-441` contains the current baseline menu validation.
- `macos/README.md:40` documents the remaining parity gaps.

## Apple guidance considered

- Apple documents event-driven `MTKView` rendering through `isPaused` plus `enableSetNeedsDisplay`; Zigonaut already follows the equivalent on-demand strategy, so a continuous display loop is not recommended.
- Apple's Metal best-practices guide recommends acquiring drawables as late as possible and holding them briefly; rendering CPU-side retained rows before calling `nextDrawable()` is consistent with that guidance.
- Apple requires the `UNUserNotificationCenterDelegate` to be assigned before launch completes to reliably process user responses.
- Apple's focus, keyboard, menus, accessibility, and window guidance favours predictable spatial navigation, state-sensitive commands, complete keyboard operation, native restoration, and rich semantic accessibility over visual imitation.

## Sources

- [Apple: enableSetNeedsDisplay](https://developer.apple.com/documentation/metalkit/mtkview/enablesetneedsdisplay)
- [Apple: Metal Best Practices — Drawables](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html)
- [Apple: UNUserNotificationCenterDelegate](https://developer.apple.com/documentation/usernotifications/unusernotificationcenterdelegate)
- [Apple: Focus and selection](https://developer.apple.com/design/human-interface-guidelines/focus-and-selection)
