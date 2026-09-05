# Research: idle scrollback compression

**Date:** 2026-09-05
**Question:** Can Monstar-style idle compression reduce Zigonaut's history memory on Windows and macOS?
**Status:** Implemented on macOS; unsupported by libghostty on Windows.

## Findings

The public `ghostty_terminal_compression_activity` and
`ghostty_terminal_compress` APIs exist in both Zigonaut's committed Ghostty
revision and the locally updated dependency. No dependency change is required.

The activity token is opaque: only equality comparisons are meaningful.
Incremental compression performs bounded work and returns pending, complete or
unsupported. It changes storage representation, not terminal contents or the
history limit. Access restores compressed history transparently. All terminal
access, including compression, must use the same lock.

Actual memory reclamation is supported on 64-bit Darwin and Linux, but not
Windows. Scheduling Windows calls would do no useful work. Adding a Windows
reclamation backend belongs upstream and is outside this port.

## Measurement

A temporary C probe linked the current debug `libzigonaut-core.dylib` and used
its libghostty C exports. It created a 120-column, 24-row terminal with the same
50,000,000-byte limit as Zigonaut and a 10,000-line limit. It fed 10,000 numbered
log records, then called incremental compression until complete:

```text
00000 INFO request completed status=200 route=/api/items elapsed=12ms rows=42
```

Mach `TASK_VM_INFO.phys_footprint`, measured within the probe process:

| Measurement | Result |
| --- | ---: |
| Before compression | 13,009,256 bytes |
| After compression | 2,965,864 bytes |
| Physical footprint reduction | 10,043,392 bytes (about 77%) |
| Incremental calls | 29 |
| Longest call | 608,000 ns (0.61 ms) |
| Total compression CPU-side elapsed time | 11,265,541 ns (11.27 ms) |

This is one synthetic log workload, not a guarantee of whole-application
savings or latency. Virtual address space is deliberately retained, so virtual
size and ordinary allocator-free counters would misrepresent the benefit.

## Implementation

- macOS refreshes schedule maintenance on the existing serial background queue.
- The core observes the activity token and waits 250 ms after a change.
- Each pending incremental step schedules the next call after 1 ms.
- A busy terminal lock postpones compression for 250 ms instead of blocking.
- Completed passes stop scheduling. A later refresh checks for new activity.
- Generation checks invalidate superseded delayed jobs. Queued work retains the
  existing core handle, and stopping cores reject maintenance.
- Compression never requests a redraw or changes scrollback limits.

Tests cover idle/restart/completion timing, lock contention, teardown, C ABI
availability, and selection, search and viewport access after compressing cold
history. Windows remains unchanged apart from the portable API wrappers.

## References

- [Monstar idle compression](https://github.com/rockorager/monstar/commit/6a8f1748591a14d3015ce2a0eb5df82a9a6973b8)
- [Committed dependency API](https://github.com/ghostty-org/ghostty/blob/da5ddcb0857c0e4ddb32f7a089911e9038d040f3/include/ghostty/vt/terminal.h)
- [Locally updated dependency API](https://github.com/ghostty-org/ghostty/blob/c81f0b26871c7fbbe2fc35549fdad1f64ed29094/include/ghostty/vt/terminal.h#L2223-L2274)
- [Platform reclamation support](https://github.com/ghostty-org/ghostty/blob/c81f0b26871c7fbbe2fc35549fdad1f64ed29094/src/terminal/mem.zig)
