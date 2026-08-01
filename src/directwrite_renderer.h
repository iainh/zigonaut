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

typedef struct ZigonautLayoutCacheBenchmark {
    uint64_t layout_creations;
    uint64_t hot_reuse_creations;
    uint32_t cache_entries;
} ZigonautLayoutCacheBenchmark;

typedef struct ZigonautDecodedImage {
    uint32_t width;
    uint32_t height;
    uint8_t* pixels;
    size_t length;
} ZigonautDecodedImage;

HRESULT zigonaut_decode_png(const uint8_t* data, size_t length, ZigonautDecodedImage* result);
void zigonaut_free_decoded_image(uint8_t* pixels);

HRESULT zigonaut_benchmark_layout_cache(
    uint32_t repetitions,
    ZigonautLayoutCacheBenchmark* result);

typedef enum ZigonautCellOccupancy {
    ZIGONAUT_CELL_NARROW = 0,
    ZIGONAUT_CELL_WIDE = 1,
    ZIGONAUT_CELL_WIDE_TAIL = 2,
    ZIGONAUT_CELL_WRAP_SPACER = 3,
} ZigonautCellOccupancy;

HRESULT zigonaut_text_engine_create(
    const wchar_t* font_family,
    uint32_t font_size,
    uint16_t font_weight,
    uint16_t intense_font_weight,
    uint32_t dpi,
    ZigonautTextEngine** result);

void zigonaut_text_engine_destroy(ZigonautTextEngine* engine);

HRESULT zigonaut_text_engine_set_dpi(ZigonautTextEngine* engine, uint32_t dpi);

HRESULT zigonaut_text_engine_refresh_rendering_params(ZigonautTextEngine* engine);

ZigonautCellMetrics zigonaut_text_engine_get_cell_metrics(
    const ZigonautTextEngine* engine);

HRESULT zigonaut_text_engine_set_window(ZigonautTextEngine* engine, uintptr_t hwnd);

void* zigonaut_text_engine_get_swap_chain(ZigonautTextEngine* engine);

HANDLE zigonaut_text_engine_get_frame_latency_waitable_object(ZigonautTextEngine* engine);

HRESULT zigonaut_text_engine_begin_frame(
    ZigonautTextEngine* engine,
    uint32_t width,
    uint32_t height,
    uint32_t background,
    BOOL full_rebuild,
    BOOL* full_rebuild_required);

void zigonaut_text_engine_clear_rect(ZigonautTextEngine* engine,
    float left, float top, float right, float bottom, uint32_t color);

void zigonaut_text_engine_abort_frame(ZigonautTextEngine* engine);

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

HRESULT zigonaut_text_engine_draw_image(ZigonautTextEngine* engine,
    uint32_t image_id, uint64_t generation, const uint8_t* rgba, size_t rgba_length,
    uint32_t image_width, uint32_t image_height,
    float destination_left, float destination_top, float destination_width,
    float destination_height, float source_left, float source_top,
    float source_width, float source_height, float clip_left, float clip_top,
    float clip_right, float clip_bottom);

HRESULT zigonaut_text_engine_end_row(ZigonautTextEngine* engine);

void zigonaut_text_engine_draw_cursor(
    ZigonautTextEngine* engine,
    float left,
    float top,
    float width,
    float height,
    uint32_t color,
    uint8_t style);

HRESULT zigonaut_text_engine_draw_preedit(ZigonautTextEngine* engine, const uint16_t* text,
    uint32_t text_length, uint32_t caret, float left, float top, float max_width,
    float height, uint32_t foreground, uint32_t background, float* caret_x);

HRESULT zigonaut_text_engine_end_frame(ZigonautTextEngine* engine);

HRESULT zigonaut_text_engine_retry_present(ZigonautTextEngine* engine);

void zigonaut_fit_cluster_advances(
    float* advances,
    uint32_t glyph_count,
    float expected_width);

#ifdef __cplusplus
}
#endif
