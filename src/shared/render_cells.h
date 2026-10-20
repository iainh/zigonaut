#ifndef ZIGONAUT_RENDER_CELLS_H
#define ZIGONAUT_RENDER_CELLS_H
#include <stdint.h>
/* Offsets reference the owning row/frame's UTF-8 arena. */
typedef struct { uint32_t version, size, text_offset, text_length; uint32_t foreground_rgb, background_rgb, underline_rgb; uint16_t x, y; uint8_t occupancy, underline_style, bold, italic, faint, strikethrough, overline, selected, background_is_default, search_highlight; uint8_t reserved[6]; } zigonaut_render_cell_v1;
#endif
