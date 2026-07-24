const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;
const win = @import("win32.zig").c;

pub const KeyEvent = struct {
    key: Terminal.Key,
    action: Terminal.KeyAction,
};

pub const State = struct {
    pending_high_surrogate: ?u16 = null,
    suppressed_character: ?u16 = null,

    pub fn keyEvent(self: *State, virtual_key: usize, lparam: isize, released: bool) ?KeyEvent {
        const key = keyFromVirtualKey(virtual_key) orelse return null;
        const repeated = (@as(usize, @bitCast(lparam)) & (1 << 30)) != 0;
        if (!released) self.suppressed_character = suppressedCodeUnit(virtual_key);
        return .{
            .key = key,
            .action = if (released) .release else if (repeated) .repeat else .press,
        };
    }

    pub fn suppressCharacter(self: *State, code_unit: u16) bool {
        const suppressed = self.suppressed_character == code_unit;
        self.suppressed_character = null;
        return suppressed;
    }

    pub fn encodeCharacter(self: *State, code_unit: u16, output: *[4]u8) ?[]const u8 {
        if (self.suppressCharacter(code_unit)) return null;
        return self.encodeUnsuppressedCharacter(code_unit, output);
    }

    pub fn encodeUnsuppressedCharacter(self: *State, code_unit: u16, output: *[4]u8) ?[]const u8 {
        var utf16: [2]u16 = undefined;
        var length: usize = 1;
        if (code_unit >= 0xD800 and code_unit <= 0xDBFF) {
            self.pending_high_surrogate = code_unit;
            return null;
        } else if (code_unit >= 0xDC00 and code_unit <= 0xDFFF) {
            const high = self.pending_high_surrogate orelse return null;
            utf16 = .{ high, code_unit };
            length = 2;
        } else {
            utf16[0] = code_unit;
        }
        self.pending_high_surrogate = null;
        const utf8_length = std.unicode.utf16LeToUtf8(output, utf16[0..length]) catch return null;
        return output[0..utf8_length];
    }
};

pub fn keyFromVirtualKey(virtual_key: usize) ?Terminal.Key {
    return switch (virtual_key) {
        win.VK_ESCAPE => .escape,
        win.VK_BACK => .backspace,
        win.VK_TAB => .tab,
        win.VK_RETURN => .enter,
        win.VK_INSERT => .insert,
        win.VK_DELETE => .delete,
        win.VK_END => .end,
        win.VK_HOME => .home,
        win.VK_NEXT => .page_down,
        win.VK_PRIOR => .page_up,
        win.VK_DOWN => .arrow_down,
        win.VK_LEFT => .arrow_left,
        win.VK_RIGHT => .arrow_right,
        win.VK_UP => .arrow_up,
        win.VK_F1 => .f1,
        win.VK_F2 => .f2,
        win.VK_F3 => .f3,
        win.VK_F4 => .f4,
        win.VK_F5 => .f5,
        win.VK_F6 => .f6,
        win.VK_F7 => .f7,
        win.VK_F8 => .f8,
        win.VK_F9 => .f9,
        win.VK_F10 => .f10,
        win.VK_F11 => .f11,
        win.VK_F12 => .f12,
        else => null,
    };
}

pub fn currentModifiers() u16 {
    var modifiers: u16 = 0;
    if (win.GetKeyState(win.VK_SHIFT) < 0) modifiers |= Terminal.Modifier.shift;
    if (win.GetKeyState(win.VK_CONTROL) < 0) modifiers |= Terminal.Modifier.control;
    if (win.GetKeyState(win.VK_MENU) < 0) modifiers |= Terminal.Modifier.alt;
    if (win.GetKeyState(win.VK_LWIN) < 0 or win.GetKeyState(win.VK_RWIN) < 0) modifiers |= Terminal.Modifier.super;
    return modifiers;
}

fn suppressedCodeUnit(virtual_key: usize) ?u16 {
    return switch (virtual_key) {
        win.VK_ESCAPE => 0x1b,
        win.VK_BACK => 0x08,
        win.VK_TAB => 0x09,
        win.VK_RETURN => 0x0d,
        else => null,
    };
}

test "virtual keys map navigation and function keys" {
    try std.testing.expectEqual(Terminal.Key.home, keyFromVirtualKey(win.VK_HOME).?);
    try std.testing.expectEqual(Terminal.Key.arrow_left, keyFromVirtualKey(win.VK_LEFT).?);
    try std.testing.expectEqual(Terminal.Key.f12, keyFromVirtualKey(win.VK_F12).?);
    try std.testing.expectEqual(@as(?Terminal.Key, null), keyFromVirtualKey('A'));
}

test "key events distinguish press repeat and release" {
    var state = State{};
    try std.testing.expectEqual(Terminal.KeyAction.press, state.keyEvent(win.VK_HOME, 0, false).?.action);
    try std.testing.expectEqual(Terminal.KeyAction.repeat, state.keyEvent(win.VK_HOME, 1 << 30, false).?.action);
    try std.testing.expectEqual(Terminal.KeyAction.release, state.keyEvent(win.VK_HOME, 0, true).?.action);
}

test "translated control character is suppressed once" {
    var state = State{};
    _ = state.keyEvent(win.VK_RETURN, 0, false);
    try std.testing.expect(state.suppressCharacter(0x0d));
    try std.testing.expect(!state.suppressCharacter(0x0d));
}

test "BMP character encodes as UTF-8" {
    var state = State{};
    var output: [4]u8 = undefined;
    try std.testing.expectEqualStrings("\xC3\xA9", state.encodeCharacter(0x00e9, &output).?);
}

test "UTF-16 surrogate pair accumulates and encodes" {
    var state = State{};
    var output: [4]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), state.encodeCharacter(0xd83d, &output));
    try std.testing.expectEqualStrings("\xF0\x9F\x98\x80", state.encodeCharacter(0xde00, &output).?);
}
