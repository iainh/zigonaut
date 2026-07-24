#pragma once
#include <windows.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#define ZIGONAUT_NOEXCEPT noexcept
#else
#define ZIGONAUT_NOEXCEPT
#endif

typedef void (__cdecl *zigonaut_chrome_command)(void* context, uint32_t command, uint32_t argument);

__declspec(dllexport) void* __cdecl zigonaut_chrome_initialize(HWND parent, zigonaut_chrome_command callback, void* context) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_update(void* bridge, const char* const* titles, const uint32_t* title_lengths, uint32_t count, int32_t active_index) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_move(void* bridge, int32_t x, int32_t y, int32_t width, int32_t height) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) BOOL __cdecl zigonaut_chrome_pretranslate(void* bridge, MSG* message) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_close(void* bridge) ZIGONAUT_NOEXCEPT;
__declspec(dllexport) HRESULT __cdecl zigonaut_chrome_destroy(void* bridge) ZIGONAUT_NOEXCEPT;

#ifdef __cplusplus
}
#endif

#undef ZIGONAUT_NOEXCEPT
