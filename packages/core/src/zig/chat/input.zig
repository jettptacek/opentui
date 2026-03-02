// chat/input.zig — Key event types and input dispatch
// TS parses raw escape sequences into structured KeyEvents,
// then passes them to Zig via FFI. This module defines the key
// event type and dispatches events to the appropriate handler
// based on current screen/focus/modal state.
const std = @import("std");

/// Special keys (non-character keys).
/// Values chosen to match what TS will send over FFI.
pub const SpecialKey = enum(u16) {
    enter = 1,
    tab = 2,
    escape = 3,
    backspace = 4,
    delete = 5,
    up = 6,
    down = 7,
    left = 8,
    right = 9,
    home = 10,
    end = 11,
    page_up = 12,
    page_down = 13,
    f1 = 14,
    f2 = 15,
    f3 = 16,
    f4 = 17,
    f5 = 18,
    f6 = 19,
    f7 = 20,
    f8 = 21,
    f9 = 22,
    f10 = 23,
    f11 = 24,
    f12 = 25,
    insert = 26,
    space = 27,
};

/// Modifier flags (bitfield, matches TS encoding)
pub const Modifiers = packed struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    _pad: u5 = 0,
};

/// A parsed key event passed from TS → Zig via FFI.
/// Discriminated by tag:
///   - char: a Unicode codepoint (with modifiers)
///   - special: a named special key (with modifiers)
pub const KeyEvent = struct {
    /// 0 = char, 1 = special
    tag: u8,
    /// For char events: Unicode codepoint. For special: SpecialKey value.
    code: u32,
    /// Modifier flags
    modifiers: Modifiers,

    pub fn isChar(self: KeyEvent) bool {
        return self.tag == 0;
    }

    pub fn isSpecial(self: KeyEvent) bool {
        return self.tag == 1;
    }

    pub fn specialKey(self: KeyEvent) ?SpecialKey {
        if (self.tag != 1) return null;
        return std.meta.intToEnum(SpecialKey, @as(u16, @intCast(self.code))) catch null;
    }

    pub fn charValue(self: KeyEvent) ?u21 {
        if (self.tag != 0) return null;
        if (self.code > 0x10FFFF) return null;
        return @intCast(self.code);
    }

    pub fn hasCtrl(self: KeyEvent) bool {
        return self.modifiers.ctrl;
    }

    pub fn hasShift(self: KeyEvent) bool {
        return self.modifiers.shift;
    }

    pub fn hasAlt(self: KeyEvent) bool {
        return self.modifiers.alt;
    }
};
