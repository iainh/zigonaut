#pragma once
#include <windows.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#define ZIGONAUT_NOEXCEPT noexcept
#else
#define ZIGONAUT_NOEXCEPT
#endif

typedef enum zigonaut_chrome_command_id {
    ZIGONAUT_CHROME_NEW_PROFILE = 1,
    ZIGONAUT_CHROME_CLOSE = 3,
    ZIGONAUT_CHROME_SELECT = 4,
    ZIGONAUT_CHROME_OPEN_SETTINGS = 5,
    ZIGONAUT_CHROME_RELOAD_SETTINGS = 6,
    ZIGONAUT_CHROME_QUIT = 7,
    ZIGONAUT_CHROME_SCROLL = 8,
    ZIGONAUT_CHROME_SCROLL_WHEEL = 9,
    ZIGONAUT_CHROME_NOTIFICATION_ACTIVATE = 13,
    ZIGONAUT_CHROME_NEW_DEFAULT = 14,
    ZIGONAUT_CHROME_ZOOM_IN = 15,
    ZIGONAUT_CHROME_ZOOM_OUT = 16,
    ZIGONAUT_CHROME_ZOOM_RESET = 17,
    ZIGONAUT_CHROME_SELECT_NEXT = 18,
    ZIGONAUT_CHROME_SELECT_PREVIOUS = 19,
    ZIGONAUT_CHROME_SHUTDOWN = 20,
    ZIGONAUT_CHROME_SPLIT_RIGHT = 21,
    ZIGONAUT_CHROME_SPLIT_DOWN = 22,
    ZIGONAUT_CHROME_FOCUS_LEFT = 23,
    ZIGONAUT_CHROME_FOCUS_RIGHT = 24,
    ZIGONAUT_CHROME_FOCUS_UP = 25,
    ZIGONAUT_CHROME_FOCUS_DOWN = 26,
    ZIGONAUT_CHROME_CLOSE_PANE = 27,
    ZIGONAUT_CHROME_NEW_WINDOW = 28,
    ZIGONAUT_CHROME_PIPE_COMMAND_OUTPUT = 29,
    ZIGONAUT_CHROME_FIND = 30,
} zigonaut_chrome_command_id;

typedef void (__cdecl *zigonaut_chrome_command)(void* context, uint32_t command, uint32_t argument);
typedef BOOL (__cdecl *zigonaut_window_started)(void* context, void* bridge, HWND window);

typedef enum zigonaut_pane_event_kind {
    ZIGONAUT_PANE_EVENT_FOCUS = 1,
    ZIGONAUT_PANE_EVENT_COMMITTED_RATIO = 2,
    ZIGONAUT_PANE_EVENT_SCROLL = 3,
    ZIGONAUT_PANE_EVENT_SCROLL_WHEEL = 4,
    ZIGONAUT_PANE_EVENT_IME_PREEDIT = 5,
    ZIGONAUT_PANE_EVENT_IME_COMMIT = 6,
    ZIGONAUT_PANE_EVENT_IME_CLEAR = 7,
    ZIGONAUT_PANE_EVENT_FIND_QUERY = 8,
    ZIGONAUT_PANE_EVENT_FIND_NEXT = 9,
    ZIGONAUT_PANE_EVENT_FIND_PREVIOUS = 10,
    ZIGONAUT_PANE_EVENT_FIND_CLOSE = 11,
} zigonaut_pane_event_kind;
typedef struct zigonaut_pane_event {
    uint32_t size;
    uint32_t kind;
    uint64_t target_id;
    uint32_t value;
    uint32_t reserved;
    /* Present when size includes these fields. Borrowed for the callback only. */
    const uint16_t* text;
    uint32_t text_length;
    uint32_t selection_start;
    uint32_t selection_length;
    uint32_t attributes;
} zigonaut_pane_event;
typedef void (__cdecl *zigonaut_pane_event_callback)(void* context, const zigonaut_pane_event* event);

/* Private, synchronous child-window query used by the XAML automation peer.
   The buffer is borrowed for SendMessageW's duration and is never retained. */
#define ZIGONAUT_WM_ACCESSIBILITY_QUERY (WM_APP + 31)
typedef enum zigonaut_accessibility_query_kind {
    ZIGONAUT_ACCESSIBLE_NAME = 1,
    ZIGONAUT_ACCESSIBLE_VALUE = 2,
} zigonaut_accessibility_query_kind;
typedef struct zigonaut_accessibility_query {
    uint32_t size;
    uint32_t kind;
    uint16_t* output;
    uint32_t capacity;
    uint32_t required;
} zigonaut_accessibility_query;

typedef enum zigonaut_layout_kind { ZIGONAUT_LAYOUT_LEAF = 1, ZIGONAUT_LAYOUT_SPLIT = 2 } zigonaut_layout_kind;
typedef enum zigonaut_split_axis { ZIGONAUT_AXIS_LEFT_RIGHT = 1, ZIGONAUT_AXIS_TOP_BOTTOM = 2 } zigonaut_split_axis;
typedef struct zigonaut_layout_node {
    uint32_t size;
    uint32_t kind;
    uint64_t id;
    uint32_t axis;
    uint32_t ratio;
    uint32_t subtree_size;
    uint32_t reserved;
} zigonaut_layout_node;

typedef enum zigonaut_taskbar_progress_state {
    ZIGONAUT_TASKBAR_PROGRESS_NONE = 0,
    ZIGONAUT_TASKBAR_PROGRESS_INDETERMINATE = 1,
    ZIGONAUT_TASKBAR_PROGRESS_NORMAL = 2,
    ZIGONAUT_TASKBAR_PROGRESS_ERROR = 4,
    ZIGONAUT_TASKBAR_PROGRESS_PAUSED = 8,
} zigonaut_taskbar_progress_state;

typedef enum zigonaut_backdrop_kind {
    ZIGONAUT_BACKDROP_NONE = 0,
    ZIGONAUT_BACKDROP_MICA = 1,
    ZIGONAUT_BACKDROP_ACRYLIC = 2,
    ZIGONAUT_BACKDROP_MICA_ALT = 3,
} zigonaut_backdrop_kind;

__declspec(dllexport) HRESULT __cdecl zigonaut_window_run(zigonaut_window_started started, zigonaut_chrome_command callback, zigonaut_pane_event_callback pane_callback, void* context, const char* version, uint32_t version_length, const char* git_hash, uint32_t git_hash_length) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_attach_pane(void* bridge, uint64_t pane_id, HWND terminal, void* swap_chain, uint32_t cell_width, uint32_t cell_height, uint32_t minimum_width, uint32_t minimum_height, uint32_t initial_width, uint32_t initial_height) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_detach_pane(void* bridge, uint64_t pane_id) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_focus_pane(void* bridge, uint64_t pane_id) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_layout(void* bridge, const zigonaut_layout_node* nodes, uint32_t count, uint64_t focused_pane) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update(void* bridge, const char* const* titles, const uint32_t* title_lengths, uint32_t count, int32_t active_index) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_profiles(void* bridge, const char* const* names, const uint32_t* name_lengths, uint32_t count) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_pane_scrollbar(void* bridge, uint64_t pane_id, uint32_t total, uint32_t page, uint32_t position, BOOL show) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_taskbar_progress(void* bridge, uint32_t state, uint32_t value) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_show_notification(void* bridge, uint32_t session_id, const char* title, uint32_t title_length, const char* body, uint32_t body_length) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_appearance(void* bridge, uint32_t backdrop, BOOL high_contrast, BOOL dark_theme) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_show_settings(void* bridge, const char* path, uint32_t path_length, const char* contents, uint32_t contents_length) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_show_find(void* bridge, uint64_t pane_id) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_find(void* bridge, uint64_t pane_id, uint32_t match_count, int32_t active_match, BOOL scanning) ZIGONAUT_NOEXCEPT;
typedef struct zigonaut_ime_bounds { uint32_t size; int32_t left, top, right, bottom; int32_t pane_left, pane_top, pane_right, pane_bottom; } zigonaut_ime_bounds;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_ime_bounds(void* bridge, uint64_t pane_id, const zigonaut_ime_bounds* bounds) ZIGONAUT_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef ZIGONAUT_NOEXCEPT
