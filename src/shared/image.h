#ifndef ZIGONAUT_IMAGE_H
#define ZIGONAUT_IMAGE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Straight, tightly packed RGBA input; caller-owned non-overlapping output.
   width * 4 <= stride; buffers cover height rows; dimensions/stride must not
   overflow size_t. Padding is untouched. format: 0 = RGBA bytes, 1 = native
   endian ARGB32 words (Cairo). No allocation or retained pointers. */
void zigonaut_image_premultiply(const uint8_t *rgba, uint8_t *output,
    size_t width, size_t height, size_t stride, uint32_t format);
typedef struct { double x, y, width, height; } zigonaut_image_rect;
typedef struct { double left, top, right, bottom; } zigonaut_image_clip;
typedef struct { zigonaut_image_rect destination, source; } zigonaut_image_quad;
typedef struct { float x, y, width, height; } zigonaut_image_rect_f32;
typedef struct { float left, top, right, bottom; } zigonaut_image_clip_f32;
typedef struct { zigonaut_image_rect_f32 destination, source; } zigonaut_image_quad_f32;
/* Returns 0 for invalid geometry, 1 for invisible, 2 for visible (writes output).
   Positive finite rectangles, nonnegative source coordinates, finite endpoints
   and mapping are required. Callers validate source bounds against their bitmap.
   Native origins (including fractional scroll) are supplied unchanged. f32
   preserves Windows arithmetic; double preserves macOS/Linux arithmetic.
   Native draws may retain the original crop under a clip to preserve filtering. */
uint32_t zigonaut_image_clip_quad(zigonaut_image_rect destination,
    zigonaut_image_rect source, zigonaut_image_clip clip, zigonaut_image_quad *output);
uint32_t zigonaut_image_clip_quad_f32(zigonaut_image_rect_f32 destination,
    zigonaut_image_rect_f32 source, zigonaut_image_clip_f32 clip, zigonaut_image_quad_f32 *output);
#ifdef __cplusplus
}
#endif
#endif
