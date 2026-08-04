const std = @import("std");
const Terminal = @import("terminal.zig").Terminal;
const win = @import("win32.zig").c;

pub const KeyEvent = struct {
    key: Terminal.Key,
    action: Terminal.KeyAction,
    unshifted_codepoint: u32,
    modifiers: u16,
    utf8: [16]u8 = undefined,
    utf8_length: u5 = 0,
    consumed_modifiers: u16 = 0,
};

pub const PressedKey = struct {
    unshifted_codepoint: u32,
    altgr_text: bool,
};

pub const State = struct {
    pending_high_surrogate: ?u16 = null,
    suppressed_character: ?u16 = null,
    pressed: [std.enums.values(Terminal.Key).len]bool = @splat(false),
    altgr_text: [std.enums.values(Terminal.Key).len]bool = @splat(false),
    unshifted_codepoints: [std.enums.values(Terminal.Key).len]u32 = @splat(0),
    encoded_character_key: ?Terminal.Key = null,

    pub fn keyEvent(self: *State, virtual_key: usize, lparam: isize, released: bool) ?KeyEvent {
        const key = keyFromMessage(virtual_key, lparam) orelse return null;
        const repeated = (@as(usize, @bitCast(lparam)) & (1 << 30)) != 0;
        const index = @intFromEnum(key);
        var event: KeyEvent = .{
            .key = key,
            .action = if (released) .release else if (repeated) .repeat else .press,
            .unshifted_codepoint = self.unshifted_codepoints[index],
            .modifiers = currentModifiers(),
        };
        if (released) {
            if (!self.pressed[index]) return null;
            self.pressed[index] = false;
            event.modifiers = normalizeModifiers(event.modifiers, self.altgr_text[index]);
            self.altgr_text[index] = false;
            if (self.encoded_character_key == key) self.encoded_character_key = null;
        } else {
            self.pressed[index] = true;
            self.unshifted_codepoints[index] = unshiftedCodepoint(virtual_key, lparam);
            self.suppressed_character = suppressedCodeUnit(virtual_key);
            event.unshifted_codepoint = self.unshifted_codepoints[index];
            const translation = translatedUtf8(virtual_key, lparam, &event.utf8);
            event.utf8_length = @intCast(translation.length);
            event.consumed_modifiers = translation.consumed_modifiers;
            self.altgr_text[index] = translation.altgr_text;
            event.modifiers = normalizeModifiers(event.modifiers, translation.altgr_text);
        }
        return event;
    }

    pub fn takePressed(self: *State, key: Terminal.Key) ?PressedKey {
        const index = @intFromEnum(key);
        const pressed = &self.pressed[index];
        if (!pressed.*) return null;
        pressed.* = false;
        if (self.encoded_character_key == key) self.encoded_character_key = null;
        defer self.altgr_text[index] = false;
        return .{
            .unshifted_codepoint = self.unshifted_codepoints[index],
            .altgr_text = self.altgr_text[index],
        };
    }

    pub fn suppressEncodedCharacter(self: *State, key: Terminal.Key, unshifted_codepoint: u32) void {
        if (unshifted_codepoint != 0) self.encoded_character_key = key;
    }

    pub fn suppressCharacter(self: *State, code_unit: u16) bool {
        // Windows sends a character message after its key message. Suppress
        // that character when the key event already encoded the same input.
        const suppressed = self.suppressed_character == code_unit or self.encoded_character_key != null;
        self.suppressed_character = null;
        self.encoded_character_key = null;
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

pub fn keyFromMessage(virtual_key: usize, lparam: isize) ?Terminal.Key {
    const raw: usize = @bitCast(lparam);
    const scan_code: u8 = @truncate(raw >> 16);
    const extended = raw & (1 << 24) != 0;
    if (!extended) if (writingSystemKey(scan_code)) |key| return key;
    return switch (virtual_key) {
        win.VK_ESCAPE => .escape,
        win.VK_BACK => .backspace,
        win.VK_TAB => .tab,
        win.VK_RETURN => if (extended) .numpad_enter else .enter,
        win.VK_SHIFT => if (scan_code == 0x36) .shift_right else .shift_left,
        win.VK_CONTROL => if (extended) .control_right else .control_left,
        win.VK_MENU => if (extended) .alt_right else .alt_left,
        win.VK_LWIN => .meta_left,
        win.VK_RWIN => .meta_right,
        win.VK_APPS => .context_menu,
        win.VK_CAPITAL => .caps_lock,
        win.VK_KANA => .kana_mode,
        win.VK_CONVERT => .convert,
        win.VK_NONCONVERT => .non_convert,
        win.VK_INSERT => if (extended) .insert else .numpad_insert,
        win.VK_DELETE => if (extended) .delete else .numpad_delete,
        win.VK_END => if (extended) .end else .numpad_end,
        win.VK_HOME => if (extended) .home else .numpad_home,
        win.VK_NEXT => if (extended) .page_down else .numpad_page_down,
        win.VK_PRIOR => if (extended) .page_up else .numpad_page_up,
        win.VK_DOWN => if (extended) .arrow_down else .numpad_down,
        win.VK_LEFT => if (extended) .arrow_left else .numpad_left,
        win.VK_RIGHT => if (extended) .arrow_right else .numpad_right,
        win.VK_UP => if (extended) .arrow_up else .numpad_up,
        win.VK_CLEAR => .numpad_begin,
        win.VK_HELP => .help,
        win.VK_NUMLOCK => .num_lock,
        win.VK_NUMPAD0 => .numpad_0,
        win.VK_NUMPAD1 => .numpad_1,
        win.VK_NUMPAD2 => .numpad_2,
        win.VK_NUMPAD3 => .numpad_3,
        win.VK_NUMPAD4 => .numpad_4,
        win.VK_NUMPAD5 => .numpad_5,
        win.VK_NUMPAD6 => .numpad_6,
        win.VK_NUMPAD7 => .numpad_7,
        win.VK_NUMPAD8 => .numpad_8,
        win.VK_NUMPAD9 => .numpad_9,
        win.VK_ADD => .numpad_add,
        win.VK_DECIMAL => .numpad_decimal,
        win.VK_DIVIDE => .numpad_divide,
        win.VK_MULTIPLY => .numpad_multiply,
        win.VK_SUBTRACT => .numpad_subtract,
        win.VK_SEPARATOR => .numpad_separator,
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
        win.VK_F13 => .f13,
        win.VK_F14 => .f14,
        win.VK_F15 => .f15,
        win.VK_F16 => .f16,
        win.VK_F17 => .f17,
        win.VK_F18 => .f18,
        win.VK_F19 => .f19,
        win.VK_F20 => .f20,
        win.VK_F21 => .f21,
        win.VK_F22 => .f22,
        win.VK_F23 => .f23,
        win.VK_F24 => .f24,
        win.VK_SNAPSHOT => .print_screen,
        win.VK_SCROLL => .scroll_lock,
        win.VK_PAUSE => .pause,
        win.VK_BROWSER_BACK => .browser_back,
        win.VK_BROWSER_FAVORITES => .browser_favorites,
        win.VK_BROWSER_FORWARD => .browser_forward,
        win.VK_BROWSER_HOME => .browser_home,
        win.VK_BROWSER_REFRESH => .browser_refresh,
        win.VK_BROWSER_SEARCH => .browser_search,
        win.VK_BROWSER_STOP => .browser_stop,
        win.VK_LAUNCH_APP1 => .launch_app_1,
        win.VK_LAUNCH_APP2 => .launch_app_2,
        win.VK_LAUNCH_MAIL => .launch_mail,
        win.VK_MEDIA_PLAY_PAUSE => .media_play_pause,
        win.VK_LAUNCH_MEDIA_SELECT => .media_select,
        win.VK_MEDIA_STOP => .media_stop,
        win.VK_MEDIA_NEXT_TRACK => .media_track_next,
        win.VK_MEDIA_PREV_TRACK => .media_track_previous,
        win.VK_SLEEP => .sleep,
        win.VK_VOLUME_DOWN => .audio_volume_down,
        win.VK_VOLUME_MUTE => .audio_volume_mute,
        win.VK_VOLUME_UP => .audio_volume_up,
        else => null,
    };
}

fn writingSystemKey(scan_code: u8) ?Terminal.Key {
    return switch (scan_code) {
        0x02 => .digit_1,
        0x03 => .digit_2,
        0x04 => .digit_3,
        0x05 => .digit_4,
        0x06 => .digit_5,
        0x07 => .digit_6,
        0x08 => .digit_7,
        0x09 => .digit_8,
        0x0a => .digit_9,
        0x0b => .digit_0,
        0x0c => .minus,
        0x0d => .equal,
        0x10 => .q,
        0x11 => .w,
        0x12 => .e,
        0x13 => .r,
        0x14 => .t,
        0x15 => .y,
        0x16 => .u,
        0x17 => .i,
        0x18 => .o,
        0x19 => .p,
        0x1a => .bracket_left,
        0x1b => .bracket_right,
        0x1e => .a,
        0x1f => .s,
        0x20 => .d,
        0x21 => .f,
        0x22 => .g,
        0x23 => .h,
        0x24 => .j,
        0x25 => .k,
        0x26 => .l,
        0x27 => .semicolon,
        0x28 => .quote,
        0x29 => .backquote,
        0x2b => .backslash,
        0x2c => .z,
        0x2d => .x,
        0x2e => .c,
        0x2f => .v,
        0x30 => .b,
        0x31 => .n,
        0x32 => .m,
        0x33 => .comma,
        0x34 => .period,
        0x35 => .slash,
        0x39 => .space,
        0x56 => .intl_backslash,
        0x73 => .intl_ro,
        0x7d => .intl_yen,
        else => null,
    };
}

fn unshiftedCodepoint(virtual_key: usize, lparam: isize) u32 {
    var keyboard_state: [256]u8 = @splat(0);
    var utf16: [4]u16 = undefined;
    const scan_code: win.UINT = @truncate(@as(usize, @bitCast(lparam)) >> 16);
    // Use neutral modifier state to get the physical key's base character.
    // Flag 4 prevents this query from changing the keyboard's dead-key state.
    const count = win.ToUnicodeEx(
        @intCast(virtual_key),
        scan_code,
        &keyboard_state,
        &utf16,
        utf16.len,
        4,
        win.GetKeyboardLayout(0),
    );
    if ((count == 1 or count == -1) and !std.unicode.utf16IsHighSurrogate(utf16[0]) and !std.unicode.utf16IsLowSurrogate(utf16[0])) return utf16[0];
    if (count == 2 and std.unicode.utf16IsHighSurrogate(utf16[0]) and std.unicode.utf16IsLowSurrogate(utf16[1])) {
        return std.unicode.utf16DecodeSurrogatePair(&utf16) catch 0;
    }
    return 0;
}

fn translatedUtf8(virtual_key: usize, lparam: isize, output: *[16]u8) struct { length: usize, consumed_modifiers: u16, altgr_text: bool } {
    var keyboard_state: [256]u8 = undefined;
    if (win.GetKeyboardState(&keyboard_state) == 0) return .{ .length = 0, .consumed_modifiers = 0, .altgr_text = false };
    var text_state = keyboard_state;
    // libghostty applies control-key encoding itself and expects the logical
    // text ("c"), not the WM_CHAR control byte (0x03). Keep Ctrl+Alt while
    // translating because Windows keyboard layouts use that state for AltGr.
    if (text_state[win.VK_CONTROL] & 0x80 != 0 and text_state[win.VK_MENU] & 0x80 == 0) {
        text_state[win.VK_CONTROL] = 0;
        text_state[win.VK_LCONTROL] = 0;
        text_state[win.VK_RCONTROL] = 0;
    }
    const length = translateWithState(virtual_key, lparam, &text_state, output);
    const right_alt = keyboard_state[win.VK_RMENU] & 0x80 != 0;
    const control = keyboard_state[win.VK_CONTROL] & 0x80 != 0;
    const alt = keyboard_state[win.VK_MENU] & 0x80 != 0;
    const altgr_candidate = length != 0 and right_alt and control and alt;
    const altgr_text = if (altgr_candidate) altgr: {
        var plain_state = text_state;
        plain_state[win.VK_CONTROL] = 0;
        plain_state[win.VK_LCONTROL] = 0;
        plain_state[win.VK_RCONTROL] = 0;
        plain_state[win.VK_MENU] = 0;
        plain_state[win.VK_LMENU] = 0;
        plain_state[win.VK_RMENU] = 0;
        var plain: [16]u8 = undefined;
        const plain_length = translateWithState(virtual_key, lparam, &plain_state, &plain);
        break :altgr isAltGrText(right_alt, control, alt, output[0..length], plain[0..plain_length]);
    } else false;
    if (length == 0 or text_state[win.VK_SHIFT] & 0x80 == 0) {
        return .{ .length = length, .consumed_modifiers = 0, .altgr_text = altgr_text };
    }

    var unshifted_state = text_state;
    unshifted_state[win.VK_SHIFT] = 0;
    unshifted_state[win.VK_LSHIFT] = 0;
    unshifted_state[win.VK_RSHIFT] = 0;
    var unshifted: [16]u8 = undefined;
    const unshifted_length = translateWithState(virtual_key, lparam, &unshifted_state, &unshifted);
    return .{
        .length = length,
        .consumed_modifiers = if (!std.mem.eql(u8, output[0..length], unshifted[0..unshifted_length])) Terminal.Modifier.shift else 0,
        .altgr_text = altgr_text,
    };
}

fn isAltGrText(right_alt: bool, control: bool, alt: bool, translated: []const u8, plain: []const u8) bool {
    return right_alt and control and alt and translated.len != 0 and !std.mem.eql(u8, translated, plain);
}

pub fn normalizeModifiers(modifiers: u16, altgr_text: bool) u16 {
    return if (altgr_text) modifiers & ~(Terminal.Modifier.control | Terminal.Modifier.alt) else modifiers;
}

fn translateWithState(virtual_key: usize, lparam: isize, keyboard_state: *const [256]u8, output: *[16]u8) usize {
    var utf16: [4]u16 = undefined;
    const scan_code: win.UINT = @truncate(@as(usize, @bitCast(lparam)) >> 16);
    const count = win.ToUnicodeEx(
        @intCast(virtual_key),
        scan_code,
        keyboard_state,
        &utf16,
        utf16.len,
        4,
        win.GetKeyboardLayout(0),
    );
    if (count <= 0) return 0;
    return std.unicode.utf16LeToUtf8(output, utf16[0..@intCast(count)]) catch 0;
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
    const extended: isize = 1 << 24;
    try std.testing.expectEqual(Terminal.Key.home, keyFromMessage(win.VK_HOME, extended).?);
    try std.testing.expectEqual(Terminal.Key.arrow_left, keyFromMessage(win.VK_LEFT, extended).?);
    try std.testing.expectEqual(Terminal.Key.f24, keyFromMessage(win.VK_F24, 0).?);
    try std.testing.expectEqual(@as(?Terminal.Key, null), keyFromMessage(win.VK_PACKET, 0));
}

test "scan codes map writing keys independently of virtual characters" {
    try std.testing.expectEqual(Terminal.Key.a, keyFromMessage('Q', 0x1e << 16).?);
    try std.testing.expectEqual(Terminal.Key.backquote, keyFromMessage(win.VK_OEM_3, 0x29 << 16).?);
    try std.testing.expectEqual(Terminal.Key.intl_backslash, keyFromMessage(win.VK_OEM_102, 0x56 << 16).?);
}

test "AltGr normalization requires right Alt text that differs from the plain key" {
    try std.testing.expect(isAltGrText(true, true, true, "@", "q"));
    try std.testing.expect(!isAltGrText(false, true, true, "@", "q"));
    try std.testing.expect(!isAltGrText(true, true, true, "q", "q"));
    try std.testing.expect(!isAltGrText(true, true, true, "", "q"));
    const ctrl_alt = Terminal.Modifier.control | Terminal.Modifier.alt;
    try std.testing.expectEqual(@as(u16, 0), normalizeModifiers(ctrl_alt, true));
    try std.testing.expectEqual(ctrl_alt, normalizeModifiers(ctrl_alt, false));
}

test "extended bit distinguishes navigation and numpad keys" {
    try std.testing.expectEqual(Terminal.Key.home, keyFromMessage(win.VK_HOME, 1 << 24).?);
    try std.testing.expectEqual(Terminal.Key.numpad_home, keyFromMessage(win.VK_HOME, 0).?);
    try std.testing.expectEqual(Terminal.Key.enter, keyFromMessage(win.VK_RETURN, 0).?);
    try std.testing.expectEqual(Terminal.Key.numpad_enter, keyFromMessage(win.VK_RETURN, 1 << 24).?);
}

test "key events distinguish press repeat and release" {
    var state = State{};
    try std.testing.expectEqual(Terminal.KeyAction.press, state.keyEvent(win.VK_HOME, 0, false).?.action);
    try std.testing.expectEqual(Terminal.KeyAction.repeat, state.keyEvent(win.VK_HOME, 1 << 30, false).?.action);
    try std.testing.expectEqual(Terminal.KeyAction.release, state.keyEvent(win.VK_HOME, 0, true).?.action);
}

test "key releases require a delivered press" {
    var state = State{};
    const a_message: isize = 0x1e << 16;
    try std.testing.expectEqual(@as(?KeyEvent, null), state.keyEvent('A', a_message, true));
    try std.testing.expectEqual(Terminal.KeyAction.press, state.keyEvent('A', a_message, false).?.action);
    try std.testing.expectEqual(Terminal.KeyAction.release, state.keyEvent('A', a_message, true).?.action);
    try std.testing.expectEqual(@as(?KeyEvent, null), state.keyEvent('A', a_message, true));
}

test "pressed keys can be drained when focus is lost" {
    var state = State{};
    _ = state.keyEvent('A', 0x1e << 16, false);
    _ = state.keyEvent('B', 0x30 << 16, false);
    try std.testing.expect(state.takePressed(.a) != null);
    try std.testing.expectEqual(@as(?PressedKey, null), state.takePressed(.a));
    try std.testing.expect(state.takePressed(.b) != null);
}

test "draining a pressed AltGr key retains release normalization" {
    var state = State{};
    const index = @intFromEnum(Terminal.Key.q);
    state.pressed[index] = true;
    state.unshifted_codepoints[index] = 'q';
    state.altgr_text[index] = true;
    const pressed = state.takePressed(.q).?;
    try std.testing.expectEqual(@as(u32, 'q'), pressed.unshifted_codepoint);
    try std.testing.expect(pressed.altgr_text);
    try std.testing.expect(!state.altgr_text[index]);
}

test "encoded physical input suppresses only its translated character" {
    var state = State{};
    const a_message: isize = 0x1e << 16;
    const event = state.keyEvent('A', a_message, false).?;
    state.suppressEncodedCharacter(event.key, event.unshifted_codepoint);
    try std.testing.expect(state.suppressCharacter('A'));
    try std.testing.expect(!state.suppressCharacter('A'));

    _ = state.keyEvent('A', a_message, false);
    state.suppressEncodedCharacter(.a, 'a');
    _ = state.keyEvent('A', a_message, true);
    try std.testing.expect(!state.suppressCharacter('B'));
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
