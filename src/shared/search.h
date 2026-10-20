#ifndef ZIGONAUT_SEARCH_H
#define ZIGONAUT_SEARCH_H
#include <stdbool.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint32_t row, start, end, highlight; } zigonaut_search_span;
/* Zero-initialize pending. Push cells in drawing order; true emits output.
   Highlight is a nonzero kind or colour. Zero flushes, including at end of input.
   Overlaps, gaps, rows and highlight changes split spans. No allocation. */
bool zigonaut_search_span_push(zigonaut_search_span *pending, uint32_t row,
    uint32_t column, uint32_t width, uint32_t highlight, zigonaut_search_span *output);
#ifdef __cplusplus
}
#endif
#endif
