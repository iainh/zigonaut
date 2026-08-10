#pragma once

#include <stdint.h>
#include <windows.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ZigonautTextEngine ZigonautTextEngine;

typedef enum ZigonautTextAntialiasing {
    ZIGONAUT_TEXT_AA_ACCELERATED_GRAYSCALE = 0,
    ZIGONAUT_TEXT_AA_NATIVE_CLEARTYPE = 1,
} ZigonautTextAntialiasing;

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

typedef struct ZigonautDirectWriteBenchmark {
    uint64_t warm_row_nanoseconds;
    uint64_t monochrome_row_nanoseconds;
    uint64_t uniform_row_nanoseconds;
    uint64_t fragmented_row_nanoseconds;
    uint64_t scene_copy_nanoseconds;
    uint64_t scene_region_copy_nanoseconds;
    uint64_t scene_copy_gpu_nanoseconds;
    uint64_t scene_region_copy_gpu_nanoseconds;
    uint64_t scroll_full_nanoseconds;
    uint64_t scroll_shift_nanoseconds;
    uint64_t layout_hits;
    uint64_t layout_misses;
    uint64_t layout_draws;
    uint64_t glyph_callbacks;
    uint64_t glyph_submissions;
    uint64_t color_translate_attempts;
    uint64_t color_translate_successes;
    uint64_t monochrome_translate_attempts;
    uint64_t monochrome_translate_successes;
    uint64_t resolved_plan_hits;
    uint64_t resolved_plan_misses;
    uint64_t resolved_plan_bypasses;
    uint64_t fragmented_plan_hits;
    uint64_t fragmented_plan_misses;
    uint64_t atlas_eligible_rows, atlas_batched_rows, atlas_fallback_rows;
    uint64_t atlas_placement_hits, atlas_placement_misses, atlas_rasterizations;
    uint64_t atlas_full_misses, atlas_sprites, atlas_sprite_batches;
    uint64_t atlas_uploads, atlas_upload_bytes;
    uint64_t atlas_reserved_area, atlas_rejected_area, atlas_rejected_count;
    uint64_t atlas_pressure_resets, atlas_generation, atlas_resource_allocations;
    uint32_t atlas_extent;
    uint64_t fragmented_native_glyph_submissions, uniform_native_glyph_submissions;
    uint64_t atlas_warm_frame_nanoseconds;
    uint64_t legacy_fragmented_frame_nanoseconds;
    uint64_t instanced_fragmented_frame_nanoseconds;
    uint64_t immutable_instance_frame_nanoseconds;
    uint64_t dynamic_instance_frame_nanoseconds;
    uint64_t paced_legacy_submit_nanoseconds;
    uint64_t paced_instanced_submit_nanoseconds;
    uint64_t paced_legacy_submit_p95_nanoseconds;
    uint64_t paced_instanced_submit_p95_nanoseconds;
    uint64_t paced_legacy_wait_nanoseconds;
    uint64_t paced_instanced_wait_nanoseconds;
    uint64_t paced_legacy_present_retries;
    uint64_t paced_instanced_present_retries;
    uint64_t glyph_slot_uses;
    uint64_t glyph_slot_wraps;
    uint64_t glyph_buffer_creations;
    uint64_t glyph_capacity_growths;
    uint64_t atlas_cold_frame_nanoseconds;
    uint64_t atlas_cold_rasterizations, atlas_cold_uploads;
    uint32_t warm_row_iterations;
    uint32_t monochrome_row_iterations;
    uint32_t uniform_row_iterations;
    uint32_t fragmented_row_iterations;
    uint32_t atlas_warm_frame_rows;
    uint32_t fragmented_frame_iterations;
    uint32_t paced_frame_iterations;
    uint32_t atlas_cold_resource_allocations;
    uint32_t scene_copy_iterations;
    uint32_t scene_copy_d3d11_copies;
    uint32_t scene_region_copy_d3d11_copies;
    uint64_t scene_region_copy_bytes;
    uint32_t scene_width;
    uint32_t scene_height;
    uint32_t scene_region_height;
    uint32_t scroll_iterations;
} ZigonautDirectWriteBenchmark;

typedef struct ZigonautGlyphAtlasPixelsTest {
    uint64_t first_changed_pixels;
    uint64_t second_changed_pixels;
    uint64_t first_red_dominant_pixels;
    uint64_t first_green_dominant_pixels;
    uint64_t first_sprite_batches;
    uint64_t first_sprites;
    uint64_t empty_sprite_batches;
    uint64_t empty_sprites;
    uint64_t empty_changed_pixels;
    uint64_t second_sprite_batches;
    uint64_t second_sprites;
    uint64_t second_placement_hits;
} ZigonautGlyphAtlasPixelsTest;

typedef struct ZigonautDamageTransferTest {
    uint32_t compared_frames;
    uint32_t full_copies;
    uint32_t region_copies;
    uint64_t region_copy_bytes;
} ZigonautDamageTransferTest;

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

HRESULT zigonaut_benchmark_directwrite_pipeline(ZigonautDirectWriteBenchmark* result);
HRESULT zigonaut_test_glyph_atlas_allocator(void);
HRESULT zigonaut_test_present_status_classification(void);
HRESULT zigonaut_test_glyph_atlas_pixels(ZigonautGlyphAtlasPixelsTest* result);
HRESULT zigonaut_test_atlas_policy_and_faults(void);
HRESULT zigonaut_test_damage_aware_transfer(ZigonautDamageTransferTest* result);

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
    int32_t antialiasing,
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

HRESULT zigonaut_text_engine_shift_scene(ZigonautTextEngine* engine,
    int32_t row_delta, uint32_t grid_left, uint32_t grid_top,
    uint32_t grid_width, uint32_t row_height, uint32_t row_count);

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

void zigonaut_text_engine_abandon_pending_present(ZigonautTextEngine* engine);

void zigonaut_fit_cluster_advances(
    float* advances,
    uint32_t glyph_count,
    float expected_width);

#ifdef __cplusplus
}
#endif
