#pragma once
#include <windows.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (__cdecl *zigonaut_chrome_command)(void* context, uint32_t command, uint32_t argument);

__declspec(dllexport) void* __cdecl zigonaut_chrome_initialize(HWND parent, zigonaut_chrome_command callback, void* context);
__declspec(dllexport) void __cdecl zigonaut_chrome_update(void* bridge, const uint8_t* shell_kinds, uint32_t count, int32_t active_index);
__declspec(dllexport) void __cdecl zigonaut_chrome_move(void* bridge, int32_t x, int32_t y, int32_t width, int32_t height);
__declspec(dllexport) BOOL __cdecl zigonaut_chrome_pretranslate(void* bridge, MSG* message);
__declspec(dllexport) void __cdecl zigonaut_chrome_close(void* bridge);
__declspec(dllexport) void __cdecl zigonaut_chrome_destroy(void* bridge);

#ifdef __cplusplus
}
#endif
