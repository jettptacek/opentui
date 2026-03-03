// chat/types.zig — Shared types for the Zig chat renderer
const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer = @import("../buffer.zig");
pub const RGBA = buffer.RGBA;

pub const MAX_NAME_LEN = 20;
pub const MAX_CHANNEL_NAME_LEN = 32;
pub const MAX_CONTENT_LEN = 4096;
pub const MAX_USERS = 256;
pub const MAX_CHANNELS = 64;
pub const MAX_MESSAGES = 2000;
pub const MAX_PANELS = 16;
pub const MAX_TYPING_USERS = 16;
pub const MAX_DM_MEMBERS = 8;

pub const Role = enum(u8) {
    user = 0,
    moderator = 1,
    admin = 2,
};

pub const MAX_AVATAR_PATTERN_LEN = 12; // 3 glyphs × up to 4 bytes each

pub const User = struct {
    id: [36]u8 = undefined, // UUID
    id_len: u8 = 0,
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: u8 = 0,
    color: RGBA = .{ 1.0, 1.0, 1.0, 1.0 },
    role: Role = .user,
    avatar_seed: u32 = 0,
    has_avatar: bool = false,
    avatar_pattern: [MAX_AVATAR_PATTERN_LEN]u8 = undefined,
    avatar_pattern_len: u8 = 0,

    pub fn nameSlice(self: *const User) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn idSlice(self: *const User) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn avatarPatternSlice(self: *const User) []const u8 {
        return self.avatar_pattern[0..self.avatar_pattern_len];
    }
};

pub const Channel = struct {
    id: [36]u8 = undefined,
    id_len: u8 = 0,
    name: [MAX_CHANNEL_NAME_LEN]u8 = undefined,
    name_len: u8 = 0,
    is_dm: bool = false,
    member_count: u8 = 0,
    unread_count: u16 = 0,

    pub fn nameSlice(self: *const Channel) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn idSlice(self: *const Channel) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub const MAX_REACTION_TYPES = 8; // matches REACTION_EMOJIS count

pub const Message = struct {
    id: [36]u8 = undefined,
    id_len: u8 = 0,
    from_name: [MAX_NAME_LEN]u8 = undefined,
    from_name_len: u8 = 0,
    from_color: RGBA = .{ 1.0, 1.0, 1.0, 1.0 },
    from_role: Role = .user,
    channel: [MAX_CHANNEL_NAME_LEN]u8 = undefined,
    channel_len: u8 = 0,
    content: [MAX_CONTENT_LEN]u8 = undefined,
    content_len: u16 = 0,
    timestamp: i64 = 0, // unix millis
    has_image: bool = false,
    // Reaction counts per emoji type (indexed by REACTION_EMOJIS)
    reaction_counts: [MAX_REACTION_TYPES]u16 = [_]u16{0} ** MAX_REACTION_TYPES,

    pub fn contentSlice(self: *const Message) []const u8 {
        return self.content[0..self.content_len];
    }

    pub fn fromNameSlice(self: *const Message) []const u8 {
        return self.from_name[0..self.from_name_len];
    }

    pub fn idSlice(self: *const Message) []const u8 {
        return self.id[0..self.id_len];
    }

    /// Returns true if this message has any reactions
    pub fn hasReactions(self: *const Message) bool {
        for (self.reaction_counts) |c| {
            if (c > 0) return true;
        }
        return false;
    }
};

pub const Screen = enum(u8) {
    loading = 0,
    chat = 2,
};

pub const PanelKind = enum(u8) {
    header = 0,
    messages = 1,
    compose = 2,
    channels = 3,
    members = 4,
};

pub const Panel = struct {
    kind: PanelKind,
    col: u16,
    row: u16,
    col_span: u16,
    row_span: u16,
    group: u8,
    // Computed by layout
    x: u16 = 0,
    y: u16 = 0,
    width: u16 = 0,
    height: u16 = 0,
    visible: bool = true,

    pub fn isFocusable(self: *const Panel) bool {
        return self.kind != .header and self.visible;
    }

    pub fn innerX(self: *const Panel) u16 {
        return self.x + 1;
    }

    pub fn innerY(self: *const Panel) u16 {
        return self.y + 1;
    }

    pub fn innerWidth(self: *const Panel) u16 {
        if (self.width < 2) return 0;
        return self.width - 2;
    }

    pub fn innerHeight(self: *const Panel) u16 {
        if (self.height < 2) return 0;
        return self.height - 2;
    }
};

/// Active modal overlay (only one at a time)
pub const Modal = enum(u8) {
    none = 0,
    help = 1,
    users = 2, // Users/DM picker (Ctrl+U / Ctrl+N)
    add_member = 3, // Add member to DM (Ctrl+A)
    reaction = 4, // Reaction picker (Ctrl+R)
    settings_menu = 5, // Settings top-level menu (Ctrl+S)
    settings_name = 6,
    settings_color = 7,
    settings_avatar = 8,
    settings_theme = 9,
    settings_keybindings = 10,
    settings_layout = 11,
};

/// Avatar inline glyphs — 16 quadrant block characters (matches AVATAR_INLINE_GLYPHS in avatar.ts)
pub const AVATAR_GLYPHS = [16][]const u8{
    "\xe2\x96\x91", // ░ U+2591
    "\xe2\x96\x98", // ▘ U+2598
    "\xe2\x96\x9d", // ▝ U+259D
    "\xe2\x96\x80", // ▀ U+2580
    "\xe2\x96\x96", // ▖ U+2596
    "\xe2\x96\x8c", // ▌ U+258C
    "\xe2\x96\x9e", // ▞ U+259E
    "\xe2\x96\x9b", // ▛ U+259B
    "\xe2\x96\x97", // ▗ U+2597
    "\xe2\x96\x9a", // ▚ U+259A
    "\xe2\x96\x90", // ▐ U+2590
    "\xe2\x96\x9c", // ▜ U+259C
    "\xe2\x96\x84", // ▄ U+2584
    "\xe2\x96\x99", // ▙ U+2599
    "\xe2\x96\x9f", // ▟ U+259F
    "\xe2\x96\x93", // ▓ U+2593
};
pub const AVATAR_GLYPH_COUNT: u8 = 16;

/// Reaction emoji identifiers
pub const REACTION_EMOJIS = [8][]const u8{
    "+1",
    "heart",
    "joy",
    "open_mouth",
    "cry",
    "tada",
    "fire",
    "eyes",
};

/// Reaction emoji display characters (UTF-8)
pub const REACTION_DISPLAY = [8][]const u8{
    "\xf0\x9f\x91\x8d", // 👍
    "\xe2\x9d\xa4\xef\xb8\x8f", // ❤️
    "\xf0\x9f\x98\x82", // 😂
    "\xf0\x9f\x98\xae", // 😮
    "\xf0\x9f\x98\xa2", // 😢
    "\xf0\x9f\x8e\x89", // 🎉
    "\xf0\x9f\x94\xa5", // 🔥
    "\xf0\x9f\x91\x80", // 👀
};

/// Slash command definition for compose autocomplete
pub const SlashCommand = struct {
    name: []const u8,
    description: []const u8,
    has_args: bool,
};

/// Available slash commands (matching the old SolidJS implementation)
pub const SLASH_COMMANDS = [_]SlashCommand{
    .{ .name = "help", .description = "Show keyboard shortcuts", .has_args = false },
    .{ .name = "quit", .description = "Disconnect from server", .has_args = false },
    .{ .name = "nick", .description = "Open name editor", .has_args = false },
    .{ .name = "settings", .description = "Open settings menu", .has_args = false },
    .{ .name = "theme", .description = "Open theme picker", .has_args = false },
    .{ .name = "dm", .description = "Open DM user picker", .has_args = false },
    .{ .name = "channel", .description = "Create a new channel", .has_args = true },
    .{ .name = "react", .description = "React to selected message", .has_args = false },
    .{ .name = "leavedm", .description = "Leave current DM", .has_args = false },
    .{ .name = "kick", .description = "Kick a user", .has_args = true },
};
pub const SLASH_COMMAND_COUNT: usize = SLASH_COMMANDS.len;
pub const MAX_SLASH_VISIBLE: usize = 8; // max items shown in autocomplete popup

/// Bindable command identifiers — matches the TS BindableCommand type.
/// Order matches BINDABLE_COMMANDS array in keybindings.ts.
pub const BindableCommand = enum(u8) {
    quit = 0, // Close modal / deselect
    quit_immediate = 1, // Quit immediately (Ctrl+Q)
    toggle_help = 2, // Toggle help overlay
    open_settings = 3, // Open settings menu
    toggle_timestamps = 4, // Toggle timestamp display
    toggle_avatars = 5, // Toggle avatar display
    toggle_users = 6, // Open users / DM picker
    new_dm = 7, // New DM conversation (same action as toggle_users)
    leave_dm = 8, // Leave current DM
    add_dm_member = 9, // Add member to current DM
    prev_channel = 10, // Switch to previous channel
    next_channel = 11, // Switch to next channel
    react = 12, // React to selected message
};
pub const BINDABLE_COMMAND_COUNT: u8 = 13;

/// A key combination: either a character key or special key, with modifier flags.
pub const KeyCombo = struct {
    /// 0 = character key, 1 = special key (matches KeyEvent.tag)
    tag: u8,
    /// For char: Unicode codepoint. For special: SpecialKey value.
    code: u32,
    /// Modifier flags (packed same as input.zig Modifiers)
    ctrl: bool,
    shift: bool,

    pub fn eql(self: KeyCombo, other: KeyCombo) bool {
        return self.tag == other.tag and self.code == other.code and
            self.ctrl == other.ctrl and self.shift == other.shift;
    }
};

/// Default keybindings (matches DEFAULT_KEYBINDINGS in keybindings.ts).
/// Indexed by BindableCommand enum value.
pub const DEFAULT_KEYBINDINGS = [BINDABLE_COMMAND_COUNT]KeyCombo{
    .{ .tag = 1, .code = 3, .ctrl = false, .shift = false }, // quit: Escape
    .{ .tag = 0, .code = 'q', .ctrl = true, .shift = false }, // quit_immediate: Ctrl+Q
    .{ .tag = 1, .code = 14, .ctrl = false, .shift = false }, // toggle_help: F1
    .{ .tag = 0, .code = 's', .ctrl = true, .shift = false }, // open_settings: Ctrl+S
    .{ .tag = 0, .code = 't', .ctrl = true, .shift = false }, // toggle_timestamps: Ctrl+T
    .{ .tag = 0, .code = 'g', .ctrl = true, .shift = false }, // toggle_avatars: Ctrl+G
    .{ .tag = 0, .code = 'u', .ctrl = true, .shift = false }, // toggle_users: Ctrl+U
    .{ .tag = 0, .code = 'n', .ctrl = true, .shift = false }, // new_dm: Ctrl+N
    .{ .tag = 0, .code = 'l', .ctrl = true, .shift = false }, // leave_dm: Ctrl+L
    .{ .tag = 0, .code = 'a', .ctrl = true, .shift = false }, // add_dm_member: Ctrl+A
    .{ .tag = 1, .code = 8, .ctrl = true, .shift = false }, // prev_channel: Ctrl+Left
    .{ .tag = 1, .code = 9, .ctrl = true, .shift = false }, // next_channel: Ctrl+Right
    .{ .tag = 0, .code = 'r', .ctrl = true, .shift = false }, // react: Ctrl+R
};

/// Human-readable labels for each bindable command
pub const COMMAND_LABELS = [BINDABLE_COMMAND_COUNT][]const u8{
    "Quit / close modal",
    "Quit immediately",
    "Toggle help",
    "Open settings",
    "Toggle timestamps",
    "Toggle avatars",
    "User picker / DM",
    "New DM",
    "Leave DM",
    "Add DM member",
    "Prev channel",
    "Next channel",
    "React to message",
};

/// Format a KeyCombo as human-readable text into a buffer.
/// Returns the number of bytes written.
pub fn formatKeyCombo(combo: KeyCombo, out: []u8) usize {
    var pos: usize = 0;

    if (combo.ctrl) {
        const prefix = "Ctrl+";
        if (pos + prefix.len <= out.len) {
            @memcpy(out[pos .. pos + prefix.len], prefix);
            pos += prefix.len;
        }
    }
    if (combo.shift) {
        const prefix = "Shift+";
        if (pos + prefix.len <= out.len) {
            @memcpy(out[pos .. pos + prefix.len], prefix);
            pos += prefix.len;
        }
    }

    if (combo.tag == 0) {
        // Character key — display as uppercase letter
        const c: u8 = @intCast(combo.code & 0x7F);
        const upper = if (c >= 'a' and c <= 'z') c - 32 else c;
        if (pos < out.len) {
            out[pos] = upper;
            pos += 1;
        }
    } else {
        // Special key name
        const name = specialKeyName(combo.code);
        if (pos + name.len <= out.len) {
            @memcpy(out[pos .. pos + name.len], name);
            pos += name.len;
        }
    }
    return pos;
}

fn specialKeyName(code: u32) []const u8 {
    return switch (code) {
        1 => "Enter",
        2 => "Tab",
        3 => "Esc",
        4 => "Backspace",
        5 => "Delete",
        6 => "Up",
        7 => "Down",
        8 => "Left",
        9 => "Right",
        10 => "Home",
        11 => "End",
        12 => "PageUp",
        13 => "PageDown",
        14 => "F1",
        15 => "F2",
        16 => "F3",
        17 => "F4",
        18 => "F5",
        19 => "F6",
        20 => "F7",
        21 => "F8",
        22 => "F9",
        23 => "F10",
        24 => "F11",
        25 => "F12",
        26 => "Insert",
        27 => "Space",
        else => "???",
    };
}

/// Layout editor mode (state machine for the grid editing UI)
pub const EditorMode = enum(u8) {
    navigate = 0, // Arrow keys move cursor, A=add, D=delete, S=save
    select_panel = 1, // Up/Down picks panel type, Enter anchors
    place = 2, // Arrow keys extend rectangle, Enter places
};

/// Short labels for panel types in the mini-grid preview (2 chars each)
pub const PANEL_SHORT = [5][]const u8{
    "HD", // header
    "MS", // messages
    "CO", // compose
    "CH", // channels
    "ME", // members
};

/// Full labels for panel types in the panel type picker
pub const PANEL_TYPE_LABELS = [5][]const u8{
    "Header",
    "Messages",
    "Compose",
    "Channels",
    "Members",
};
pub const PANEL_TYPE_COUNT: u8 = 5;

pub const DirtyFlags = packed struct {
    messages: bool = true,
    compose: bool = true,
    members: bool = true,
    channels: bool = true,
    header: bool = true,
    layout: bool = true,
    full: bool = true,

    pub fn any(self: DirtyFlags) bool {
        return self.messages or self.compose or self.members or
            self.channels or self.header or self.layout or self.full;
    }

    pub fn clear(self: *DirtyFlags) void {
        self.* = .{
            .messages = false,
            .compose = false,
            .members = false,
            .channels = false,
            .header = false,
            .layout = false,
            .full = false,
        };
    }

    pub fn markAll(self: *DirtyFlags) void {
        self.* = .{};
    }

    pub fn forPanel(self: *const DirtyFlags, kind: PanelKind) bool {
        return self.full or switch (kind) {
            .header => self.header,
            .messages => self.messages,
            .compose => self.compose,
            .channels => self.channels,
            .members => self.members,
        };
    }
};

/// Calculate how many display rows a message needs given the available width.
/// Accounts for the "username: " prefix on the first line.
/// Subsequent wrapped lines are indented to align with content after the prefix.
/// Adds 1 row if the message has reactions.
pub fn msgRowCount(msg: *const Message, available_width: usize) usize {
    return msgRowCountWithAvatar(msg, available_width, 0);
}

pub fn msgRowCountWithAvatar(msg: *const Message, available_width: usize, avatar_cols: usize) usize {
    if (available_width == 0) return 1;
    const name_len = msg.from_name_len;
    const content_len = msg.content_len;
    // Prefix: "name: " (name + 2 for ": ") + 1 for left padding + avatar_cols
    const prefix_len: usize = @as(usize, name_len) + 3 + avatar_cols;
    var rows: usize = undefined;
    if (prefix_len >= available_width) {
        // Panel too narrow — everything on separate rows
        if (content_len == 0) {
            rows = 1;
        } else {
            rows = 1 + (content_len + available_width - 1) / available_width;
        }
    } else {
        const content_cols_first_line = available_width - prefix_len;
        if (content_len <= content_cols_first_line) {
            rows = 1;
        } else {
            const remaining = content_len - content_cols_first_line;
            // Wrapped lines use full width (indented to prefix_len for visual alignment,
            // but we wrap at available_width for simplicity)
            const wrap_width = available_width - 2; // 2 for left margin on wrapped lines
            if (wrap_width == 0) {
                rows = 2;
            } else {
                rows = 1 + (remaining + wrap_width - 1) / wrap_width;
            }
        }
    }
    // Add 1 row for reaction badges if present
    if (msg.hasReactions()) rows += 1;
    return rows;
}
