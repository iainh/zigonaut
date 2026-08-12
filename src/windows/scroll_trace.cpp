#include "scroll_trace.h"

#include <evntrace.h>
#include <evntprov.h>
#include <stdio.h>

// Zigonaut.Scroll: {B0B70986-9D2A-4B52-A8CC-693BF873D56B}
static const GUID provider_id = {
    0xb0b70986, 0x9d2a, 0x4b52, {0xa8, 0xcc, 0x69, 0x3b, 0xf8, 0x73, 0xd5, 0x6b}};
static REGHANDLE provider{};
static const ULONGLONG scroll_keyword = 1;

extern "C" void zigonaut_scroll_trace_register(void) {
    if (provider == 0) EventRegister(&provider_id, nullptr, nullptr, &provider);
}

extern "C" void zigonaut_scroll_trace_unregister(void) {
    if (provider != 0) {
        EventUnregister(provider);
        provider = 0;
    }
}

extern "C" BOOL zigonaut_scroll_trace_enabled(void) {
    return provider != 0 && EventProviderEnabled(provider, TRACE_LEVEL_INFORMATION, scroll_keyword);
}

extern "C" void zigonaut_scroll_trace_write(
    ZigonautScrollTraceEvent event,
    uint64_t pane_id,
    uint64_t request_id,
    int64_t value1,
    int64_t value2) {
    if (!zigonaut_scroll_trace_enabled()) return;

    const wchar_t* name = L"Unknown";
    const wchar_t* fields = L"value1=%lld value2=%lld";
    switch (event) {
    case ZIGONAUT_SCROLL_TRACE_INPUT:
        name = L"ScrollInput"; fields = L"delta=%lld offset=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_INVALIDATED:
        name = L"RenderInvalidated"; fields = L"already_dirty=%lld reserved=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_FRAME_WAIT_ARMED:
        name = L"FrameWaitArmed"; fields = L"wait_id=%lld epoch=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_FRAME_WAIT_COMPLETED:
        name = L"FrameWaitCompleted"; fields = L"wait_id=%lld outcome=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_CAPTURE_STARTED:
        name = L"CaptureStarted"; fields = L"wait_id=%lld reserved=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_CAPTURE_LOCK_ACQUIRED:
        name = L"CaptureLockAcquired"; fields = L"wait_ns=%lld reserved=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_CAPTURE_COMPLETED:
        name = L"CaptureCompleted"; fields = L"wait_id=%lld outcome=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_PAINT_STARTED:
        name = L"PaintStarted"; fields = L"width=%lld height=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_RENDER_PATH:
        name = L"RenderPath"; fields = L"path=%lld scroll_delta=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_PAINT_COMPLETED:
        name = L"PaintCompleted"; fields = L"present_result=%lld reserved=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_PAINT_FAILED:
        name = L"PaintFailed"; fields = L"error=%lld detail=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_PRESENT_RETRY:
        name = L"PresentRetry"; fields = L"retry=%lld delay_ms=%lld"; break;
    case ZIGONAUT_SCROLL_TRACE_PRESENT_SUCCEEDED:
        name = L"PresentSucceeded"; fields = L"retries=%lld elapsed_ms=%lld"; break;
    default:
        break;
    }

    wchar_t values[128]{};
    _snwprintf_s(values, _countof(values), _TRUNCATE, fields,
        static_cast<long long>(value1), static_cast<long long>(value2));
    wchar_t message[256]{};
    _snwprintf_s(message, _countof(message), _TRUNCATE,
        L"event=%ls pane=%llu request=%llu %ls", name,
        static_cast<unsigned long long>(pane_id),
        static_cast<unsigned long long>(request_id), values);
    EventWriteString(provider, TRACE_LEVEL_INFORMATION, scroll_keyword, message);
}
