# Measuring interactive scroll stalls

Zigonaut exposes the Windows scroll pipeline through the manifest-free ETW provider `Zigonaut.Scroll` (`B0B70986-9D2A-4B52-A8CC-693BF873D56B`). The provider is dormant when no ETW session enables it.

## Capture a trace

Build an optimized executable with debug information, then open an elevated PowerShell prompt:

```powershell
zig build -Doptimize=ReleaseSafe -Ddebug-info=true
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\docs\performance\capture-scroll.ps1 `
  -Executable .\zig-out\bin\zigonaut.exe
```

`-ExecutionPolicy Bypass` applies only to this PowerShell process. It does not change the machine or user execution policy.

In Zigonaut, produce a fixed transcript and wait until output has stopped. Use the same window size, DPI, font and scrollback size between captures. Scroll quickly until the pause occurs, immediately return to the capture prompt and press Enter. Keep the capture under 30 seconds where possible.

For a timed provider-only confirmation trace, which omits CPU and GPU data, add `-EventsOnly -DurationSeconds 20`. The trace saves automatically when the interval ends.

The script intentionally refuses to cancel an existing WPR session. Stop or save that session before retrying.

## Analyze the trace

Open `zigonaut-scroll.etl` in Windows Performance Analyzer (WPA):

1. Add **Generic Events**, **CPU Usage (Sampled)**, **CPU Usage (Precise)** and **GPU Utilization** to the analysis view.
2. Filter Generic Events to provider `B0B70986-9D2A-4B52-A8CC-693BF873D56B`.
3. Expand the event message column and correlate by `pane`, `request` and `wait_id`.
4. Select a visible pause in Generic Events, then inspect CPU stacks and thread wait states over exactly that interval.

The event sequence is:

```text
ScrollInput -> RenderInvalidated -> FrameWaitArmed
    -> CaptureStarted -> CaptureLockAcquired -> CaptureCompleted
    -> FrameWaitCompleted -> PaintStarted -> RenderPath -> PaintCompleted
    -> PresentSucceeded
       or PresentRetry ... -> PresentSucceeded
       or PaintFailed
```

`RenderPath.path` is `0` for dirty-row replay, `1` for a full replay and `2` for a shifted scene. `FrameWaitCompleted.outcome` is `0` for prepared, `1` for synchronized output, `2` for failure and `3` for timeout. `PaintCompleted.present_result` is `0` for success and `1` when DXGI requires a retry. `PaintFailed.error` is `1` for begin-frame, `2` for scene-shift, `3` for cell-draw, `4` for row-end, `5` for image-draw, `6` for built-in glyph draw and `7` for end-frame failure; `0` is another error. For an end-frame failure, `detail` packs the native stage into bits 56–63 (`1` glyph flush, `2` Direct2D EndDraw, `3` scene transfer, `4` DXGI Present), the Direct2D command tag into bits 32–39, the command subtype into bits 40–55 and the HRESULT into its low 32 bits. Command tags are `1` frame setup, `2` clear, `3` row, `4` built-in glyph, `5` image, `6` cursor, `7` IME preedit, `8` cell decoration, `9` row clip, `10` row glyph, `11` row built-in glyph, `12` row sprite batch and `13` row strikethrough. Row-glyph subtypes are `1` colour and `2` newly shaped monochrome.

Interpret common signatures as follows:

- Repeated `PresentRetry` events whose `delay_ms` grows towards 250 ms indicate compositor or GPU backpressure amplified by retry backoff.
- A long `FrameWaitArmed` to `FrameWaitCompleted` interval with little CPU activity indicates frame-latency wait or compositor delay.
- A large `CaptureLockAcquired.wait_ns` indicates contention with terminal parsing or another terminal-state reader.
- A long `CaptureStarted` to `CaptureCompleted` or `PaintStarted` to `PaintCompleted` interval with busy CPU is suitable for CPU stack or flamegraph analysis.
- `PaintFailed` followed by renderer reinitialization identifies a Direct2D failure rather than frame pacing; use its error code to locate the failed rendering stage.
- Many `ScrollInput`/`RenderInvalidated` events with `already_dirty=1` before one paint show deliberate frame coalescing, not missing input.

For displayed-frame timing, run PresentMon during the same reproduction and align its timestamps with the ETL. The ETW `PresentSucceeded` event marks submission; PresentMon distinguishes submission delays from DWM/display delays.
