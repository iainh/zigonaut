#pragma once

#include <stdint.h>
#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum ZigonautScrollTraceEvent {
    ZIGONAUT_SCROLL_TRACE_INPUT = 1,
    ZIGONAUT_SCROLL_TRACE_INVALIDATED,
    ZIGONAUT_SCROLL_TRACE_FRAME_WAIT_ARMED,
    ZIGONAUT_SCROLL_TRACE_FRAME_WAIT_COMPLETED,
    ZIGONAUT_SCROLL_TRACE_CAPTURE_STARTED,
    ZIGONAUT_SCROLL_TRACE_CAPTURE_LOCK_ACQUIRED,
    ZIGONAUT_SCROLL_TRACE_CAPTURE_COMPLETED,
    ZIGONAUT_SCROLL_TRACE_PAINT_STARTED,
    ZIGONAUT_SCROLL_TRACE_RENDER_PATH,
    ZIGONAUT_SCROLL_TRACE_PAINT_COMPLETED,
    ZIGONAUT_SCROLL_TRACE_PAINT_FAILED,
    ZIGONAUT_SCROLL_TRACE_PRESENT_RETRY,
    ZIGONAUT_SCROLL_TRACE_PRESENT_SUCCEEDED,
} ZigonautScrollTraceEvent;

void zigonaut_scroll_trace_register(void);
void zigonaut_scroll_trace_unregister(void);
BOOL zigonaut_scroll_trace_enabled(void);
void zigonaut_scroll_trace_write(
    ZigonautScrollTraceEvent event,
    uint64_t pane_id,
    uint64_t request_id,
    int64_t value1,
    int64_t value2);

#ifdef __cplusplus
}
#endif
