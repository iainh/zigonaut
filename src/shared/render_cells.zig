//! Packed render cells use offsets into an owning UTF-8 arena, never pointers
//! into the live terminal. Native frontends can retain rows without decoding
//! a string for every cell. The layout is shared with render_cells.h.
pub const Cell = extern struct {
    version: u32,
    size: u32,
    text_offset: u32,
    text_length: u32,
    foreground_rgb: u32,
    background_rgb: u32,
    underline_rgb: u32,
    x: u16,
    y: u16,
    occupancy: u8,
    underline_style: u8,
    bold: u8,
    italic: u8,
    faint: u8,
    strikethrough: u8,
    overline: u8,
    selected: u8,
    background_is_default: u8,
    search_highlight: u8,
    reserved: [6]u8,
};
