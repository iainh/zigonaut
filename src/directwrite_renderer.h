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

typedef enum ZigonautCellOccupancy {
    ZIGONAUT_CELL_NARROW = 0,
    ZIGONAUT_CELL_WIDE = 1,
    ZIGONAUT_CELL_WIDE_TAIL = 2,
    ZIGONAUT_CELL_WRAP_SPACER = 3,
} ZigonautCellOccupancy;

HRESULT zigonaut_text_engine_create(
    const wchar_t* font_family,
    uint32_t font_size,
    uint32_t dpi,
    ZigonautTextEngine** result);

void zigonaut_text_engine_destroy(ZigonautTextEngine* engine);

HRESULT zigonaut_text_engine_set_dpi(ZigonautTextEngine* engine, uint32_t dpi);

HRESULT zigonaut_text_engine_refresh_rendering_params(ZigonautTextEngine* engine);

ZigonautCellMetrics zigonaut_text_engine_get_cell_metrics(
    const ZigonautTextEngine* engine);

HRESULT zigonaut_text_engine_set_window(ZigonautTextEngine* engine, uintptr_t hwnd);

HRESULT zigonaut_text_engine_begin_frame(
    ZigonautTextEngine* engine,
    uint32_t width,
    uint32_t height,
    uint32_t background);

void zigonaut_text_engine_begin_row(
    ZigonautTextEngine* engine,
    uint32_t row,
    float origin_x,
    float top,
    float cell_width,
    float cell_height);

HRESULT zigonaut_text_engine_draw_cell(
    ZigonautTextEngine* engine,
    const uint16_t* text,
    uint32_t text_length,
    float left,
    float top,
    float width,
    float height,
    uint32_t foreground,
    uint32_t background,
    uint32_t underline_color,
    BOOL bold,
    BOOL italic,
    BOOL faint,
    BOOL strikethrough,
    BOOL overline,
    uint8_t underline,
    ZigonautCellOccupancy occupancy);

void zigonaut_text_engine_end_row(ZigonautTextEngine* engine);

void zigonaut_text_engine_draw_cursor(
    ZigonautTextEngine* engine,
    float left,
    float top,
    float width,
    float height,
    uint32_t color,
    uint8_t style);

HRESULT zigonaut_text_engine_end_frame(ZigonautTextEngine* engine);

void zigonaut_fit_cluster_advances(
    float* advances,
    uint32_t glyph_count,
    float expected_width);

#ifdef __cplusplus
}
#endif
