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
#ifdef __cplusplus
}
#endif
#endif
