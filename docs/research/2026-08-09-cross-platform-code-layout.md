# Research: Cross-platform code layout

**Date**: 2026-08-09
**Question**: How should Zigonaut organize its macOS and Windows clients so future integration and parity work stays orderly?
**Status**: Complete; migration sequencing and shared-behaviour scope need approval

## Context

Zigonaut now has two native clients with intentionally different ownership models:

- Windows runs a Zig application and session model, then loads a C++/WinRT WinUI shell through a C ABI.
- macOS runs an AppKit and SwiftUI application, then embeds one Zig terminal and POSIX pseudoterminal core per pane through a separate C ABI.

This asymmetry is valid. Windows and macOS have different lifecycle, tab, window, process-launch, rendering and settings conventions. The current repository layout hides that distinction because portable Zig modules, Windows-only Zig modules and macOS-only Zig modules all occupy the flat `src/` directory.

The goal should be a **shared terminal kernel with two native clients**, not one artificial cross-platform desktop application layer.

## Findings

### The build already separates native products correctly

`build.zig` selects a separate macOS graph before constructing Windows resources, C++ sources or system-library links. The macOS graph builds a dynamic Zig core and PTY helper, then invokes SwiftPM and assembles an application bundle. The Windows graph builds the Zig executable and invokes MSBuild to deploy the WinUI shell.

This product split is a sound foundation. It should remain explicit rather than being replaced with platform checks scattered through application modules.

One correction is needed before other targets are considered: the current top-level branch is effectively “macOS, otherwise Windows.” It should explicitly accept Windows and macOS, then reject unsupported operating systems.

### The genuinely portable Zig surface is small and coherent

These files contain platform-neutral terminal semantics or value types:

| File | Shared responsibility | Qualification |
| --- | --- | --- |
| `src/terminal.zig` | Ghostty VT state, input encoding and renderer-neutral snapshots | Windows Imaging Component PNG decoding still leaks through a compile-time Windows hook |
| `src/search.zig` | Search state, navigation and row matching | Pure |
| `src/link.zig` | Link detection and allowed-scheme policy | Pure |
| `src/theme.zig` | Theme values, parsing, overrides and colour randomization | `Catalog.load` also owns Windows-style executable-relative resource discovery |
| `src/pane_tree.zig` | Stable tree IDs, split mutation and normalized geometry | Pure, though only Windows currently consumes it |

`src/platform_sync.zig` is cross-target support code rather than application semantics. Its non-Windows mutex spins while waiting, so it should not become a broadly used shared-domain primitive without reviewing lock duration and replacing it with blocking synchronization where appropriate.

### Most of the flat Zig source directory is Windows-specific

The following modules belong to the Windows client as written:

- `main.zig` owns Win32 process and window orchestration, WinUI startup and native terminal-view lifetime.
- `app.zig` owns useful tab and pane records but imports Windows configuration, session and renderer modules. It also contains WSL and Windows command-line policy.
- `session.zig` owns ConPTY, Win32 synchronization, worker retirement and Windows OSC 7 path conversion.
- `terminal_view.zig`, `input.zig`, `directwrite_renderer.*` and `gdi_renderer.zig` own HWND, DirectWrite, GDI, Windows input, clipboard and accessibility behaviour.
- `config.zig`, `pty.zig`, `shell_quote.zig`, `chrome_bridge.zig` and `win32.zig` contain direct Windows policy or APIs.
- `benchmark.zig`, `conpty_resize_test.zig` and the current `tests.zig` root build against the Windows stack.

In particular, `app.zig` is not a ready-made common application model. Making it shared would first require removing Windows session creation, shell metadata, WSL rewriting and DirectWrite coupling. The remaining common functionality would overlap heavily with the already portable `pane_tree.zig`.

### The macOS client has a clear but concentrated boundary

`src/macos_core.zig` combines four responsibilities in 1,556 lines:

1. The exported Swift-facing C ABI and structure marshaling
2. POSIX PTY ownership, reader and writer workers and synchronization
3. Terminal operations such as input, search, selection and snapshots
4. macOS virtual-key translation and host effects

`macos/Sources/Models.swift` similarly combines preferences, C ABI ownership, render marshaling, terminal state and pane/window state in 1,156 lines. `TerminalSurface.swift` combines input, IME, accessibility and rendering in 1,166 lines. These are more important future decomposition candidates than adding deeper folder nesting immediately.

The Swift `PaneNode` and `WindowModel` should not be replaced merely to match Windows. They intentionally support native AppKit window tabs, UUID restoration, SwiftUI presentation and frame-based focus. Windows has different IDs, close/focus rules, runtime ownership and WinUI layout synchronization.

### The ABIs are client-specific and should stay that way

`winui/bridge.h` describes the contract between the Zig Windows application and its WinUI DLL. It includes HWNDs, swap chains, IME, taskbar, accessibility and chrome concepts. The WinUI project should continue to own it.

`macos/include/zigonaut_core.h` describes the Swift-to-Zig terminal/session contract. It should remain the canonical macOS foreign-function interface and stay scoped to opaque terminal handles. AppKit windows, Swift panes and preferences should not cross this ABI.

The macOS ABI records are currently duplicated as C declarations in the header and `extern struct` declarations in `macos_core.zig`. Version and size fields reduce risk, but automated size, alignment and offset checks are still needed. The header also needs complete ownership, callback-thread, retry-buffer and teardown documentation.

### Themes are shared assets but settings are native policy

The root `themes/` directory is already the right canonical asset source. Both build graphs package it in platform-appropriate locations. However:

- `theme.Catalog.load` assumes a directory beside the executable.
- macOS hard-codes the available theme names even though it packages the JSON files.
- Rasmus fallback values are independently represented in Zig, Swift and C++.
- The Windows settings UI independently parses and writes the JSON schema that `config.zig` also parses and validates.

Shared code should parse theme files supplied by each host; it should not decide where a native bundle stores them. macOS can enumerate bundle resources rather than maintain a name list.

Configuration persistence should remain native. Windows profiles, ConPTY commands, Mica and Explorer integration do not map cleanly to macOS login shells, materials and `UserDefaults`. Share only explicit terminal-level semantics such as palette values, scrollback limits and clipboard-write policy. Do not introduce one persistence format solely for symmetry.

## Recommended target layout

The first useful boundary is `shared`, `windows` and `macos`. Avoid deeper `model`, `service`, `controller` and `adapter` folders until a file has a coherent responsibility to extract.

```text
src/
  shared/
    terminal.zig
    search.zig
    link.zig
    theme.zig
    pane_tree.zig

  support/
    platform_sync.zig

  windows/
    main.zig
    app.zig
    session.zig
    terminal_view.zig
    config.zig
    pty.zig
    input.zig
    shell_quote.zig
    chrome_bridge.zig
    win32.zig
    directwrite_renderer.zig
    directwrite_renderer.cpp
    directwrite_renderer.h
    glyph_atlas_allocator.h
    gdi_renderer.zig
    benchmark.zig
    conpty_resize_test.zig
    tests.zig

  macos/
    core.zig
    pty_helper.zig

winui/                       # Native Windows C++/WinRT project and its ABI
macos/                       # Native Swift package, resources, tests and C ABI
themes/                      # Canonical cross-platform theme assets
assets/                      # Shared source branding; platform outputs remain native
installer/                   # Windows packaging
```

Keeping `winui/` and `macos/` as build-system roots is pragmatic. Their native tools expect different project structures. Renaming both under a cosmetic `clients/` parent would create churn without improving module ownership.

```text
┌──────────────────────────┐       ┌──────────────────────────┐
│ macOS native client      │       │ Windows native client    │
│ AppKit + SwiftUI         │       │ WinUI + Win32 Zig app    │
│ native lifecycle/state   │       │ native lifecycle/state   │
└────────────┬─────────────┘       └────────────┬─────────────┘
             │ macOS C ABI                      │ WinUI C ABI
             ▼                                  ▼
┌──────────────────────────┐       ┌──────────────────────────┐
│ macOS Zig session host   │       │ Windows Zig session host │
│ POSIX PTY + host effects │       │ ConPTY + host effects    │
└────────────┬─────────────┘       └────────────┬─────────────┘
             └──────────────┬───────────────────┘
                            ▼
                 ┌─────────────────────┐
                 │ Shared Zig kernel   │
                 │ terminal/search/    │
                 │ links/themes/values │
                 └─────────────────────┘
```

## Migration plan

### Stage 1: Make boundaries testable before moving files

1. Add explicit `test-shared`, `test-windows`, `test-macos-core` and `test-macos-ui` entry points. Keep `test` as a host-supported aggregate.
2. Make the top-level OS selection explicit and fail unsupported targets.
3. Add macOS C ABI structure layout and symbol checks, plus a minimal C consumer that includes the public header.
4. Add common fixtures for theme parsing and any pane-tree semantics that both clients are expected to honour.
5. Record a capability matrix that labels behaviour as shared terminal semantics, expected platform parity or intentionally native.

**Stopping point:** No runtime behaviour or file locations change, but subsequent extraction and relocation become reviewable.

### Stage 2: Purify shared modules in place

1. Split theme parsing and values from platform resource discovery. Pass a platform-selected theme directory or contents into the parser.
2. Move Windows PNG decoding out of `terminal.zig` behind a narrow process-level host hook.
3. Keep synchronization under support code and replace the macOS spinning mutex before increasing its use.
4. Extract from `app.zig` only when a concrete cross-client behaviour needs it. Do not build a speculative generic app or session factory.

**Stopping point:** Every proposed `shared/` module compiles in both build graphs without importing Win32, ConPTY, AppKit or Swift concepts.

### Stage 3: Relocate modules mechanically

Move the files into the target tree and update imports and build roots without changing runtime behaviour. Preserve Windows detach-before-session-retirement order and macOS callback draining exactly. Keep this move separate from renderer, PTY, settings and model redesign.

**Stopping point:** The repository structure truthfully communicates ownership while both products behave as before.

### Stage 4: Decompose concentrated platform files as features touch them

Use responsibility boundaries rather than line count alone:

- Split macOS C ABI marshaling from the POSIX session host.
- Split Swift preferences, terminal bridge state and workspace state out of `Models.swift`.
- Split AppKit input/accessibility from retained rendering when either area next changes substantially.
- Split WinUI window/chrome, pane hosting and system integrations out of `bridge.cpp`.
- Move Windows settings schema mutation behind Zig before the next schema revision, or at minimum add round-trip fixtures shared by Zig and C++.

**Stopping point:** Each extraction must reduce a real coupled change set. Do not pre-create empty layers.

### Stage 5: Remove parity drift opportunistically

1. Make all packaged JSON themes discoverable on both clients.
2. Add `rasmus.json` or otherwise establish one tested canonical fallback palette.
3. Test normalized terminal settings across clients while retaining native storage and UI.
4. Share additional policy only after identical behaviour is a product requirement.

## Options considered

| Option | Advantages | Disadvantages | Decision |
| --- | --- | --- | --- |
| Shared terminal kernel and two native clients | Reflects current architecture; preserves native behaviour; supports targeted parity | Some app behaviour remains intentionally duplicated | **Choose** |
| One shared Zig app/window/pane model | One apparent source of truth | Forces unlike tab, restoration, launch and lifecycle semantics through platform branches | Reject unless a future feature proves the need |
| Move files immediately without extracting seams | Fast visual cleanup | Labels impure modules as shared and creates noisy import churn before tests protect boundaries | Defer until Stages 1–2 |
| Keep the flat `src/` tree | No migration cost | Ownership remains unclear and platform coupling will spread as parity work increases | Reject |
| Put all native projects under `clients/` | Superficially symmetric | Churns SwiftPM, MSBuild, scripts and packaging without improving code boundaries | Do not prioritize |

## Coupling risks

1. **Native view and runtime lifetime:** Windows must detach and destroy pane presentation before retiring its session runtime.
2. **Callback teardown:** Both platform hosts wake native UI from worker threads. Shared callback vocabulary must not hide callback-context lifetime or draining.
3. **Launch semantics:** WSL `--cd`, Windows quoting, ConPTY handles, POSIX login shells and the macOS helper are platform policy, not one generic command string.
4. **Pane semantics:** ID types, ratios, close-focus choices, directional focus and restoration differ despite both clients using split trees.
5. **Resource location:** Shared code may parse themes, but each host must locate its executable or application-bundle resources.
6. **Configuration ownership:** Windows `Config` contains borrowed slices owned by `Loaded`; future settings snapshots must establish explicit ownership.
7. **Global decoder hooks:** Ghostty image decoding is process-level setup, not mutable per-session configuration.
8. **Test meaning:** A platform-dependent `test` target can look comprehensive while exercising different module sets on each host.

## Anti-goals

- No common application lifecycle, event loop, native window, tab view, terminal view, renderer, accessibility layer or settings UI.
- No app-level panes, windows or preferences in the macOS C ABI.
- No platform enum threaded through otherwise portable modules.
- No shared configuration file introduced only to make the clients look symmetric.
- No bulk file move combined with behaviour changes.
- No replacement of Swift `PaneNode` with Zig `pane_tree` without a concrete feature requiring identical semantics.
- No one-use wrappers or empty architecture folders created in anticipation of future work.

## Recommended first deliverable

Implement Stages 1–3 as separate reviewable changes:

1. Test and ABI boundary hardening
2. Shared-module purification
3. Mechanical source relocation

This yields an orderly repository without committing either native client to the other client’s model. Configuration consolidation and large-file decomposition should follow as independent, behaviour-focused changes.

## Open questions

- Which user-visible behaviours must have exact cross-platform parity, rather than platform-appropriate equivalents?
- Should `pane_tree.zig` remain a portable utility used only by Windows, or is identical pane mutation/restoration a future product requirement?
- Should Windows settings mutation move into Zig before the next configuration-schema version?
- Is a standalone shared-kernel test expected to run on every continuous integration host, including hosts that cannot build either native shell?

## References

- `build.zig`
- `src/terminal.zig`
- `src/search.zig`
- `src/link.zig`
- `src/theme.zig`
- `src/pane_tree.zig`
- `src/app.zig`
- `src/session.zig`
- `src/macos_core.zig`
- `macos/include/zigonaut_core.h`
- `macos/Sources/Models.swift`
- `macos/Sources/TerminalSurface.swift`
- `winui/bridge.h`
- `winui/bridge.cpp`
- `winui/settings_dialog.cpp`
