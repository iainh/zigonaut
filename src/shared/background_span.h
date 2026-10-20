#ifndef ZIGONAUT_BACKGROUND_SPAN_H
#define ZIGONAUT_BACKGROUND_SPAN_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Native coordinates, colour and opacity remain caller-owned. Try extending
   a nonempty span with an exactly adjacent, equal-colour rectangle on the same
   row. On failure neither input changes: paint/reset the span before retrying.
   Skipped/default cells and layer boundaries must flush the caller's span.
   No allocation; input and span must not alias. */
typedef struct {
    double left, top, right, bottom;
    uint32_t colour;
} zigonaut_background_span;
uint8_t zigonaut_background_span_extend(zigonaut_background_span *span,
    const zigonaut_background_span *next);
#ifdef __cplusplus
}
#endif
#endif
