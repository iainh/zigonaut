# Research: Native macOS UI for Zigonaut

**Date**: 2026-08-08
**Question**: Which macOS UI framework best preserves Zigonaut's Zig core and existing WinUI frontend while delivering a modern, native Mac experience?
**Status**: Complete; architecture and product-policy decisions remain

## Context

Zigonaut is currently a Windows-only application. Its Zig executable owns the application model, terminal sessions and Win32 terminal views. A dynamically loaded C++/WinRT DLL supplies the WinUI 3 shell. The goal is to add a first-class macOS application without replacing WinUI or reducing the Mac frontend to a toolkit-styled port.

The main constraint is deeper than the UI framework. The terminal model has useful portable parts, but the build, coordinator, process transport, synchronization, image decoding and renderer are coupled to Windows.

## Recommendation

Use a hybrid native stack:

- **AppKit** owns application and window lifecycle, menus, the responder chain, text input, accessibility, drag and drop, native notifications and restoration.
- **SwiftUI** composes the tab strip, split layout, settings, search and transient overlays.
- A persistent custom **AppKit `NSView`** hosts each terminal pane inside SwiftUI through `NSViewRepresentable`.
- **Zig** remains the source of truth for terminal sessions, tabs, pane trees, search, selection and committed layout state.
- A new **C application binary interface (ABI)** connects Swift to opaque Zig app, window and surface handles.
- A new Zig **Metal/CoreText terminal renderer** draws directly into the native surface.
- Xcode consumes the Zig core as a static **XCFramework** and owns the `.app` bundle, signing, entitlements and notarization.

This is not a pure SwiftUI recommendation. SwiftUI supplies the most current standard controls and declarative composition, while AppKit supplies the deterministic desktop and terminal-specific behaviour that a custom terminal surface needs.

```text
┌──────────────────────────────── macOS application ────────────────────────────────┐
│ AppKit lifecycle, windows, menus, input, accessibility and notifications          │
│                │                                                                  │
│                ▼                                                                  │
│ SwiftUI tabs, split presentation, settings, search and overlays                   │
│                │ NSViewRepresentable                                              │
│                ▼                                                                  │
│ Persistent TerminalSurfaceView ─────── native view/layer, IME and accessibility   │
└───────────────────────────────┬────────────────────────────────────────────────────┘
                                │ C ABI
                                ▼
┌──────────────────────────────── Zig embedded core ────────────────────────────────┐
│ App and pane model ─ Session ─ Ghostty VT ─ POSIX PTY                             │
│          │                      │                                                  │
│          └──── model events     └──── render snapshot ─ Metal/CoreText renderer   │
└────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────── Windows application ────────────────────────────────┐
│ Existing Zig coordinator, Win32 terminal view, DirectWrite renderer and WinUI 3   │
└────────────────────────────────────────────────────────────────────────────────────┘
```

## Why AppKit and SwiftUI are the best fit

### They provide the most current macOS design

Apple states that standard SwiftUI and AppKit controls automatically adopt the current macOS appearance, including Liquid Glass on current releases. Standard bars, sheets, popovers, controls and navigation elements also adapt to reduced transparency, reduced motion and other accessibility settings.

A cross-platform toolkit can reproduce a similar appearance, but it cannot provide this automatic adoption. SwiftUI and AppKit also provide the native conventions expected for application menus, keyboard command validation, sheets, settings, focus and window restoration.

### They complement rather than replace each other

Apple officially supports both directions of integration: AppKit can host SwiftUI through `NSHostingView`, and SwiftUI can host AppKit through `NSViewRepresentable`.

The terminal viewport should not be a SwiftUI text grid. A persistent `NSView` gives Zigonaut direct control over:

- `NSTextInputClient` marked text, text commit and candidate-window geometry
- First-responder and keyboard behaviour
- VoiceOver and custom accessibility ranges
- Backing scale and display changes
- Native context menus, drag and drop, pasteboard and Services integration
- A `CAMetalLayer` or equivalent native Metal presentation surface

SwiftUI remains well suited to controls around that viewport. This split avoids forcing terminal identity, lifetime and input semantics through declarative view recreation.

### Ghostty proves the Zig integration model

Ghostty's current macOS application uses this same broad architecture: AppKit owns lifecycle and windows, SwiftUI composes terminal UI, an AppKit `NSView` hosts each terminal surface, and Swift calls a Zig core through opaque C handles and callbacks. Ghostty packages its Zig static library, C header and module map as an XCFramework for Xcode.

Zigonaut should reuse these architectural patterns, not Ghostty's private application internals. The `ghostty-vt` package consumed by Zigonaut exposes terminal parsing and state but does not expose Ghostty's PTY, session or Metal renderer.

## Options considered

| Option | Native fidelity | Zig integration | Advantages | Disadvantages | Decision |
| --- | --- | --- | --- | --- | --- |
| AppKit lifecycle + SwiftUI composition | Highest | Clean C ABI | Current system controls, complete Mac integration, proven by Ghostty | Requires Swift expertise and a macOS-specific renderer | **Choose** |
| Pure SwiftUI lifecycle + selective AppKit | High | Clean C ABI | Less initial AppKit code | Harder control over window teardown, responder behaviour and persistent terminal views | Do not use as the base lifecycle |
| AppKit only | Highest | Clean C ABI | Maximum control and maturity | More imperative UI code; slower work on settings and overlays | Use selectively under SwiftUI |
| Qt 6 | Medium–high | Requires a C++ shim | Mature menus, input and accessibility; strongest cross-platform alternative | Qt-styled controls, large runtime and packaging cost; no Windows UI reuse because WinUI remains | Reject for the stated goal |
| GTK 4/libadwaita | Low for macOS design | Direct C ABI | Mechanically straightforward FFI | GNOME design language and weaker Mac integration evidence | Reject |
| SDL/custom UI | Depends on custom work | Direct C ABI | Strong window/input/Metal primitives | Not a complete semantic UI toolkit; settings and accessibility become custom work | Use neither as the shell nor by default |

Qt becomes reasonable only if reducing macOS-specific frontend work matters more than top-tier Mac fidelity. Its normal cross-platform advantage is mostly absent because Zigonaut will retain WinUI.

## Current codebase findings

### Reusable foundations

- `src/app.zig` owns stable tab, pane and session identities, the pane tree, tab ordering and runtime retirement.
- `src/pane_tree.zig`, `src/search.zig`, `src/link.zig`, `src/shell_quote.zig` and most of `src/theme.zig` are suitable core components.
- `src/terminal.zig` provides Ghostty VT parsing, terminal input encoding and a renderer-neutral `RenderSnapshot` model.
- `src/session.zig` contains useful backpressure, coalesced refresh, search, render handoff and teardown logic.
- The existing WinUI bridge demonstrates successful use of C-compatible structures, pointer-and-length strings, callbacks and explicit lifetime rules.

### Portability blockers

- `build.zig` unconditionally creates a Windows subsystem executable, embeds Windows resources and links DirectWrite, Direct2D, D3D11 and Win32 libraries.
- `src/main.zig` combines the reusable model with Win32 messages, native child windows, the WinUI bridge and Windows integration.
- `src/app.zig` imports DirectWrite for tests and embeds Windows/WSL command construction policy.
- `src/session.zig` directly imports ConPTY and uses Windows mutexes, clocks, sleeps and `RtlWaitOnAddress`.
- `src/terminal.zig` uses a Windows Imaging Component PNG decoder and Win32 mutex.
- `src/config.zig` uses `%APPDATA%`, has Windows-only default profiles and contains Windows-specific appearance values.
- `src/terminal_view.zig` and the DirectWrite/GDI renderers are entirely Windows-specific.
- `src/chrome_bridge.zig` is a WinUI DLL contract containing `HWND`, swap-chain and `HRESULT` concepts. It should remain Windows-only rather than becoming the macOS ABI.

The migration is therefore an extraction and new-platform project, not merely a new shell.

## Proposed ownership boundaries

| Concern | Owner |
| --- | --- |
| Process/application lifecycle | AppKit |
| Native windows and optional AppKit window tab groups | AppKit |
| Tab and split presentation, settings and overlays | SwiftUI |
| Native terminal view identity | AppKit controller registry keyed by pane ID |
| Authoritative tabs, panes, stable IDs and committed split ratios | Zig app model |
| Terminal parser, search, selection and input encoding | Zig |
| PTY and subprocess lifecycle | Platform-specific Zig backend |
| Metal resources and frame encoding | Zig renderer |
| Layer/view attachment, scale and display reporting | AppKit terminal view |
| IME and accessibility protocol adaptation | AppKit, backed by bounded Zig queries |
| App bundle, resources, signing and notarization | Xcode |

Swift must project the Zig model by stable IDs rather than maintain a second source of truth. Swift may hold transient divider-drag state, but it should commit the final ratio to Zig.

## Proposed C ABI

Create a new embedded-core ABI rather than extending the WinUI bridge. Use:

- Opaque handles for process-wide core, window model and pane surface objects
- Explicit `create`, `quiesce`, `detach` and `destroy` functions
- Fixed-width integers, tagged structures and UTF-8 pointer/length pairs
- `size` and version fields on structures that may grow
- Status codes and caller-provided error buffers
- Stable `u64` IDs instead of pointers for tabs, panes and split nodes
- One thread-safe wake callback and an internal event queue
- Flat, generation-numbered model snapshots with one matching release operation

Do not expose Zig slices, error unions, allocators or Swift objects. Do not transfer terminal cells over the C ABI each frame. The Metal renderer should consume Zig-owned render snapshots within the Zig library.

The callback contract should be asymmetric:

1. Swift strongly owns the opaque core/window/surface handles.
2. Zig stores raw callback context only while the host is attached.
3. Worker threads enqueue effects and issue a lightweight wake callback.
4. Swift schedules a drain on the main actor and retrieves owned snapshots.
5. Destruction disables and drains callbacks before Swift releases their context.

## macOS PTY strategy

Implement a small Zigonaut-owned POSIX PTY backend. Ghostty does not publish a PTY API through `ghostty-vt`.

The backend needs:

- `openpty` with initial row and column size
- `IUTF8`, close-on-exec and terminal mode setup
- `setsid` and `TIOCSCTTY` for a controlling terminal
- Standard input, output and error attached to the slave
- Parent read/write through the PTY master
- `TIOCSWINSZ` resizing and `SIGWINCH`
- One child reaper and clear process-group ownership
- Bounded shutdown escalation and cancellation of blocked I/O

Avoid calling `fork` and non-async-signal-safe code after AppKit has become multithreaded. A small signed spawn helper, launched with `posix_spawn`, is the conservative production design if Darwin's public spawn actions cannot establish the complete controlling-terminal state.

## Staged delivery plan

### 1. Split the build graph

Keep the current Windows product intact. Add distinct portable-core tests and a macOS embedded-library product. Select products at the top of `build.zig` rather than scattering platform checks through UI modules.

**Exit condition:** Portable model and terminal tests compile on macOS without Win32, ConPTY or DirectWrite.

### 2. Extract platform seams

In order:

1. Synchronization, monotonic clock, sleep and generation waits
2. PTY spawn/read/write/resize/cancel/reap operations
3. Platform-normalized launch specifications using executable plus argument vector
4. OSC 7 local-path conversion
5. PNG decoding
6. Per-pane terminal geometry

Preserve the current render-handoff fairness and teardown ordering. Do not flatten ConPTY's staged destruction into the portable interface.

**Exit condition:** `app.zig`, `session.zig` and `terminal.zig` run against a fake PTY on both Windows and macOS.

### 3. Add the embedded C ABI

Build opaque core, window and surface handles, event delivery, model snapshots and explicit teardown. Add ABI layout tests before Swift depends on it.

**Exit condition:** A small C or Swift test can create a model, receive a wake, read a model snapshot and shut it down without callbacks after destruction.

### 4. Build the smallest useful macOS proof of concept

Build an unsigned local arm64 app with:

- AppKit application lifecycle and one window controller
- One `NSHostingView`
- One persistent `TerminalSurfaceView`
- One `/bin/zsh -l` session through the POSIX PTY
- Basic Metal/CoreText rendering for text, ANSI colours, background, cursor and selection
- Retina resizing, text commit, paste and scrolling
- Clean shutdown while output is active

The proof must validate `stty size`, Unicode and combining text, backing-scale changes, sustained output and child cleanup. A Swift text grid would validate the wrong boundary.

### 5. Add complete desktop behaviour

Add tabs, splits, focus, search, marked-text IME, keyboard layout handling, VoiceOver, clipboard confirmation, links, drag and drop, notifications, settings and restoration. Keep persistent native views in a registry rather than creating a new Zig surface during SwiftUI recomputation.

### 6. Package and harden

Produce development and universal-release XCFramework slices. Let Xcode own the final application bundle, hardened runtime, signing, notarization, assets and tests. Keep Windows packaging independent.

## Deployment strategy

Build against the latest macOS SDK to receive current SwiftUI/AppKit design automatically. Treat **macOS 14** as a provisional minimum for the first proof and revisit it before beta based on Intel support and audience data.

Newer appearance APIs should be isolated in Swift with availability checks. Modern fidelity comes primarily from standard controls and the latest SDK, not from requiring the newest operating system for the entire core.

The Mac App Store should not be assumed. A terminal must launch arbitrary shells and developer tools, which conflicts with normal App Sandbox constraints. Plan first for a signed and notarized direct-download application unless a separate sandbox feasibility study supports another route.

## Main risks

1. **Metal/CoreText renderer scope**: `ghostty-vt` does not include Ghostty's renderer. Text shaping, fallback, colour glyphs, atlas management, images and frame pacing form the largest new subsystem.
2. **Lifetime errors**: PTY callbacks, render callbacks and Swift object destruction must preserve Zigonaut's current detach-before-retire invariant.
3. **Model duplication**: Independent Swift and Zig tab/split models will drift.
4. **IME and accessibility debt**: A custom terminal surface needs these protocols in its initial design, even if the proof implements them incrementally.
5. **Process spawning**: A raw post-launch `fork` path can be unsafe in a multithreaded AppKit process.
6. **Per-pane sizing**: The current single terminal-size assumption must become per-surface geometry before splits are complete.
7. **Build recursion and signing**: Zig and Xcode need one-way orchestration and matching architectures and deployment targets.
8. **Platform-specific configuration**: Windows defaults and Mica/acrylic concepts cannot leak into the Mac UI or default profiles.

## Decisions needed before implementation

- Minimum macOS version and whether Intel is supported at first release
- Direct download only or a future Mac App Store objective
- Whether the first milestone is only architectural proof or a user-testable single-pane terminal
- Whether macOS and Windows share one configuration file schema with platform-specific fields or expose separate platform views over a common subset
- Whether renderer parity is required before beta, especially Kitty images, colour glyphs and fallback behaviour

## References

- [Apple: AppKit integration with SwiftUI](https://developer.apple.com/documentation/swiftui/appkit-integration)
- [Apple: Integrating AppKit](https://developer.apple.com/tutorials/app-dev-training/integrating-appkit)
- [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Apple: Liquid Glass overview and WWDC sessions](https://developer.apple.com/documentation/technologyoverviews/liquid-glass)
- [Ghostty C embedding API](https://github.com/ghostty-org/ghostty/blob/main/include/ghostty.h)
- [Ghostty embedded Zig runtime](https://github.com/ghostty-org/ghostty/blob/main/src/apprt/embedded.zig)
- [Ghostty macOS sources](https://github.com/ghostty-org/ghostty/tree/main/macos/Sources)
- [Ghostty PTY implementation](https://github.com/ghostty-org/ghostty/blob/main/src/pty.zig)
