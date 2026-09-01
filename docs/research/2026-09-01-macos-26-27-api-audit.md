# Research: macOS 26 and 27 API audit

**Date**: 2026-09-01
**Question**: Does Zigonaut use the right macOS APIs, and which macOS 26 and 27 APIs should it adopt?
**Status**: Complete for the macOS 26.5 and 27.0 SDKs; both toolchains pass after applying the Zig 0.16 compatibility overlay

## Conclusion

Zigonaut already uses a strong native macOS foundation. AppKit owns lifecycle, windows, tabs, menus, input and accessibility; SwiftUI owns pane and settings layout; Metal presents an event-driven renderer; CoreText and Core Graphics handle text and raster content; and a dedicated `posix_spawn` helper safely creates each PTY session. Most new macOS 26 and 27 APIs do not improve these choices.

The audit found six changes worth prioritizing:

1. Remove the private title-bar view hierarchy traversal.
2. Replace the API that macOS 27 deprecates, `activate(ignoringOtherApps:)`.
3. Handle the macOS 26 `mouseCancelled(with:)` event so selection and terminal mouse reporting cannot remain stuck.
4. Modernize pane dragging with a typed `Transferable` payload, then evaluate the Xcode 27 reordering and drag-configuration APIs.
5. Disable AppKit window restoration explicitly because Zigonaut already owns restoration.
6. Reap exited PTY children promptly instead of waiting until a pane is destroyed.

Adopting Metal 4, replacing `NSTextInputClient`, replacing the Carbon keyboard-layout calls or moving terminal selection to macOS 27's `NSTextSelectionManager` is not recommended without a measured problem.

## Audit boundary and evidence

The audit covered:

- `macos/Sources`, `macos/Accessibility`, `macos/PaneLayout`, `macos/RenderSupport` and `macos/Restoration`
- `src/macos/core.zig`, `src/macos/pty_helper.zig` and the C ABI
- `build.zig`, `macos/Package.swift`, `macos/assemble.sh` and `macos/Info.plist`
- AppKit, SwiftUI, Accessibility, UserNotifications, Metal, MetalKit, QuartzCore, Core Graphics, CoreText, HIToolbox, POSIX process and PTY APIs

The local machine runs macOS 27.0 beta. The audit checked declarations directly in both Xcode 26.6's macOS 26.5 SDK and Xcode 27.0 beta build 27A5252f's macOS 27.0 SDK. The Xcode 27 Swift compiler is Apple Swift 6.4. The machine's global developer directory remains on stable Xcode 26.6; Xcode 27 checks used `DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer`.

`zig build ci` passed with Xcode 26.6 on 2026-09-01: all Zig, shell-integration and Swift tests passed, including 19 Swift Testing cases and two XCTest restoration cases. After applying the compatibility overlay described below, the complete `zig build ci` also passed with Xcode 27. A separate `swift build --package-path macos` completed without diagnostics.

Before the overlay, Xcode 27's `zig build ci` failed while compiling Zig 0.16.0's bundled LLVM-21 libc++, before any failing Zigonaut source, because `libcxx/include/__random/clamp_to_integral.h` referred to an undeclared `INFINITY`. Xcode 27's `math.h` requests infinity and NaN definitions through the newer `__need_infinity_nan` protocol, which Zig 0.16's bundled Clang `float.h` does not implement.

Ghostty fixed this exact combination in July 2026 by overlaying the SDK's `math.h` and supplying fallback `INFINITY` and `NAN` definitions. Zigonaut's pinned Ghostty commit, `da5ddcb`, already contains that fix, but build-step settings do not propagate from Ghostty to Zigonaut's separate compile artifacts. Zigonaut now applies the equivalent SDK configuration in `build.zig` to its macOS core and test artifacts while reusing Ghostty's compatibility header directly. Current Zig main still has the affected libc++ expression. LLVM main independently replaced it with `numeric_limits<_RealT>::infinity()` in August 2026, but no Zig release or backport containing that change was found.

## Priority findings

### P0: Remove private title-bar hierarchy traversal

`macos/Sources/main.swift:8-37` searches descendants by the private runtime class names `NSTitlebarContainerView` and `NSTitlebarView`, then modifies their backing layers. The macOS-major-version check only selects which private hierarchy to expect. It does not make that hierarchy a supported API.

This is the highest macOS-version risk. An internal hierarchy can change in a point release, and the code may interfere with Liquid Glass's adaptive title-bar material. Apple specifically recommends removing custom title-bar backgrounds where possible and allowing the system to provide the latest appearance.

**Recommendation**

1. Test whether the existing public configuration is sufficient: `NSWindow.backgroundColor`, `titlebarAppearsTransparent` and `titlebarSeparatorStyle`.
2. If terminal content must extend into title-bar space, use `.fullSizeContentView`, safe areas and public `NSTitlebarAccessoryViewController` APIs.
3. Keep custom terminal-coloured chrome only if a visual test establishes it as a product requirement. Do not implement it by matching private class names.

No private frameworks or private symbols are linked. The problem is the dependency on private view structure.

### Resolved: Support Zig 0.16.0 with the Xcode 27 SDK

Zigonaut now applies Ghostty's Zig 0.16 compatibility approach to each of its own macOS artifacts that links Ghostty and libc++. It renders a native SDK libc configuration with the compatibility include overlay, enables libc++ vendor availability annotations and supplies the SDK framework, header and library paths explicitly. Both Xcode 26.6 and Xcode 27 builds pass. The checked release bundle remains arm64, has a macOS 15 minimum and was linked against a macOS 26 SDK.

**Recommendation**

- Remove the compatibility path once Zig's bundled Clang headers implement `__need_infinity_nan`, or once the required Zig release includes another confirmed fix.
- Add an Xcode 27 CI lane while retaining an Xcode 26 lane for the oldest supported build environment.
- Run the complete test suite and a manual interface matrix on macOS 26 and 27: window tabs, title bars, settings forms, reduced transparency, increased contrast, VoiceOver, IME, pane dragging, interrupted mouse drags and restoration.
- Keep the deployment target at macOS 15 unless the product intentionally drops older systems. New APIs should be availability-gated or back-deployed where Apple supports that.

### P1: Replace `activate(ignoringOtherApps:)`

`macos/Sources/main.swift:282`, `:322` and `:797` call `NSApp.activate(ignoringOtherApps: true)`. Apple's current documentation lists the method as deprecated through macOS 27 and directs applications to `NSApplication.activate()`, available since macOS 14. The Xcode 27 header still uses the `API_TO_BE_DEPRECATED` sentinel, so this beta may not emit a deprecation warning; the migration is still appropriate.

The replacement is source-compatible with Zigonaut's macOS 15 floor. Keep the existing explicit window ordering because activation remains asynchronous and isn't guaranteed to take effect immediately.

### P1: Handle mouse cancellation on macOS 26

`macos/Sources/TerminalSurface.swift:754-839` clears selection and mouse-reporting state only in mouse-up handlers. macOS 26 adds `NSResponder.mouseCancelled(with:)` for interrupted mouse sequences. Without it, `selecting` or `reportingButton` can remain set after AppKit cancels a drag.

**Recommendation**

Add an availability-annotated override for macOS 26. It should:

- clear `selecting` and `selectionShouldCopy`;
- end or cancel the core selection consistently;
- if `reportingButton != 0`, send the appropriate terminal release or cancellation policy before clearing it;
- refresh the model and view as needed.

Validate cancellation through Mission Control, app deactivation, interrupted drags and trackpad gestures.

### P1: Modernize pane drag and drop

`macos/Sources/Content.swift:59-76` uses `onDrag` and `onDrop(of:delegate:)`. It advertises the pane UUID as plain text but trusts separate mutable state (`window.draggingPane`) as the real source. This allows unrelated plain-text drags to enter validation and can leave source state behind when a drag ends without a drop.

**Recommendation**

1. First adopt a dedicated `Transferable` pane identifier with a private content type. The basic typed `draggable` and `dropDestination` APIs are available from macOS 13, which improves type safety on every supported system.
2. On macOS 26, evaluate the session-based `dropDestination`, `DropSession`, `dragConfiguration` and `dropConfiguration` APIs. The Xcode 27 SDK marks these available on macOS 26; the older item-array `dropDestination` overload is soft-deprecated in their favour. State the move operation explicitly and use the drop session rather than out-of-band mutable source state.
3. On macOS 27, evaluate `reorderable` and `reorderContainer` for pane movement. Zigonaut needs edge-based tree insertion rather than linear collection ordering, so these may not fit directly.

The existing `onDrop(of:delegate:)` remains available and is not formally deprecated in the Xcode 27 SDK. Migration is justified by typed payloads, explicit operations and reliable drag-session state rather than immediate API removal.

### P1: Establish one window-restoration owner

Zigonaut saves and restores complete window, native-tab and pane topology itself in `macos/Sources/main.swift:384-499` and `macos/Restoration/Restoration.swift`. AppKit makes titled windows restorable by default, yet Zigonaut does not set a restoration identifier or restoration class and does not disable AppKit restoration.

**Recommendation**

Set `isRestorable = false` on terminal and settings windows. This is the smallest change and makes the current custom store the explicit owner. Adopting `NSWindowRestoration` instead would be a larger rewrite with no macOS 26/27-specific benefit.

### P1: Reap exited PTY children promptly

`src/macos/core.zig:443-491` marks a terminal exited when the PTY read loop ends but does not call `waitpid`. `zigonaut_core_destroy` reaps the child at `src/macos/core.zig:1521-1560`, so an exited shell can remain a zombie while its pane remains open.

**Recommendation**

Give one synchronized code path ownership of `waitpid`. Reap the direct child after terminal closure, record its status and preserve bounded process-group cleanup for explicit pane destruction. Handle `EINTR` and prevent the read thread and destructor from racing to reap the same child.

This is not a new macOS API opportunity; it is a correctness issue found while auditing the process APIs.

## Secondary opportunities

### Use Liquid Glass for the pane drag handle

`macos/Sources/Content.swift:49-65` draws the hover-only pane drag handle with `.ultraThinMaterial`. This is one of the few custom controls that fits Apple's Liquid Glass guidance: it is interactive, floats above content and represents a top-level manipulation action.

On macOS 26, evaluate `.glassEffect()` or a glass button treatment for this handle, with the current material as the macOS 15–25 fallback. Test reduced transparency, increased contrast and inactive-window appearance. Do not apply glass to terminal content or every overlay.

### Complete the `NSTextInputClient` geometry contract

`macos/Sources/TerminalSurface.swift:691-707` returns `0` for every `characterIndex(for:)` query and ignores the proposed range in `firstRect(forCharacterRange:actualRange:)`. `NSTextInputClient` remains the right API, but these placeholder answers can position or query complex IME input incorrectly.

Map points and requested UTF-16 ranges to the marked-text/cursor geometry. Return `NSNotFound` when no character can be mapped.

### Keep accessibility snapshots fresh for all clients

`macos/Sources/TerminalSurface.swift:190-230` updates its cached text snapshot only while VoiceOver is enabled. Other accessibility clients can query the same AppKit API and receive stale data.

Keep the VoiceOver check as an optimization for unsolicited notifications, not as the sole refresh trigger. Refresh lazily in accessibility getters or maintain the bounded snapshot regardless. Consider `.layoutChanged` for pane or grid layout changes only after testing notification volume with Accessibility Inspector.

### Compile static Metal shaders at build time

`macos/Sources/TerminalSurface.swift:304-370` embeds fixed Metal source and calls `makeLibrary(source:)` at launch. Move static shaders to a `.metal` source, compile a `.metallib` during the build and load it from bundle resources. This moves compiler failures to build time and avoids runtime compilation.

This is a conventional Metal improvement, not a reason to adopt Metal 4.

### Define the renderer's colour-management policy

The renderer uses `.bgra8Unorm`, device RGB Core Graphics contexts, `CAMetalLayer` without a colour space and texture loading with `.SRGB: false` (`macos/Sources/TerminalSurface.swift:957-993`, `:1222-1255`, `:1298-1337`). Decide whether exact unmanaged terminal byte colours or display-consistent sRGB output is intended, then configure and test the pipeline consistently on standard- and wide-gamut displays.

Do not enable extended dynamic range or HDR only because newer APIs exist; Zigonaut currently produces SDR UI.

### Make shell selection window-modal

`macos/Sources/Content.swift:608-618` calls `NSOpenPanel.runModal()`. Prefer `beginSheetModal(for:)` when the settings window is available, retaining an application-modal fallback only if necessary.

### Simplify geometry observation where it remains stable

`macos/Sources/Content.swift:8-13`, `:79-82`, `:158-203` and `:226` use nested `GeometryReader` and `PreferenceKey` plumbing. `onGeometryChange`, available at the macOS 15 floor, may simplify this. Treat it as a refactor candidate, not a required modernization, and verify live split resizing does not introduce feedback loops.

### Distribution and metadata

`macos/assemble.sh:45-47` ad-hoc signs the bundle with `codesign --deep`, and `macos/Info.plist:10-11` duplicates the package version manually. The README already documents the ARM64-only, ad-hoc-signed release.

For normal Internet distribution, sign components inside-out with Developer ID, enable hardened runtime, notarize and staple the archive. Avoid `--deep` for release signing. Generate bundle versions from release metadata. These are release-engineering requirements, not macOS 26/27 API adoption.

## APIs to keep

### Keep classic Metal

Metal 4 is available on Apple silicon with macOS 26, but Zigonaut's renderer is a small event-driven 2D compositor. It already acquires drawables late, sets Retina drawable geometry correctly, performs retained row updates and falls back to AppKit rendering. A Metal 4 migration would require a second availability-gated command and pipeline backend while retaining classic Metal for macOS 15–25 and Intel. No measured bottleneck justifies that complexity.

Compile the shaders ahead of time and profile first. Reconsider Metal 4 only if profiling identifies command-generation or pipeline-management pressure that Metal 4 directly solves.

### Keep `NSTextInputClient` and Carbon keyboard translation

The AppKit text-input client plus `interpretKeyEvents` is appropriate for a custom terminal surface with IME and dead-key composition. SwiftUI key handlers are not a replacement.

`TISCopyCurrentKeyboardLayoutInputSource`, `TISGetInputSourceProperty`, `UCKeyTranslate` and `LMGetKbdType` in `macos/Sources/TerminalSurface.swift:627-642` remain public and non-deprecated in the macOS 26.5 SDK. Despite the Carbon module name, they are still the supported low-level route to an unshifted layout code point. Keep this path until Apple deprecates it or provides a documented replacement. Remove only genuinely unused imports.

### Do not adopt `NSTextSelectionManager` yet

macOS 27's `NSTextSelectionManager` provides standard document-like click, drag, shift-click and word/line/paragraph selection through gesture recognizers. Its Xcode 27 contract requires both a delegate and an `NSTextSelectionDataSource`, typically an `NSTextLayoutManager` or similar text-layout object. Zigonaut instead owns a custom grid and also needs terminal mouse reporting, Option-drag rectangular selection, grid-based selection units, copy-on-select and PTY-aware autoscroll. Replacing the current implementation would require a text-layout adapter while preserving substantial custom logic.

Use `mouseCancelled(with:)` now. Revisit `NSTextSelectionManager` only if a prototype can provide its data-source contract and all terminal semantics with less code and no interaction regressions.

### Keep the current window, menu and notification APIs

- Native `NSWindow` tabs and tab groups remain the correct APIs.
- Programmatic `NSMenu`, responder-chain selectors and `NSMenuItemValidation` remain appropriate for the manually driven `NSApplication`.
- macOS 27 reduces menu item image use and adds `preferredImageVisibility`; Zigonaut's mostly text-only menus and standard selectors already fit this direction. Do not add a broad set of icons merely to imitate macOS 26.
- `UNUserNotificationCenter`, delegate response routing and stable pane identity remain current.
- `NSViewRepresentable` remains the right boundary for the persistent AppKit/Metal terminal surface.
- Public `openpty`, `posix_spawn`, `posix_spawn_file_actions_addinherit_np`, `proc_name`, `TIOCSCTTY` and `TIOCSWINSZ` remain valid in the supported SDK.
- The dedicated PTY helper is safer than calling `fork` or `forkpty` from the multithreaded AppKit process.

### macOS 27 APIs that do not apply

The current app does not benefit from macOS 27's `NSRefreshController`, scroll-gesture relationship APIs, semantic `NSToolbarItemGroup` roles, segmented-control tab roles or title-bar accessory overflow changes. The settings colour-scheme picker selects a value rather than navigating content, so it should remain a normal segmented picker rather than adopt the new tabs role.

## Suggested implementation order

1. Establish the dual-SDK CI lane now that local Xcode 26 and 27 builds pass.
2. Replace `activate(ignoringOtherApps:)` and add `mouseCancelled(with:)`.
3. Remove private title-bar traversal after visual prototypes establish the public replacement.
4. Disable AppKit restoration and fix PTY reaping.
5. Introduce a typed pane drag payload, then prototype Xcode 27 drag/reordering APIs.
6. Address IME geometry and accessibility freshness.
7. Consider Liquid Glass for the pane handle, ahead-of-time Metal shaders and colour management as focused quality projects.

## References

- [Apple: macOS 27 beta 8 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes)
- [Apple: macOS 26 release notes](https://developer.apple.com/documentation/macos-release-notes/macos-26-release-notes)
- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [WWDC25: Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/)
- [WWDC25: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [WWDC26: Code-along — Build powerful drag and drop in SwiftUI](https://developer.apple.com/videos/play/wwdc2026/271/)
- [Apple: `NSApplication.activate(ignoringOtherApps:)`](https://developer.apple.com/documentation/appkit/nsapplication/activate(ignoringotherapps:))
- [Apple: `NSResponder.mouseCancelled(with:)`](https://developer.apple.com/documentation/appkit/nsresponder/mousecancelled(with:))
- [LLVM libc++ change replacing `<random>`'s global math dependencies](https://github.com/llvm/llvm-project/pull/213084)
- [Zig's current `clamp_to_integral.h`](https://github.com/ziglang/zig/blob/master/lib/libcxx/include/__random/clamp_to_integral.h)
- [Ghostty PR #13419: support Xcode 27 SDK headers](https://github.com/ghostty-org/ghostty/pull/13419)
- [Ghostty's Xcode 27 `math.h` compatibility wrapper](https://github.com/ghostty-org/ghostty/blob/main/pkg/apple-sdk/include/math.h)
- [Apple: Metal best practices — drawables](https://developer.apple.com/library/archive/documentation/3DDrawing/Conceptual/MTLBestPracticesGuide/Drawables.html)
- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
