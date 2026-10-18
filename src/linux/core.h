#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Private, synchronous GTK ↔ Zig boundary. All calls run on the GTK thread.
 * Byte spans and draw arguments are borrowed for the duration of the call. */
typedef struct TerminalCore TerminalCore;
TerminalCore *zgtk_create(void *host);
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

/* Implemented by the GTK host. Colours are packed 0xRRGGBB. */
void zgtk_write(void *host, const char *bytes, size_t length);
void zgtk_title(void *host, const char *bytes, size_t length);
void zgtk_clipboard(void *host, const char *bytes, size_t length);
void zgtk_begin_frame(void *host, uint32_t background);
void zgtk_draw_cell(void *host, uint16_t x, uint16_t y, uint8_t columns,
                    const char *text, size_t length, uint32_t foreground,
                    uint32_t background, uint32_t underline, uint8_t flags);
void zgtk_draw_cursor(void *host, uint16_t x, uint16_t y, uint8_t columns,
                      uint8_t style, uint32_t colour);
