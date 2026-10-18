#include "images.h"
#define GHOSTTY_STATIC 1
#include <ghostty/vt.h>
#include <png.h>
#include <limits.h>
#include <string.h>

#define IMAGE_LIMIT (32u * 1024u * 1024u)

static bool decode_png(void *userdata, const GhosttyAllocator *allocator,
                       const uint8_t *data, size_t length, GhosttySysImage *out) {
    (void)userdata;
    if (!data || !out || !length || length > IMAGE_LIMIT) return false;
    png_image png = { .version = PNG_IMAGE_VERSION };
    if (!png_image_begin_read_from_memory(&png, data, length)) {
        png_image_free(&png);
        return false;
    }
    bool success = false;
    /* Validate before PNG_IMAGE_SIZE or allocation (including on 32-bit). */
    if (!png.width || !png.height || png.width > IMAGE_LIMIT / 4 / png.height) goto done;
    png.format = PNG_FORMAT_RGBA;
    size_t bytes = (size_t)png.width * png.height * 4;
    uint8_t *pixels = ghostty_alloc(allocator, bytes);
    if (!pixels) goto done;
    if (!png_image_finish_read(&png, NULL, pixels, 0, NULL)) {
        ghostty_free(allocator, pixels, bytes);
        goto done;
    }
    *out = (GhosttySysImage){ .width = png.width, .height = png.height,
                             .data = pixels, .data_len = bytes };
    success = true;
done:
    png_image_free(&png);
    return success;
}

bool zgtk_install_png_decoder(void) {
    /* The host creates all terminals on the GTK thread, before feeding PTYs. */
    static bool installed;
    if (!installed)
        installed = ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, (GhosttySysDecodePngFn)decode_png) == GHOSTTY_SUCCESS;
    return installed;
}

static void remove_surface(ImageCache *cache, size_t index) {
    cache->bytes -= cache->entries[index].bytes;
    cairo_surface_destroy(cache->entries[index].surface);
    cache->count--;
    memmove(cache->entries + index, cache->entries + index + 1,
            (cache->count - index) * sizeof cache->entries[0]);
}

void zgtk_images_clear(ImageCache *cache) {
    while (cache->count) remove_surface(cache, cache->count - 1);
}

static cairo_surface_t *image_surface(ImageCache *cache, const TerminalImage *image) {
    for (size_t i = 0; i < cache->count; i++) {
        ImageSurface entry = cache->entries[i];
        if (entry.image_id != image->image_id) continue;
        if (entry.generation == image->generation && entry.width == image->width && entry.height == image->height) {
            memmove(cache->entries + 1, cache->entries, i * sizeof entry);
            cache->entries[0] = entry;
            return entry.surface;
        }
        remove_surface(cache, i);
        break;
    }
    int stride = cairo_format_stride_for_width(CAIRO_FORMAT_ARGB32, (int)image->width);
    if (stride < 0 || (size_t)stride > IMAGE_LIMIT / image->height) return NULL;
    size_t bytes = (size_t)stride * image->height;
    while (cache->count && (cache->count == 8 || cache->bytes > IMAGE_LIMIT - bytes))
        remove_surface(cache, cache->count - 1);
    cairo_surface_t *surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, (int)image->width, (int)image->height);
    if (cairo_surface_status(surface) != CAIRO_STATUS_SUCCESS) {
        cairo_surface_destroy(surface);
        return NULL;
    }
    uint8_t *destination = cairo_image_surface_get_data(surface);
    for (uint32_t y = 0; y < image->height; y++) {
        uint32_t *row = (uint32_t *)(destination + (size_t)y * stride);
        const uint8_t *rgba = image->pixels + (size_t)y * image->width * 4;
        for (uint32_t x = 0; x < image->width; x++, rgba += 4) {
            uint32_t a = rgba[3];
            /* A native-endian ARGB word is Cairo's format on either endian. */
            row[x] = a << 24 | ((rgba[0] * a + 127) / 255) << 16 |
                     ((rgba[1] * a + 127) / 255) << 8 | ((rgba[2] * a + 127) / 255);
        }
    }
    cairo_surface_mark_dirty(surface);
    memmove(cache->entries + 1, cache->entries, cache->count * sizeof cache->entries[0]);
    cache->entries[0] = (ImageSurface){ surface, image->generation, image->image_id,
                                      image->width, image->height, bytes };
    cache->count++;
    cache->bytes += bytes;
    return surface;
}

void zgtk_images_draw(ImageCache *cache, cairo_t *cr, const TerminalImage *image,
                       int padding, int columns, int rows, int cell_width, int cell_height) {
    if (!image->pixels || !image->width || !image->height ||
        image->width > IMAGE_LIMIT / 4 / image->height ||
        image->length != (size_t)image->width * image->height * 4 ||
        image->width > INT_MAX || image->height > INT_MAX ||
        !image->source_width || !image->source_height || !image->pixel_width || !image->pixel_height ||
        image->source_x > image->width || image->source_width > image->width - image->source_x ||
        image->source_y > image->height || image->source_height > image->height - image->source_y) return;
    cairo_surface_t *surface = image_surface(cache, image);
    if (!surface) return;
    double left = padding + (double)image->viewport_col * cell_width + image->x_offset;
    double top = padding + (double)image->viewport_row * cell_height + image->y_offset;
    cairo_save(cr);
    cairo_rectangle(cr, padding, padding, (double)columns * cell_width, (double)rows * cell_height);
    cairo_clip(cr);
    cairo_rectangle(cr, left, top, image->pixel_width, image->pixel_height);
    cairo_clip(cr);
    cairo_translate(cr, left, top);
    cairo_scale(cr, (double)image->pixel_width / image->source_width,
                    (double)image->pixel_height / image->source_height);
    /* A subsurface also clamps filtering to the source crop, not its neighbours. */
    cairo_surface_t *crop = cairo_surface_create_for_rectangle(surface, image->source_x,
                              image->source_y, image->source_width, image->source_height);
    cairo_set_source_surface(cr, crop, 0, 0);
    cairo_pattern_set_extend(cairo_get_source(cr), CAIRO_EXTEND_PAD);
    cairo_pattern_set_filter(cairo_get_source(cr), CAIRO_FILTER_BILINEAR);
    cairo_paint(cr);
    cairo_restore(cr);
    cairo_surface_destroy(crop);
}
