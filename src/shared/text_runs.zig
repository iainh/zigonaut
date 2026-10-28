//! Allocation-free row segmentation. Hosts retain encoded text/shaping objects;
//! Zig decides run boundaries without imposing one platform's shaping policy.
const std = @import("std");

pub const Input = extern struct {
    column: u32,
    row: u32,
    columns: u32,
    foreground: u32,
    style: u32, // bold=1, italic=2, faint=4 (after native colour resolution)
    occupancy: u32,
    builtin: u32,
    empty: u32,
};
pub const State = extern struct {
    next_column: u32 = 0,
    row: u32 = 0,
    foreground: u32 = 0,
    style: u32 = 0,
    active: u32 = 0,
};
pub const Action = enum(u32) { skip, boundary, builtin, single, start, append };

/// macOS batches narrow cells only. DirectWrite also shapes wide and spacer
/// cells in a run and ignores wide tails without breaking the preceding run.
pub fn push(state: *State, input: Input, windows: bool) Action {
    if (input.occupancy == 2 and windows) return .skip;
    if (input.builtin != 0) {
        state.active = 0;
        return .builtin;
    }
    if (!windows and input.occupancy != 0) {
        state.active = 0;
        return if (input.occupancy == 2 or input.empty != 0) .boundary else .single;
    }
    const append = state.active != 0 and state.next_column == input.column and
        state.row == input.row and state.foreground == input.foreground and state.style == input.style;
    state.* = .{
        .next_column = input.column + input.columns,
        .row = input.row,
        .foreground = input.foreground,
        .style = input.style,
        .active = 1,
    };
    return if (append) .append else .start;
}

export fn zigonaut_text_run_push(state: *State, input: *const Input, windows: bool) u32 {
    return @backingInt(push(state, input.*, windows));
}

export fn zigonaut_render_procedural_scalar(text: [*]const u8, length: usize) u32 {
    if (length != 3 or text[0] != 0xe2) return 0;
    const scalar = std.unicode.utf8Decode(text[0..3]) catch return 0;
    return if (scalar >= 0x2500 and scalar <= 0x259f) scalar else 0;
}

test "native run policies preserve wide cells, tails, gaps, styles and builtins" {
    var mac = State{};
    var windows = State{};
    var cell = Input{ .column = 2, .row = 3, .columns = 1, .foreground = 0x123456, .style = 1, .occupancy = 0, .builtin = 0, .empty = 0 };
    try std.testing.expectEqual(Action.start, push(&mac, cell, false));
    try std.testing.expectEqual(Action.start, push(&windows, cell, true));
    cell.column = 3;
    cell.occupancy = 1;
    cell.columns = 2;
    try std.testing.expectEqual(Action.single, push(&mac, cell, false));
    try std.testing.expectEqual(Action.append, push(&windows, cell, true));
    cell.column = 4;
    cell.occupancy = 2;
    try std.testing.expectEqual(Action.boundary, push(&mac, cell, false));
    try std.testing.expectEqual(Action.skip, push(&windows, cell, true));
    cell.column = 5;
    cell.occupancy = 0;
    cell.columns = 1;
    try std.testing.expectEqual(Action.start, push(&mac, cell, false));
    try std.testing.expectEqual(Action.append, push(&windows, cell, true));
    cell.column = 6;
    cell.style = 2;
    try std.testing.expectEqual(Action.start, push(&windows, cell, true));
    cell.column = 8;
    try std.testing.expectEqual(Action.start, push(&windows, cell, true));
    cell.column = 9;
    cell.builtin = 1;
    try std.testing.expectEqual(Action.builtin, push(&windows, cell, true));
    cell.column = 10;
    cell.builtin = 0;
    try std.testing.expectEqual(Action.start, push(&windows, cell, true));
    cell.column = 11;
    try std.testing.expectEqual(Action.append, push(&windows, cell, true));
    cell.row = 4;
    cell.column = 12;
    try std.testing.expectEqual(Action.start, push(&windows, cell, true));
    cell.column = 6;
    cell.style = 1;
    try std.testing.expectEqual(Action.start, push(&mac, cell, false));
    cell.column = 7;
    try std.testing.expectEqual(Action.append, push(&mac, cell, false));
    try std.testing.expectEqual(@as(u32, 0x2588), zigonaut_render_procedural_scalar("█", 3));
    try std.testing.expectEqual(@as(u32, 0), zigonaut_render_procedural_scalar("é", 3));
}
