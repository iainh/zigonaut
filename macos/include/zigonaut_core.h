#ifndef ZIGONAUT_CORE_H
#define ZIGONAUT_CORE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef struct zigonaut_core zigonaut_core;
typedef void (*zigonaut_wake_fn)(void *context);
typedef struct { uint32_t version, size; uint32_t foreground_rgb, background_rgb, cursor_rgb; uint16_t cursor_x, cursor_y; uint8_t cursor_columns, cursor_style, cursor_visible, cursor_has_position, images_skipped; uint8_t reserved[7]; } zigonaut_render_frame_v1;
/* text_offset/text_length reference the caller-owned UTF-8 arena passed with this cell array. */
typedef struct { uint32_t version, size, text_offset, text_length; uint32_t foreground_rgb, background_rgb, underline_rgb; uint16_t x, y; uint8_t occupancy, underline_style, bold, italic, faint, strikethrough, overline, selected, background_is_default, search_highlight; uint8_t reserved[6]; } zigonaut_render_cell_v1;
/* data_offset/data_length reference the caller-owned RGBA arena. */
typedef struct { uint32_t version, size, image_id; uint64_t generation; uint32_t data_offset, data_length, width, height, source_x, source_y, source_width, source_height, pixel_width, pixel_height; int32_t viewport_column, viewport_row, z; uint32_t x_offset, y_offset; uint8_t reserved[8]; } zigonaut_render_image_v1;
/* status: 0 complete, 1 truncated, 2 error. */
typedef struct { uint32_t version, size, required_cells, written_cells, required_text_bytes, written_text_bytes; uint8_t status; uint8_t reserved[7]; } zigonaut_render_snapshot_result_v1;
typedef struct { uint32_t version, size, required_images, written_images, required_data_bytes, written_data_bytes; uint8_t status; uint8_t reserved[7]; } zigonaut_render_images_result_v1;
/* search status: 0 complete, 2 invalid handle/error, 3 invalid or overlong query; active is -1 when unset. */
typedef struct { uint32_t version, size, matches; int32_t active; uint8_t status; uint8_t reserved[7]; } zigonaut_search_status_v1;
/* take status: 0 complete and consumed, 1 empty, 2 invalid, 3 insufficient capacity (not consumed). */
typedef struct { uint32_t version, size, required_title, written_title, required_body, written_body; uint8_t status, reserved[7]; } zigonaut_notification_result_v1;
typedef struct { uint32_t version, size; uint64_t token; uint32_t required_bytes, written_bytes; uint8_t clear, status, reserved[6]; } zigonaut_clipboard_result_v1;
zigonaut_core *zigonaut_core_create(const char *helper_path, const char *shell_path, zigonaut_wake_fn wake, void *context);
void zigonaut_core_resize(zigonaut_core *, uint16_t columns, uint16_t rows, uint16_t pixel_width, uint16_t pixel_height, uint32_t cell_width, uint32_t cell_height);
void zigonaut_core_request_stop(zigonaut_core *);
void zigonaut_core_write(zigonaut_core *, const uint8_t *bytes, size_t length);
void zigonaut_core_paste(zigonaut_core *, const uint8_t *bytes, size_t length);
void zigonaut_core_scroll(zigonaut_core *, ptrdiff_t rows);
void zigonaut_core_search_set(zigonaut_core *, const uint8_t *query, size_t length, zigonaut_search_status_v1 *);
void zigonaut_core_search_status(zigonaut_core *, zigonaut_search_status_v1 *);
void zigonaut_core_search_navigate(zigonaut_core *, bool forward, zigonaut_search_status_v1 *);
void zigonaut_core_search_clear(zigonaut_core *);
bool zigonaut_core_navigate_prompt(zigonaut_core *, bool forward);
/* Returns required bytes. Copying occurs only when the complete value fits. */
size_t zigonaut_core_last_command_output(zigonaut_core *, uint8_t *output, size_t capacity);
size_t zigonaut_core_working_directory(zigonaut_core *, uint8_t *output, size_t capacity);
void zigonaut_core_selection_begin(zigonaut_core *, uint16_t column, uint16_t row);
void zigonaut_core_selection_update(zigonaut_core *, uint16_t column, uint16_t row);
void zigonaut_core_selection_end(zigonaut_core *);
void zigonaut_core_selection_clear(zigonaut_core *);
/* Returns required bytes. Null/zero sizes; copying occurs only when the complete value fits. */
size_t zigonaut_core_copy_selection(zigonaut_core *, uint8_t *output, size_t capacity);
size_t zigonaut_core_snapshot(zigonaut_core *, uint8_t *output, size_t capacity);
void zigonaut_core_render_snapshot(zigonaut_core *, zigonaut_render_frame_v1 *, zigonaut_render_cell_v1 *, uint32_t cell_capacity, uint8_t *text_arena, uint32_t text_capacity, zigonaut_render_snapshot_result_v1 *);
void zigonaut_core_render_images(zigonaut_core *, zigonaut_render_image_v1 *, uint32_t image_capacity, uint8_t *rgba_arena, uint32_t rgba_capacity, zigonaut_render_images_result_v1 *);
uint32_t zigonaut_core_title(zigonaut_core *, uint8_t *output, uint32_t capacity);
uint32_t zigonaut_core_link_at(zigonaut_core *, uint16_t column, uint16_t row, uint8_t *output, uint32_t capacity);
void zigonaut_core_take_notification(zigonaut_core *, uint8_t *title, uint32_t title_capacity, uint8_t *body, uint32_t body_capacity, zigonaut_notification_result_v1 *);
/* Enabled means intentionally permit immediate OSC 52 writes; accepted writes are queued for the host. */
void zigonaut_core_set_clipboard_write(zigonaut_core *, bool enabled, uint32_t max_bytes);
void zigonaut_core_take_clipboard_write(zigonaut_core *, uint8_t *output, uint32_t capacity, zigonaut_clipboard_result_v1 *);
bool zigonaut_core_mouse_tracking(zigonaut_core *);
bool zigonaut_core_mouse(zigonaut_core *, uint8_t action, uint8_t button, int32_t x, int32_t y, uint32_t screen_width, uint32_t screen_height, uint32_t cell_width, uint32_t cell_height, uint32_t padding, uint16_t modifiers, bool any_button_pressed);
void zigonaut_core_destroy(zigonaut_core *);
#endif
