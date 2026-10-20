#ifndef ZIGONAUT_DECORATION_PATH_H
#define ZIGONAUT_DECORATION_PATH_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Local-coordinate curly underline: move=0, cubic=1. Fixed native style:
   8-pixel nominal wavelength, 2-pixel control amplitude, positive first lobe.
   Native callers retain placement, stroke, clipping and colour ownership.
   Width must be finite, positive and <= 65535. Other widths return 0.
   Returns required count; writes only capacity commands. NULL with capacity 0
   is a sizing query. No allocation. f32 preserves Direct2D arithmetic; f64
   preserves AppKit arithmetic. Cache geometry by width (style is fixed). */
typedef struct { uint32_t tag; float x, y, c1x, c1y, c2x, c2y; } zigonaut_decoration_command_f32;
typedef struct { uint32_t tag; double x, y, c1x, c1y, c2x, c2y; } zigonaut_decoration_command_f64;
size_t zigonaut_curly_underline_f32(float width, zigonaut_decoration_command_f32 *output, size_t capacity);
size_t zigonaut_curly_underline_f64(double width, zigonaut_decoration_command_f64 *output, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
