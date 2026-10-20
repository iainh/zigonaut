#ifndef ZIGONAUT_TEXT_RUNS_H
#define ZIGONAUT_TEXT_RUNS_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint32_t column, row, columns, foreground, style, occupancy, builtin, empty; } zigonaut_text_run_input;
typedef struct { uint32_t next_column, row, foreground, style, active; } zigonaut_text_run_state;
enum { ZIGONAUT_RUN_SKIP, ZIGONAUT_RUN_BOUNDARY, ZIGONAUT_RUN_BUILTIN, ZIGONAUT_RUN_SINGLE, ZIGONAUT_RUN_START, ZIGONAUT_RUN_APPEND };
/* Zero-initialize state at frame/row start. Flush native text before every
   action except APPEND/SKIP. Windows shapes wide/spacer cells together;
   macOS isolates them. Text remains owned by the caller, not this state. */
uint32_t zigonaut_text_run_push(zigonaut_text_run_state *, const zigonaut_text_run_input *, bool windows);
uint32_t zigonaut_render_procedural_scalar(const uint8_t *, size_t length);
#ifdef __cplusplus
}
#endif
#endif
