#pragma once

#include <stdint.h>
#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZigonautTextEngine ZigonautTextEngine;

typedef struct ZigonautCellMetrics {
    uint32_t width;
    uint32_t height;
    uint32_t baseline;
} ZigonautCellMetrics;

HRESULT zigonaut_text_engine_create(
    const wchar_t* font_family,
    uint32_t font_size,
    uint32_t dpi,
    ZigonautTextEngine** result);

void zigonaut_text_engine_destroy(ZigonautTextEngine* engine);

HRESULT zigonaut_text_engine_set_dpi(ZigonautTextEngine* engine, uint32_t dpi);

ZigonautCellMetrics zigonaut_text_engine_get_cell_metrics(
    const ZigonautTextEngine* engine);

#ifdef __cplusplus
}
#endif
