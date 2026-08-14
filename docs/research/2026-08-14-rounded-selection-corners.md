# Research: Rounded Selection Corners

**Date**: 2026-08-14
**Question**: What would it take to give Zigonaut's terminal selections subtly rounded outside and inside corners?
**Status**: Complete

## Context

Selections are currently rendered as cell-aligned rectangles. Slight rounding would make single-line and multi-line selections feel less mechanical, but a correct multi-line result is not a rounded rectangle per cell or even per row. It is one orthogonal silhouette whose convex outer corners and concave row-transition corners are rounded.

This investigation covers the normal macOS renderer, the Windows Direct2D renderer, retained/incremental redraw behaviour, and the Windows GDI fallback. It does not propose changing selection semantics, colours, or input handling.

## Findings

### Selection data is already sufficient, but only at cell granularity

Ghostty exposes at most one inclusive selected interval for each rendered row. `Terminal.renderViewportInternal` converts that interval into `Cell.selected` while visiting cells. `RenderSnapshot` retains those cells and replays them to platform renderers.

No selection model or Ghostty change is needed. The missing information is rendering topology: a renderer processing row `y` needs the selected intervals for `y - 1`, `y`, and `y + 1` to know whether each corner is external, internal, or joined to the next row.

Relevant ownership:

- `src/shared/terminal.zig:63-88` defines the renderer-neutral cell, including `selected`.
- `src/shared/terminal.zig:1370-1458` obtains the row interval and marks selected cells.
- `src/shared/terminal.zig:320-387` incrementally captures rows and hashes retained cell content.
- `src/shared/terminal.zig:534-557` replays full or dirty snapshots one row at a time.

### Per-cell or per-row rounded rectangles are the wrong shape

Rounding every selected cell would create scalloped seams. Rounding each row run would still leave gaps or bumps where adjacent selected rows join and would not produce concave rounding at different line starts and ends.

The suitable shape is a path around the union of selected row intervals. At every horizontal step, two short quadratic curves replace the square transition. For a concave corner, the curve should cut slightly farther into the selected area rather than add highlight colour to the unselected notch. This keeps the rounded shape a subset of the existing rectangular selection and avoids inventing a colour for pixels outside selected cells.

Zed uses this same approach for both editor and terminal selections: one interval per visual row, quadratic curves at width transitions, and a radius of `0.15 × line height`. It caps horizontal curve width at half the step length and splits non-overlapping adjacent intervals to avoid self-intersecting paths.

### Preserve current colours by clipping, not replacing, selection fills

On macOS, a selected cell currently swaps its foreground and background: `TerminalSurface.drawBackground` fills the cell with its original foreground, while `textStyle` uses its original background for text. Selection fill colour can therefore vary from cell to cell. Windows normally uses the uniform system highlight colours, but copy-flash and high-contrast paths also affect the result.

The rounded implementation should:

1. Preserve or restore the cell's ordinary background beneath the selected fill, so rounded cut-outs reveal the correct terminal background rather than always the frame default.
2. Build a rounded selection clip for the current row from the previous/current/next selected intervals.
3. Draw the existing per-cell selection backgrounds through that clip.
4. Draw text and decorations without the selection clip, preserving glyph coverage at the rounded corners.

Search highlights currently take precedence over selection colour. They should remain independently rectangular rather than silently changing search-highlight semantics.

### macOS is local and straightforward

`TerminalRenderSnapshot.cellsByRow` already retains every visible row. Both the AppKit fallback and Metal retained renderer ultimately rasterize backgrounds through `TerminalSurface`:

- `macos/Sources/TerminalSurface.swift:854-872` draws the complete AppKit scene.
- `macos/Sources/TerminalSurface.swift:1328-1345` redraws selected rows into the Metal retained bitmap.
- `macos/Sources/TerminalSurface.swift:1398-1415` computes cell rectangles and fills backgrounds.
- `macos/Sources/Models.swift:622-653` retains row-local cells and row hashes.

A small pure geometry helper belongs in `macos/RenderSupport`, where it can emit testable line/curve commands without depending on AppKit. `TerminalSurface` can convert those commands to `CGPath`/`NSBezierPath` and clip selected fills.

The Metal path needs one additional correctness change: when a selected interval changes, the rows immediately above and below may need repainting even if their cells did not change, because their joining corner changed.

### Windows needs a narrow shared-renderer contract extension

The Windows renderer uses a retained Direct2D scene and normally replays only dirty rows:

- `src/windows/terminal_view.zig:1385-1435` chooses full, shifted, or dirty snapshot replay.
- `src/windows/terminal_view.zig:2183-2225` begins each DirectWrite row.
- `src/windows/terminal_view.zig:2228-2317` resolves selected colours and submits cells.
- `src/windows/directwrite_renderer.cpp:1390-1414` coalesces adjacent background rectangles.
- `src/windows/directwrite_renderer.cpp:1505-1531` tracks and flushes a row background run.

The simplest cross-platform seam is an optional renderer callback carrying a `SelectionContext` immediately before `beginRow`: the selected interval above, on, and below the row. `RenderSnapshot` can derive these intervals from retained cells; terminal traversal and selection APIs remain unchanged.

The Zig/C++ DirectWrite bridge would then add:

- row selection context passed at `beginRow`;
- one boolean on submitted backgrounds indicating that the fill is the selection layer, preventing coalescing with a same-coloured ordinary background;
- a small antialiased Direct2D path/layer clip around selection background runs;
- unchanged, unclipped text drawing afterward.

This keeps geometry out of input/model code and preserves the recent adjacent-background coalescing optimization for non-selection backgrounds.

### Dirty-row topology is the subtle shared requirement

Current hashes describe one row's cells. Rounded joins make row `y` visually dependent on selection state in `y - 1` and `y + 1`. Without accounting for that dependency, extending a drag into a new row can leave stale square or rounded corners in both retained renderers.

`RenderSnapshot.Row` should retain its selected interval. During capture:

1. Snapshot old intervals.
2. Rebuild Ghostty-dirty rows and derive their new intervals.
3. Detect which intervals changed.
4. Mark each changed row and its immediate neighbours dirty.
5. Include the three-row selection context in the affected row hashes.

Do not expand every ordinary dirty row; doing so would turn routine one-row terminal output into three-row redraws. Expand only around an actual selection-interval change. The same context-aware base hashes then make macOS's visual hashes and Windows's dirty/shifted replay coherent.

### Radius and edge policy

A good initial radius is `0.15 × line height`, capped at about one quarter of cell width and half of the adjacent edge segment. This generally produces 2–3 pixels/DIPs at normal terminal sizes: visible but subtle. It should scale with backing scale/DPI and should not initially be a user preference.

Viewport clipping should remain authoritative. A selection continuing above or below the visible viewport should join the clipped edge rather than look like a deliberately rounded endpoint if off-screen neighbour information is available; with viewport-only data, treating the edge as clipped/square is the least misleading fallback.

Wide cells should use column boundaries from the selected interval, not glyph bounds. Rectangular selection naturally becomes one rounded rectangle with only four outside corners because adjacent rows have identical intervals.

### GDI and high contrast should retain square selection initially

The GDI fallback combines opaque background and text in `ExtTextOutW`, making antialiased background-only clipping disproportionately invasive. It is a recovery renderer, and GDI does not offer equivalent antialiased path filling without adding GDI+ or a software mask.

Leave GDI selections square in the first implementation. Also consider deliberately disabling rounding in Windows high-contrast mode so the system highlight keeps full cell coverage. This is a graceful-degradation choice, not a blocker for the normal hardware-accelerated renderer.

## Options Considered

| Option | Pros | Cons | Effort |
|--------|------|------|--------|
| Round every selected cell | Tiny local change | Visually wrong; scalloped interior seams | Small |
| Round each selected row independently | Easy to batch | Gaps/bumps between rows; no proper inside corners | Small |
| Build platform-local full paths with no shared topology | Good macOS result | Windows cannot safely infer the next row during incremental replay; duplicated dirty logic | Medium |
| Add shared row selection context, then clip existing fills with platform paths | Correct outer/inner corners; preserves colours and retained rendering | Touches shared snapshot plus Swift and Zig/C++ renderer seams | **Medium; recommended** |
| Replace all selection fills with one uniform rounded path | Simplest geometry | Changes macOS reverse-video colour behaviour and copy-flash details | Medium |

## Recommendation

Implement the shared selection-context contract and context-aware dirty propagation first, with pure tests. Then implement row-local rounded path clips in macOS Core Graphics and Windows Direct2D. Keep the radius fixed and subtle, preserve existing fill/text colour resolution, and leave GDI/high-contrast selection square.

Suggested implementation sequence:

1. Add `SelectionRange`/`SelectionContext` derivation to `Terminal.RenderSnapshot` and tests for single-line, multi-line, rectangular, non-overlapping, moved, and cleared selections.
2. Mark only changed selection rows and their neighbours dirty; test dirty replay and shifted replay hashes.
3. Add a pure macOS `SelectionShape` command builder in `RenderSupport`, with geometry tests, and use it in both AppKit and retained Metal background rasterization.
4. Extend the DirectWrite bridge with row context and selection-background identity; clip only selection fills using an antialiased path/layer.
5. Add native Windows geometry/pixel tests and manually inspect 100%, 150%, and 200% DPI.

Expected implementation size is roughly 350–600 lines across shared Zig, Swift, Zig/C++ bridge code, and tests. A macOS-only prototype is about half to one day. A production-quality macOS + Direct2D implementation, including retained-render correctness, tests, and visual tuning, is approximately two to four engineering days. Supporting antialiased GDI parity would add meaningful work and is not recommended.

## Open Questions

- Should selection endpoints at the top/bottom viewport edge be square (explicitly clipped) or rounded (visible-fragment treatment)? Square is recommended.
- Should high-contrast mode opt out on macOS as well, or only Windows where system highlight semantics are explicit?
- Is exact corner parity between macOS and Windows required, or is matching radius/topology sufficient while each platform uses its native curve rasterizer?

## References

- `src/shared/terminal.zig`
- `src/macos/core.zig:724-790`
- `macos/Sources/Models.swift:622-653`
- `macos/Sources/TerminalSurface.swift:854-872, 1328-1345, 1398-1415, 1529-1538`
- `src/windows/terminal_view.zig:1385-1435, 2183-2317`
- `src/windows/directwrite_renderer.cpp:1390-1414, 1505-1531, 1954-1983`
- [Zed `HighlightedRange::paint_lines`](https://github.com/zed-industries/zed/blob/main/crates/editor/src/element.rs#L10521-L10632)
- [Zed terminal selection painting](https://github.com/zed-industries/zed/blob/main/crates/terminal_view/src/terminal_element.rs#L1681-L1700)
