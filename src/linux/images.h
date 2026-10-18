#pragma once
#include "core.h"
#include <cairo.h>

/* Per-terminal LRU: at most eight converted surfaces and 32 MiB total.
 * Zero-initialize, use only on the GTK thread, clear before session teardown. */
typedef struct {
    cairo_surface_t *surface;
    uint64_t generation;
    uint32_t image_id, width, height;
    size_t bytes;
} ImageSurface;
typedef struct {
    ImageSurface entries[8];
    size_t count, bytes;
} ImageCache;

bool zgtk_install_png_decoder(void);
void zgtk_images_clear(ImageCache *cache);
void zgtk_images_draw(ImageCache *cache, cairo_t *cr, const TerminalImage *image,
                       int padding, int columns, int rows, int cell_width, int cell_height);
