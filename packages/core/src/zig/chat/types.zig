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

pub const User = struct {
    id: [36]u8 = undefined, // UUID
    id_len: u8 = 0,
    name: [MAX_NAME_LEN]u8 = undefined,
    name_len: u8 = 0,
    color: RGBA = .{ 1.0, 1.0, 1.0, 1.0 },
    role: Role = .user,
    avatar_seed: u32 = 0,
    has_avatar: bool = false,

    pub fn nameSlice(self: *const User) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn idSlice(self: *const User) []const u8 {
        return self.id[0..self.id_len];
    }
};

pub const Channel = struct {
    id: [36]u8 = undefined,
    id_len: u8 = 0,
    name: [MAX_CHANNEL_NAME_LEN]u8 = undefined,
    name_len: u8 = 0,
    is_dm: bool = false,
    member_count: u8 = 0,

    pub fn nameSlice(self: *const Channel) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn idSlice(self: *const Channel) []const u8 {
        return self.id[0..self.id_len];
    }
};

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

    pub fn contentSlice(self: *const Message) []const u8 {
        return self.content[0..self.content_len];
    }

    pub fn fromNameSlice(self: *const Message) []const u8 {
        return self.from_name[0..self.from_name_len];
    }
};

pub const Screen = enum(u8) {
    loading = 0,
    register = 1,
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
};

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
