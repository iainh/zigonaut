#ifndef ZIGONAUT_SELECTION_PATH_H
#define ZIGONAUT_SELECTION_PATH_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* move=0, line=1, quadratic=2, close=3. x/y is the endpoint; cx/cy is
   the quadratic control point. Each move starts a filled closed component.
   No allocation or callbacks. Returns the required command count; only the
   first capacity records are written. NULL output is allowed with capacity 0.
   A capacity of 9 * line_count (or 27 for a Windows row) never needs a retry.
   Input/output must not alias. */
typedef struct { int64_t row, start_column, end_column; } zigonaut_selection_line;
typedef struct { uint32_t tag, reserved; double x, y, cx, cy; } zigonaut_selection_command;
typedef struct { uint32_t start, end, active; } zigonaut_selection_interval;
typedef struct { uint32_t tag; float x, y, cx, cy; } zigonaut_selection_command_f32;
/* macOS: ordered visible rows, strict column overlap joins consecutive rows;
   invalid rows/spans are skipped; viewport endpoints are square. Double
   arithmetic, including origin + row * height, is retained throughout. */
size_t zigonaut_selection_path(const zigonaut_selection_line *lines, size_t line_count,
    int64_t row_count, double origin_x, double origin_y, double cell_width, double line_height,
    zigonaut_selection_command *output, size_t capacity);
/* Windows: exactly three intervals (previous/current/next). Only neighbours
   overlapping current participate. All calculations retain Float rounding,
   including top +/- height; clipping applies only when current is an endpoint. */
size_t zigonaut_selection_row_path(const zigonaut_selection_interval *intervals,
    float origin_x, float top, float cell_width, float cell_height,
    uint8_t top_clipped, uint8_t bottom_clipped,
    zigonaut_selection_command_f32 *output, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
