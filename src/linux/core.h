#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Private, synchronous GTK ↔ Zig boundary. All calls run on the GTK thread.
 * Byte spans and draw arguments are borrowed for the duration of the call. */
typedef struct TerminalCore TerminalCore;
TerminalCore *zgtk_create(void *host);
/* Themes: 0 Rasmus, 1 Fluent Light, 2 Fluent Dark. Intense: 0 all, 1 bold, 2 bright. */
bool zgtk_configure(TerminalCore *core, uint8_t theme, uint32_t scrollback,
                    uint8_t intense, bool clipboard, uint32_t clipboard_limit);
void zgtk_destroy(TerminalCore *core);
void zgtk_feed(TerminalCore *core, const char *bytes, size_t length);
bool zgtk_resize(TerminalCore *core, uint16_t columns, uint16_t rows,
                  uint32_t cell_width, uint32_t cell_height);
bool zgtk_render(TerminalCore *core);
bool zgtk_key(TerminalCore *core, const char *name, uint16_t modifiers,
              uint16_t consumed, const char *text, size_t length, bool release);
bool zgtk_paste(TerminalCore *core, const char *text, size_t length);
void zgtk_scroll(TerminalCore *core, int lines);
void zgtk_focus(TerminalCore *core, bool focused);
bool zgtk_select(TerminalCore *core, uint16_t x, uint16_t y, bool begin, bool rectangle);
void zgtk_copy(TerminalCore *core);
bool zgtk_copy_last_command(TerminalCore *core);

/* The same layout model used by Windows. IDs are local to a tab. GTK owns
 * session lifetimes and native widgets; the tree owns topology and focus. */
typedef struct PaneLayout PaneLayout;
typedef struct {
    uint64_t id;
    uint32_t subtree_size; /* Preorder, including this node; leaves are 1. */
    uint16_t ratio;
    bool split, vertical;
} PaneNode;
typedef enum {
    PANE_LEFT, PANE_RIGHT, PANE_UP, PANE_DOWN,
    PANE_PREVIOUS, PANE_NEXT,
    PANE_RESIZE_LEFT, PANE_RESIZE_RIGHT, PANE_RESIZE_UP, PANE_RESIZE_DOWN,
    PANE_EQUALIZE, PANE_ZOOM
} PaneAction;
PaneLayout *zgtk_layout_create(void);
void zgtk_layout_destroy(PaneLayout *layout);
uint64_t zgtk_layout_split(PaneLayout *layout, bool vertical);
bool zgtk_layout_close(PaneLayout *layout, uint64_t pane);
bool zgtk_layout_focus(PaneLayout *layout, uint64_t pane);
uint64_t zgtk_layout_focused(PaneLayout *layout);
bool zgtk_layout_zoomed(PaneLayout *layout);
bool zgtk_layout_action(PaneLayout *layout, PaneAction action);
bool zgtk_layout_ratio(PaneLayout *layout, uint64_t split, uint16_t ratio);
size_t zgtk_layout_nodes(PaneLayout *layout, PaneNode *nodes, size_t capacity);

typedef struct {
    uint32_t matches;
    int32_t active; /* Zero-based, or -1 when no match is selected. */
    bool scanning, failed;
} SearchStatus;
bool zgtk_search_set(TerminalCore *core, const char *query, size_t length);
SearchStatus zgtk_search_tick(TerminalCore *core);
SearchStatus zgtk_search_navigate(TerminalCore *core, bool forward);
void zgtk_search_clear(TerminalCore *core);
bool zgtk_navigate_prompt(TerminalCore *core, bool forward);

/* Implemented by the GTK host. Colours are packed 0xRRGGBB. */
void zgtk_write(void *host, const char *bytes, size_t length);
void zgtk_title(void *host, const char *bytes, size_t length);
void zgtk_clipboard(void *host, const char *bytes, size_t length);
void zgtk_begin_frame(void *host, uint32_t background);
void zgtk_draw_cell(void *host, uint16_t x, uint16_t y, uint8_t columns,
                    const char *text, size_t length, uint32_t foreground,
                    uint32_t background, uint32_t underline, uint16_t flags);
/* RGBA pixels are snapshot-owned and borrowed only during draw_image. */
typedef struct {
    uint64_t generation;
    const uint8_t *pixels;
    size_t length;
    uint32_t image_id, width, height;
    uint32_t source_x, source_y, source_width, source_height;
    uint32_t pixel_width, pixel_height;
    int32_t viewport_col, viewport_row;
    uint32_t x_offset, y_offset;
} TerminalImage;
void zgtk_draw_image(void *host, const TerminalImage *image);
void zgtk_draw_cursor(void *host, uint16_t x, uint16_t y, uint8_t columns,
                      uint8_t style, uint32_t colour);
