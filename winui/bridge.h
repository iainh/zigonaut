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
} zigonaut_chrome_command_id;

typedef void (__cdecl *zigonaut_chrome_command)(void* context, uint32_t command, uint32_t argument);

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
} zigonaut_backdrop_kind;

__declspec(dllexport) void* __cdecl zigonaut_chrome_initialize(HWND parent, zigonaut_chrome_command callback, void* context, const char* version, uint32_t version_length, const char* git_hash, uint32_t git_hash_length) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update(void* bridge, const char* const* titles, const uint32_t* title_lengths, uint32_t count, int32_t active_index) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_profiles(void* bridge, const char* const* names, const uint32_t* name_lengths, uint32_t count) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_scrollbar(void* bridge, uint32_t total, uint32_t page, uint32_t position, BOOL show) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_taskbar_progress(void* bridge, uint32_t state, uint32_t value) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_show_notification(void* bridge, uint32_t session_id, const char* title, uint32_t title_length, const char* body, uint32_t body_length) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_move(void* bridge, int32_t x, int32_t y, int32_t width, int32_t height) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update_appearance(void* bridge, uint32_t backdrop, BOOL high_contrast) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) BOOL __cdecl zigonaut_chrome_pretranslate(void* bridge, MSG* message) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_close(void* bridge) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_destroy(void* bridge) ZIGONAUT_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef ZIGONAUT_NOEXCEPT
