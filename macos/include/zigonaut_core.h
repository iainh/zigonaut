#ifndef ZIGONAUT_CORE_H
#define ZIGONAUT_CORE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "../../src/shared/selection_path.h"
typedef struct zigonaut_core zigonaut_core;
typedef void (*zigonaut_wake_fn)(void *context);
/* Main-thread pane tree. IDs are nonzero and unique across leaves and splits.
   Full preorder nodes match Linux's pane ABI; subtree_size includes the node.
   Ratios are fractions of UINT16_MAX. Maximum 64 panes / 127 nodes.
   nodes() returns required count without writing when capacity is insufficient.
   The native host owns terminal objects; Zig owns topology, focus and zoom. */
typedef struct zigonaut_panes zigonaut_panes;
typedef struct { uint64_t id; uint32_t subtree_size; uint16_t ratio; bool split, vertical; } zigonaut_pane_node;
typedef struct { uint64_t id; double x, y, width, height; } zigonaut_pane_frame;
zigonaut_panes *zigonaut_panes_create(const zigonaut_pane_node *, size_t count);
void zigonaut_panes_destroy(zigonaut_panes *);
bool zigonaut_panes_split(zigonaut_panes *, uint64_t target, uint64_t pane, uint64_t split, bool vertical);
bool zigonaut_panes_move(zigonaut_panes *, uint64_t source, uint64_t target, uint64_t split, uint8_t edge);
bool zigonaut_panes_close(zigonaut_panes *, uint64_t pane);
bool zigonaut_panes_focus(zigonaut_panes *, uint64_t pane);
uint64_t zigonaut_panes_focused(const zigonaut_panes *);
uint64_t zigonaut_panes_zoomed(const zigonaut_panes *);
/* 4/5 previous/next; 6..9 resize left/right/up/down; 10 equalize; 11 zoom. */
bool zigonaut_panes_action(zigonaut_panes *, uint8_t action);
bool zigonaut_panes_can_resize(const zigonaut_panes *, uint8_t direction);
bool zigonaut_panes_ratio(zigonaut_panes *, uint64_t split, uint16_t ratio);
size_t zigonaut_panes_nodes(const zigonaut_panes *, zigonaut_pane_node *, size_t capacity);
/* Directions/edges: 0 left, 1 right, 2 up/top, 3 down/bottom.
   Measured frames are in stable layout order, with native top-left coordinates.
   destination returns 0 for no candidate; drop_edge returns -1 outside bounds. */
uint64_t zigonaut_panes_destination(uint64_t source, uint8_t direction, const zigonaut_pane_frame *, size_t count);
int8_t zigonaut_panes_drop_edge(double x, double y, double width, double height);
/* mouse_shape uses public GhosttyMouseShape values (0 default, 8 text initially).
   It occupies a formerly reserved byte; record size and existing offsets are unchanged. */
/* viewport_rows and scroll_offset consume the remaining reserved bytes in v1.
   Size (36), alignment, and all earlier offsets are unchanged. Zero rows means
   legacy logical-row count; otherwise snapshots include one bottom overscan
   row. Positive scroll_offset translates content UP by that fraction of a row. */
typedef struct { uint32_t version, size; uint32_t foreground_rgb, background_rgb, cursor_rgb; uint16_t cursor_x, cursor_y; uint8_t cursor_columns, cursor_style, cursor_visible, cursor_has_position, images_skipped, mouse_shape; uint16_t viewport_rows; float scroll_offset; } zigonaut_render_frame_v1;
/* text_offset/text_length reference the caller-owned UTF-8 arena passed with this cell array. */
typedef struct { uint32_t version, size, text_offset, text_length; uint32_t foreground_rgb, background_rgb, underline_rgb; uint16_t x, y; uint8_t occupancy, underline_style, bold, italic, faint, strikethrough, overline, selected, background_is_default, search_highlight; uint8_t reserved[6]; } zigonaut_render_cell_v1;
/* data_offset/data_length reference the caller-owned RGBA arena. */
typedef struct { uint32_t version, size, image_id; uint64_t generation; uint32_t data_offset, data_length, width, height, source_x, source_y, source_width, source_height, pixel_width, pixel_height; int32_t viewport_column, viewport_row, z; uint32_t x_offset, y_offset; uint8_t reserved[8]; } zigonaut_render_image_v1;
typedef struct { uint32_t image_id, reserved; uint64_t generation; } zigonaut_image_generation_v1;
/* status: 0 complete, 1 truncated, 2 error. Holds replay the completed frame. */
typedef struct { uint32_t version, size, required_cells, written_cells, required_text_bytes, written_text_bytes, required_rows, written_rows; uint64_t viewport_offset; uint8_t status, images_changed; uint8_t reserved[6]; } zigonaut_render_snapshot_result_v1;
typedef struct zigonaut_accessibility_layout zigonaut_accessibility_layout;
typedef struct { uint32_t location, length; } zigonaut_accessibility_range;
typedef struct { zigonaut_accessibility_range range; uint16_t column, row, columns, reserved; } zigonaut_accessibility_span;
typedef struct { uint32_t x, y, width, height; } zigonaut_accessibility_rect;
/* All view pointers belong to layout, are immutable, and remain valid until
   release. No pointers into the terminal or input batch are retained. */
typedef struct {
    const uint16_t *text;
    const zigonaut_accessibility_range *lines, *selections;
    const zigonaut_accessibility_span *spans;
    uint32_t text_count, line_count, selection_count, span_count;
    zigonaut_accessibility_range cursor;
} zigonaut_accessibility_view;
/* Replay the last prepared render snapshot, not a fresh terminal capture.
   maximum_length is clamped to 100000 UTF-16 units, without split surrogates.
   The caller owns the returned layout; NULL means allocation/argument failure. */
zigonaut_accessibility_layout *zigonaut_core_accessibility_snapshot(zigonaut_core *, uint16_t columns, uint16_t rows, uint32_t maximum_length);
/* Pure batch alternative: cells must be row-major (sparse is allowed), with
   valid UTF-8 slices in text. Invalid batches return NULL. */
zigonaut_accessibility_layout *zigonaut_accessibility_build(uint16_t columns, uint16_t rows, const zigonaut_render_cell_v1 *cells, uint32_t cell_count, const uint8_t *text, uint32_t text_count, uint16_t cursor_column, uint16_t cursor_row, uint32_t maximum_length);
void zigonaut_accessibility_release(zigonaut_accessibility_layout *);
void zigonaut_accessibility_get_view(const zigonaut_accessibility_layout *, zigonaut_accessibility_view *);
/* Returns -1 for an invalid index; adapters translate this to native NSNotFound. */
int64_t zigonaut_accessibility_line(const zigonaut_accessibility_layout *, uint32_t index);
zigonaut_accessibility_rect zigonaut_accessibility_grid_rect(const zigonaut_accessibility_layout *, zigonaut_accessibility_range);
typedef struct { uint32_t version, size, required_images, written_images, required_data_bytes, written_data_bytes; uint8_t status; uint8_t reserved[7]; } zigonaut_render_images_result_v1;
typedef struct { uint32_t version, size, foreground_rgb, background_rgb, cursor_rgb; uint32_t ansi_rgb[16]; uint8_t reserved[8]; } zigonaut_terminal_theme_v1;
typedef struct { uint32_t version, size; uint64_t generation; uint8_t active, state, value; uint8_t reserved[5]; } zigonaut_progress_v1;
/* search status: 0 success, 2 invalid handle/error, 3 invalid or overlong query; active is -1 when unset. */
typedef struct { uint32_t version, size, matches; int32_t active; uint8_t status, scanning; uint8_t reserved[6]; } zigonaut_search_status_v1;
/* take status: 0 complete and consumed, 1 empty, 2 invalid, 3 insufficient capacity (not consumed). */
typedef struct { uint32_t version, size, required_title, written_title, required_body, written_body; uint8_t status, reserved[7]; } zigonaut_notification_result_v1;
typedef struct { uint32_t version, size; uint64_t token; uint32_t required_bytes, written_bytes; uint8_t clear, status, reserved[6]; } zigonaut_clipboard_result_v1;
typedef struct { uint32_t target_offset, target_length; uint16_t row, start_column, end_column; uint8_t label_length, label[8], reserved[5]; } zigonaut_hint_v1;
/* status: 0 complete, 1 insufficient capacity, 2 invalid/error. */
typedef struct { uint32_t version, size, required_hints, required_bytes, written_hints, written_bytes; uint8_t status, reserved[7]; } zigonaut_hint_result_v1;
/* action: 0 press, 1 repeat, 2 release. UTF-8 is optional and limited to 64 bytes. */
typedef struct { uint32_t version, size; uint16_t key_code, modifiers, consumed_modifiers, utf8_length; uint8_t action, reserved0[3]; uint32_t unshifted_codepoint; const uint8_t *utf8; uint8_t reserved[8]; } zigonaut_key_event_v1;
zigonaut_core *zigonaut_core_create(const char *helper_path, const char *shell_path, const char *working_directory, bool shell_integration, const char *shell_integration_path, zigonaut_wake_fn wake, void *context);
void zigonaut_core_resize(zigonaut_core *, uint16_t columns, uint16_t rows, uint16_t pixel_width, uint16_t pixel_height, uint32_t cell_width, uint32_t cell_height);
void zigonaut_core_request_stop(zigonaut_core *);
void zigonaut_core_write(zigonaut_core *, const uint8_t *bytes, size_t length);
void zigonaut_core_set_focused(zigonaut_core *, bool focused);
/* True means the physical key/action was recognized, even when the active protocol emits no bytes. */
bool zigonaut_core_key(zigonaut_core *, const zigonaut_key_event_v1 *);
void zigonaut_core_paste(zigonaut_core *, const uint8_t *bytes, size_t length);
void zigonaut_core_scroll(zigonaut_core *, ptrdiff_t rows);
/* Signed row units, same direction as integer scroll; false for no visual
   change, invalid handle, nonfinite input, or failure. Host supplies momentum. */
bool zigonaut_core_scroll_fractional(zigonaut_core *, double rows);
/* Call on a background queue after terminal activity. Returns the next idle
   delay in milliseconds, or zero when complete. Never waits for a busy core. */
uint32_t zigonaut_core_compress(zigonaut_core *);
void zigonaut_core_search_set(zigonaut_core *, const uint8_t *query, size_t length, zigonaut_search_status_v1 *);
void zigonaut_core_search_tick(zigonaut_core *, uint64_t time_budget_ns, zigonaut_search_status_v1 *);
void zigonaut_core_search_status(zigonaut_core *, zigonaut_search_status_v1 *);
void zigonaut_core_search_navigate(zigonaut_core *, bool forward, zigonaut_search_status_v1 *);
void zigonaut_core_search_clear(zigonaut_core *);
bool zigonaut_core_navigate_prompt(zigonaut_core *, bool forward);
/* Returns required bytes. Copying occurs only when the complete value fits. */
size_t zigonaut_core_last_command_output(zigonaut_core *, uint8_t *output, size_t capacity);
size_t zigonaut_core_working_directory(zigonaut_core *, uint8_t *output, size_t capacity);
/* unit: 0 cell, 1 word, 2 visual line, 3 whitespace run, 4 enclosing quote, 5 logical line. */
void zigonaut_core_selection_begin(zigonaut_core *, uint16_t column, uint16_t row, uint8_t unit, bool rectangle);
void zigonaut_core_selection_update(zigonaut_core *, uint16_t column, uint16_t row);
void zigonaut_core_selection_end(zigonaut_core *);
void zigonaut_core_selection_clear(zigonaut_core *);
/* Cheap state query; does not format or copy selected text. */
bool zigonaut_core_has_selection(zigonaut_core *);
/* Returns required bytes. Null/zero sizes; copying occurs only when the complete value fits. */
size_t zigonaut_core_copy_selection(zigonaut_core *, uint8_t *output, size_t capacity);
size_t zigonaut_core_snapshot(zigonaut_core *, uint8_t *output, size_t capacity);
/* Captures one coherent viewport. Cells/text are emitted only for rows whose current visual hash differs from previous_hashes. Current hashes are copied only when every output fits. */
void zigonaut_core_render_snapshot(zigonaut_core *, const uint64_t *previous_hashes, uint32_t previous_count, zigonaut_render_frame_v1 *, zigonaut_render_cell_v1 *, uint32_t cell_capacity, uint8_t *text_arena, uint32_t text_capacity, uint64_t *current_hashes, uint32_t hash_capacity, zigonaut_render_snapshot_result_v1 *);
/* Placements are always current. RGBA is emitted once per active key absent from known_generations; duplicate placements reference the same key with zero data_length. */
void zigonaut_core_render_images(zigonaut_core *, const zigonaut_image_generation_v1 *known_generations, uint32_t known_count, zigonaut_render_image_v1 *, uint32_t image_capacity, uint8_t *rgba_arena, uint32_t rgba_capacity, zigonaut_render_images_result_v1 *);
bool zigonaut_core_set_theme(zigonaut_core *, const zigonaut_terminal_theme_v1 *);
bool zigonaut_core_set_scrollback(zigonaut_core *, uint32_t lines);
/* style: 0 bold font, 1 bold font with bright colors, 2 bright colors. */
bool zigonaut_core_set_intense_text_style(zigonaut_core *, uint8_t style);
void zigonaut_core_progress(zigonaut_core *, zigonaut_progress_v1 *);
/* Plain UTF-8 pane status, never markup. Returns required bytes; copies only
   when complete. state: 0 absent, 1 idle, 2 working, 3 done, 4 blocked, 5 error. */
uint32_t zigonaut_core_program_status(zigonaut_core *, uint8_t *output, uint32_t capacity, uint8_t *state);
/* True only while a foreground process group other than the login shell owns the PTY. */
bool zigonaut_core_has_foreground_job(zigonaut_core *);
bool zigonaut_core_exited(zigonaut_core *);
uint64_t zigonaut_core_output_generation(zigonaut_core *);
uint32_t zigonaut_core_title(zigonaut_core *, uint8_t *output, uint32_t capacity);
uint32_t zigonaut_core_link_at(zigonaut_core *, uint16_t column, uint16_t row, uint8_t *output, uint32_t capacity, uint16_t *start_column, uint16_t *end_column);
void zigonaut_core_hint_snapshot(zigonaut_core *, zigonaut_hint_v1 *, uint32_t hint_capacity, uint8_t *bytes, uint32_t byte_capacity, zigonaut_hint_result_v1 *);
void zigonaut_core_take_notification(zigonaut_core *, uint8_t *title, uint32_t title_capacity, uint8_t *body, uint32_t body_capacity, zigonaut_notification_result_v1 *);
/* Opt-in OSC 133 completion alerts: at least five seconds and pane unfocused at completion. */
void zigonaut_core_set_command_notifications(zigonaut_core *, bool enabled);
/* Enabled means intentionally permit immediate OSC 52 writes; accepted writes are queued for the host. */
void zigonaut_core_set_clipboard_write(zigonaut_core *, bool enabled, uint32_t max_bytes);
void zigonaut_core_take_clipboard_write(zigonaut_core *, uint8_t *output, uint32_t capacity, zigonaut_clipboard_result_v1 *);
bool zigonaut_core_mouse_tracking(zigonaut_core *);
bool zigonaut_core_mouse(zigonaut_core *, uint8_t action, uint8_t button, int32_t x, int32_t y, uint32_t screen_width, uint32_t screen_height, uint32_t cell_width, uint32_t cell_height, uint32_t padding_top, uint32_t padding_bottom, uint32_t padding_left, uint32_t padding_right, uint16_t modifiers, bool any_button_pressed);
void zigonaut_core_destroy(zigonaut_core *);

typedef struct zigonaut_pseudographics_result_v1 {
    uint16_t version;
    uint16_t size;
    int32_t status;
    uint32_t width, height, stride;
    int32_t offset_x, offset_y;
    size_t required_bytes, written_bytes;
} zigonaut_pseudographics_result_v1;

/* Stateless physical-pixel A8 renderer. Initialize result version to 1 and size
   to sizeof(*result). Status: 0 success, 1 capacity query, -1 invalid argument,
   -2 codepoint not covered. The output is a full cell. */
bool zigonaut_pseudographics_covers(uint32_t codepoint);
int32_t zigonaut_pseudographics_render(uint32_t codepoint, uint32_t width,
    uint32_t height, uint32_t thickness, uint32_t stride, uint8_t *output,
    size_t capacity, zigonaut_pseudographics_result_v1 *result);
#endif
