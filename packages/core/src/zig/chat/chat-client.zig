// chat/chat-client.zig — Per-connection chat client state and rendering
const std = @import("std");
const Allocator = std.mem.Allocator;

const buffer_mod = @import("../buffer.zig");
const OptimizedBuffer = buffer_mod.OptimizedBuffer;
const RGBA = buffer_mod.RGBA;
const renderer_mod = @import("../renderer.zig");
const CliRenderer = renderer_mod.CliRenderer;
const gp = @import("../grapheme.zig");
const edit_buffer_mod = @import("../edit-buffer.zig");
const EditBuffer = edit_buffer_mod.EditBuffer;
const editor_view_mod = @import("../editor-view.zig");
const EditorView = editor_view_mod.EditorView;
const utf8 = @import("../utf8.zig");

const types = @import("types.zig");
const Panel = types.Panel;
const PanelKind = types.PanelKind;
const DirtyFlags = types.DirtyFlags;
const Screen = types.Screen;
const User = types.User;
const Channel = types.Channel;
const Message = types.Message;
const Modal = types.Modal;
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const layout_mod = @import("layout.zig");
const input_mod = @import("input.zig");
const KeyEvent = input_mod.KeyEvent;
const SpecialKey = input_mod.SpecialKey;
const event_queue_mod = @import("event-queue.zig");
const EventQueue = event_queue_mod.EventQueue;
const EventTag = event_queue_mod.EventTag;

const panel_render = @import("panel-render.zig");

/// Shared buffer for getText operations
var _get_text_buf: [types.MAX_CONTENT_LEN]u8 = undefined;

pub const ChatClient = struct {
    allocator: Allocator,

    // Renderer (owns the double buffer, diff engine, ANSI output)
    renderer: *CliRenderer,
    pool: *gp.GraphemePool,

    // Screen dimensions
    width: u16,
    height: u16,

    // Screen routing
    screen: Screen,

    // Current user
    me: ?User,

    // Users / channels
    users: std.ArrayList(User),
    channels: std.ArrayList(Channel),
    current_channel: [types.MAX_CHANNEL_NAME_LEN]u8,
    current_channel_len: u8,

    // Messages (flat array, newest at end)
    messages: std.ArrayList(Message),

    // Layout
    panels: [types.MAX_PANELS]Panel,
    panel_count: u8,
    grid_cols: u16,
    grid_rows: u16,
    focus_idx: u8,

    // UI state
    show_help: bool,
    show_timestamps: bool,
    show_avatars: bool,

    // Modal system
    modal: Modal,

    // Users/DM picker state
    user_picker_idx: i32,
    user_picker_selected: [types.MAX_USERS]bool, // multi-select flags indexed by user list position
    user_picker_sel_count: u8,

    // Add DM member state
    add_member_idx: i32,

    // Reaction picker state
    reaction_idx: u8,
    reaction_target_msg: i32, // message index to react to

    // Settings state
    settings_menu_idx: u8,
    settings_color_idx: u8,
    settings_theme_idx: u8,
    settings_kb_idx: u8,
    settings_kb_listening: bool,
    // Active keybindings (used for input dispatch)
    keybindings: [types.BINDABLE_COMMAND_COUNT]types.KeyCombo,
    // Draft keybindings (edited in settings, committed on save)
    kb_draft: [types.BINDABLE_COMMAND_COUNT]types.KeyCombo,

    // Layout editor state
    layout_editor_mode: types.EditorMode,
    layout_cursor_col: u16,
    layout_cursor_row: u16,
    layout_anchor_col: u16,
    layout_anchor_row: u16,
    layout_panel_type_idx: u8, // index into PANEL_TYPE_LABELS
    layout_draft_panels: [types.MAX_PANELS]Panel,
    layout_draft_count: u8,
    layout_draft_grid_cols: u16,
    layout_draft_grid_rows: u16,
    layout_error: [64]u8,
    layout_error_len: u8,
    settings_avatar_col: u8,
    settings_avatar_draft: [3]u8, // 3-glyph pattern indices

    // Settings name editor
    settings_name_edit_buffer: ?*EditBuffer,
    settings_name_editor_view: ?*EditorView,

    // Dirty tracking — only re-render what changed
    dirty: DirtyFlags,
    render_requested: bool,

    // Theme
    theme: *const Theme,

    // Scroll state for messages panel
    msg_scroll_offset: i32, // 0 = bottom (newest), positive = scrolled up
    // Unread divider — index of first "new" message (-1 = no divider)
    unread_divider_idx: i32,

    // Channel list selection
    channel_sel_idx: i32,
    // Member list selection
    member_sel_idx: i32,
    // Selected message index (-1 = none)
    selected_msg_idx: i32,

    // Compose input (EditBuffer + EditorView for text editing)
    compose_edit_buffer: ?*EditBuffer,
    compose_editor_view: ?*EditorView,

    // Typing indicators (incoming — other users typing)
    typing_users: [types.MAX_TYPING_USERS][types.MAX_NAME_LEN]u8,
    typing_user_lens: [types.MAX_TYPING_USERS]u8,
    typing_user_count: u8,
    // Typing state (outgoing — whether we have emitted typing_start)
    compose_is_typing: bool,

    // Slash command autocomplete state
    slash_ac_open: bool,
    slash_ac_idx: u8, // selected index in filtered list
    // Filtered indices into SLASH_COMMANDS (populated on each input change)
    slash_ac_filtered: [types.SLASH_COMMAND_COUNT]u8,
    slash_ac_filtered_count: u8,

    // Event queue (outgoing events from Zig → TS)
    events: EventQueue,

    pub const SETTINGS_MENU_ITEMS = [_][]const u8{
        "Name",
        "Color",
        "Theme",
        "Avatar",
        "Keybindings",
        "Layout",
    };
    pub const SETTINGS_MENU_COUNT: u8 = 6;

    pub fn create(allocator: Allocator, width: u16, height: u16, output_fd: i32, pool: *gp.GraphemePool) !*ChatClient {
        const self = try allocator.create(ChatClient);
        errdefer allocator.destroy(self);

        const rend = try CliRenderer.createWithOptions(
            allocator,
            @intCast(width),
            @intCast(height),
            pool,
            false, // not testing
            true, // remote (SSH)
        );
        errdefer rend.destroy();

        if (output_fd >= 0) {
            rend.setOutputFd(@intCast(output_fd));
        }

        // Create compose EditBuffer + EditorView
        const compose_eb = try EditBuffer.init(allocator, pool, .wcwidth);
        errdefer compose_eb.deinit();
        const compose_ev = try EditorView.init(allocator, compose_eb, 40, 1);
        errdefer compose_ev.deinit();

        // Create settings name EditBuffer + EditorView
        const settings_name_eb = try EditBuffer.init(allocator, pool, .wcwidth);
        errdefer settings_name_eb.deinit();
        const settings_name_ev = try EditorView.init(allocator, settings_name_eb, 25, 1);
        errdefer settings_name_ev.deinit();

        self.* = .{
            .allocator = allocator,
            .renderer = rend,
            .pool = pool,
            .width = width,
            .height = height,
            .screen = .loading,
            .me = null,
            .users = .{},
            .channels = .{},
            .current_channel = undefined,
            .current_channel_len = 0,
            .messages = .{},
            .panels = undefined,
            .panel_count = 0,
            .grid_cols = layout_mod.DEFAULT_GRID_COLS,
            .grid_rows = layout_mod.DEFAULT_GRID_ROWS,
            .focus_idx = 0,
            .show_help = false,
            .show_timestamps = false,
            .show_avatars = false,
            .modal = .none,
            .user_picker_idx = 0,
            .user_picker_selected = [_]bool{false} ** types.MAX_USERS,
            .user_picker_sel_count = 0,
            .add_member_idx = 0,
            .reaction_idx = 0,
            .reaction_target_msg = -1,
            .settings_menu_idx = 0,
            .settings_color_idx = 0,
            .settings_theme_idx = 0,
            .settings_kb_idx = 0,
            .settings_kb_listening = false,
            .keybindings = types.DEFAULT_KEYBINDINGS,
            .kb_draft = types.DEFAULT_KEYBINDINGS,
            .layout_editor_mode = .navigate,
            .layout_cursor_col = 0,
            .layout_cursor_row = 0,
            .layout_anchor_col = 0,
            .layout_anchor_row = 0,
            .layout_panel_type_idx = 0,
            .layout_draft_panels = undefined,
            .layout_draft_count = 0,
            .layout_draft_grid_cols = layout_mod.DEFAULT_GRID_COLS,
            .layout_draft_grid_rows = layout_mod.DEFAULT_GRID_ROWS,
            .layout_error = undefined,
            .layout_error_len = 0,
            .settings_avatar_col = 0,
            .settings_avatar_draft = .{ 0, 0, 0 },
            .settings_name_edit_buffer = settings_name_eb,
            .settings_name_editor_view = settings_name_ev,
            .dirty = .{}, // all dirty by default
            .render_requested = true,
            .theme = theme_mod.getDefaultTheme(),
            .msg_scroll_offset = 0,
            .unread_divider_idx = -1,
            .channel_sel_idx = 0,
            .member_sel_idx = 0,
            .selected_msg_idx = -1,
            .compose_edit_buffer = compose_eb,
            .compose_editor_view = compose_ev,
            .typing_users = undefined,
            .typing_user_lens = [_]u8{0} ** types.MAX_TYPING_USERS,
            .typing_user_count = 0,
            .compose_is_typing = false,
            .slash_ac_open = false,
            .slash_ac_idx = 0,
            .slash_ac_filtered = [_]u8{0} ** types.SLASH_COMMAND_COUNT,
            .slash_ac_filtered_count = 0,
            .events = EventQueue.init(),
        };

        // Initialize default layout
        self.panel_count = layout_mod.initDefaultLayout(&self.panels);

        // Set default channel
        const default_chan = "all";
        @memcpy(self.current_channel[0..default_chan.len], default_chan);
        self.current_channel_len = @intCast(default_chan.len);

        // Compute initial layout
        layout_mod.computeLayout(
            self.panels[0..self.panel_count],
            width,
            height,
            self.grid_cols,
            self.grid_rows,
        );

        // Set initial focus to compose (last focusable panel)
        self.focus_idx = self.findPanelByKind(.compose) orelse 0;

        // Setup terminal
        rend.setupTerminal(true);

        return self;
    }

    pub fn destroy(self: *ChatClient) void {
        const alloc = self.allocator;
        if (self.compose_editor_view) |ev| ev.deinit();
        if (self.compose_edit_buffer) |eb| eb.deinit();
        if (self.settings_name_editor_view) |ev| ev.deinit();
        if (self.settings_name_edit_buffer) |eb| eb.deinit();
        self.users.deinit(alloc);
        self.channels.deinit(alloc);
        self.messages.deinit(alloc);
        self.renderer.destroy();
        alloc.destroy(self);
    }

    pub fn resize(self: *ChatClient, width: u16, height: u16) void {
        self.width = width;
        self.height = height;
        self.renderer.resize(@intCast(width), @intCast(height)) catch {};
        layout_mod.computeLayout(
            self.panels[0..self.panel_count],
            width,
            height,
            self.grid_cols,
            self.grid_rows,
        );
        // Update compose editor viewport width
        if (self.compose_editor_view) |ev| {
            if (self.findPanelByKind(.compose)) |idx| {
                const p = &self.panels[idx];
                if (p.innerWidth() > 2) {
                    ev.setViewportSize(@intCast(p.innerWidth() - 2), 1);
                }
            }
        }
        self.dirty.markAll();
        self.render_requested = true;
    }

    pub fn setTheme(self: *ChatClient, theme_id: []const u8) void {
        self.theme = theme_mod.findTheme(theme_id);
        self.dirty.markAll();
        self.render_requested = true;
    }

    pub fn setScreen(self: *ChatClient, screen: Screen) void {
        self.screen = screen;
        self.dirty.markAll();
        self.render_requested = true;
    }

    pub fn setUser(self: *ChatClient, name: []const u8, color: RGBA, role: types.Role, avatar: []const u8) void {
        var user = User{};
        const len = @min(name.len, types.MAX_NAME_LEN);
        @memcpy(user.name[0..len], name[0..len]);
        user.name_len = @intCast(len);
        user.color = color;
        user.role = role;
        const alen = @min(avatar.len, types.MAX_AVATAR_PATTERN_LEN);
        if (alen > 0) {
            @memcpy(user.avatar_pattern[0..alen], avatar[0..alen]);
            user.avatar_pattern_len = @intCast(alen);
        }
        self.me = user;
        self.dirty.header = true;
        self.render_requested = true;
    }

    pub fn addMessage(self: *ChatClient, msg: Message) !void {
        if (self.messages.items.len >= types.MAX_MESSAGES) {
            // Adjust scroll offset for the rows lost by removing the oldest message
            if (self.msg_scroll_offset > 0) {
                const panel_idx = self.findPanelByKind(.messages);
                const available_width: usize = if (panel_idx) |idx| self.panels[idx].innerWidth() else 40;
                const removed_rows: i32 = @intCast(types.msgRowCountWithAvatar(&self.messages.items[0], available_width, self.avatarCols()));
                self.msg_scroll_offset = @max(0, self.msg_scroll_offset - removed_rows);
            }
            _ = self.messages.orderedRemove(0);
        }
        // Set unread divider if user is scrolled up and no divider exists yet
        if (self.msg_scroll_offset > 0 and self.unread_divider_idx < 0) {
            self.unread_divider_idx = @intCast(self.messages.items.len);
        }
        try self.messages.append(self.allocator, msg);
        self.dirty.messages = true;
        self.render_requested = true;
    }

    /// Update reactions on a message by its ID.
    /// reaction_data format: count of pairs(u8) + (emoji_idx(u8) + count(u16-le))*N
    pub fn updateMessageReactions(self: *ChatClient, msg_id: []const u8, reaction_data: []const u8) void {
        // Find the message by ID
        for (self.messages.items) |*msg| {
            if (std.mem.eql(u8, msg.idSlice(), msg_id)) {
                // Clear existing reactions
                msg.reaction_counts = [_]u16{0} ** types.MAX_REACTION_TYPES;
                // Parse reaction data: count(u8) + (emoji_idx(u8) + count_le16)*N
                if (reaction_data.len == 0) {
                    self.dirty.messages = true;
                    self.render_requested = true;
                    return;
                }
                const pair_count = reaction_data[0];
                var off: usize = 1;
                var i: u8 = 0;
                while (i < pair_count and off + 2 < reaction_data.len) : (i += 1) {
                    const emoji_idx = reaction_data[off];
                    const count_lo = reaction_data[off + 1];
                    const count_hi = reaction_data[off + 2];
                    const count: u16 = @as(u16, count_hi) << 8 | @as(u16, count_lo);
                    if (emoji_idx < types.MAX_REACTION_TYPES) {
                        msg.reaction_counts[emoji_idx] = count;
                    }
                    off += 3;
                }
                self.dirty.messages = true;
                self.render_requested = true;
                return;
            }
        }
    }

    /// Add a user to the typing indicators. Ignores duplicates and self.
    pub fn setTypingUser(self: *ChatClient, name: []const u8) void {
        // Don't show self as typing
        if (self.me) |me| {
            if (std.mem.eql(u8, name, me.nameSlice())) return;
        }
        // Check for duplicate
        for (0..self.typing_user_count) |i| {
            const existing = self.typing_users[i][0..self.typing_user_lens[i]];
            if (std.mem.eql(u8, name, existing)) return;
        }
        // Add if space available
        if (self.typing_user_count < types.MAX_TYPING_USERS) {
            const idx = self.typing_user_count;
            const len = @min(name.len, types.MAX_NAME_LEN);
            @memcpy(self.typing_users[idx][0..len], name[0..len]);
            self.typing_user_lens[idx] = @intCast(len);
            self.typing_user_count += 1;
            self.dirty.compose = true;
            self.render_requested = true;
        }
    }

    /// Remove a user from the typing indicators.
    pub fn clearTypingUser(self: *ChatClient, name: []const u8) void {
        var i: usize = 0;
        while (i < self.typing_user_count) {
            const existing = self.typing_users[i][0..self.typing_user_lens[i]];
            if (std.mem.eql(u8, name, existing)) {
                // Shift remaining entries down
                const count = self.typing_user_count;
                var j: usize = i;
                while (j + 1 < count) : (j += 1) {
                    self.typing_users[j] = self.typing_users[j + 1];
                    self.typing_user_lens[j] = self.typing_user_lens[j + 1];
                }
                self.typing_user_count -= 1;
                self.dirty.compose = true;
                self.render_requested = true;
                return;
            }
            i += 1;
        }
    }

    // ---------------------------------------------------------------
    // Modal helpers
    // ---------------------------------------------------------------

    pub fn hasModal(self: *const ChatClient) bool {
        return self.modal != .none;
    }

    fn closeModal(self: *ChatClient) void {
        self.modal = .none;
        self.dirty.markAll();
        self.render_requested = true;
    }

    fn openModal(self: *ChatClient, modal: Modal) void {
        self.modal = modal;
        self.dirty.markAll();
        self.render_requested = true;
    }

    // ---------------------------------------------------------------
    // Input handling — TS parses raw bytes into KeyEvent, passes here
    // ---------------------------------------------------------------

    pub fn processKeyEvent(self: *ChatClient, key: KeyEvent) void {
        switch (self.screen) {
            .loading => {}, // no input on loading screen
            .chat => self.handleChatInput(key),
        }
    }

    fn handleChatInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        // --- Global keys (always processed, even with modals) ---

        // Quit immediately — always works, even in modals
        if (self.matchesBinding(key, .quit_immediate)) {
            _ = self.events.pushTagged(.quit, "");
            return;
        }

        // --- Modal input takes priority ---
        if (self.modal != .none) {
            self.handleModalInput(key);
            return;
        }

        // --- Non-modal global keys ---

        // "Quit" binding → context-sensitive: close autocomplete, close help, deselect message
        if (self.matchesBinding(key, .quit)) {
            if (self.slash_ac_open) {
                self.slash_ac_open = false;
                self.slash_ac_idx = 0;
                self.slash_ac_filtered_count = 0;
                self.dirty.compose = true;
                self.render_requested = true;
                return;
            }
            if (self.show_help) {
                self.show_help = false;
                self.dirty.markAll();
                self.render_requested = true;
                return;
            }
            if (self.selected_msg_idx >= 0) {
                self.selected_msg_idx = -1;
                self.dirty.messages = true;
                self.render_requested = true;
                return;
            }
            return;
        }

        // Toggle help
        if (self.matchesBinding(key, .toggle_help)) {
            self.show_help = !self.show_help;
            self.dirty.markAll();
            self.render_requested = true;
            return;
        }

        // Toggle timestamps
        if (self.matchesBinding(key, .toggle_timestamps)) {
            self.show_timestamps = !self.show_timestamps;
            self.dirty.messages = true;
            self.render_requested = true;
            return;
        }

        // Toggle avatars
        if (self.matchesBinding(key, .toggle_avatars)) {
            self.show_avatars = !self.show_avatars;
            self.dirty.messages = true;
            self.render_requested = true;
            return;
        }

        // Open settings
        if (self.matchesBinding(key, .open_settings)) {
            self.openSettingsMenu();
            return;
        }

        // User picker / DM
        if (self.matchesBinding(key, .toggle_users) or self.matchesBinding(key, .new_dm)) {
            self.openUserPicker();
            return;
        }

        // Add DM member
        if (self.matchesBinding(key, .add_dm_member)) {
            self.openAddMember();
            return;
        }

        // React
        if (self.matchesBinding(key, .react)) {
            self.openReactionPicker();
            return;
        }

        // Leave DM
        if (self.matchesBinding(key, .leave_dm)) {
            const chan = self.currentChannelSlice();
            if (chan.len > 3 and std.mem.startsWith(u8, chan, "dm-")) {
                _ = self.events.pushTagged(.leave_dm, "");
            }
            return;
        }

        // Prev/next channel
        if (self.matchesBinding(key, .prev_channel)) {
            self.switchToPrevChannel();
            return;
        }
        if (self.matchesBinding(key, .next_channel)) {
            self.switchToNextChannel();
            return;
        }

        // Tab / Shift+Tab → focus cycling (skip when slash autocomplete is open)
        if (special) |sp| {
            if (sp == .tab and !self.slash_ac_open) {
                self.cycleFocus(!key.hasShift());
                return;
            }

            // Page Up / Page Down → scroll messages (works from any panel)
            if (sp == .page_up) {
                self.scrollMessages(10);
                return;
            }
            if (sp == .page_down) {
                self.scrollMessages(-10);
                return;
            }
        }

        // --- Panel-specific input ---
        if (self.focusedPanel()) |fp| {
            switch (fp.kind) {
                .compose => self.handleComposeInput(key),
                .channels => self.handleChannelsInput(key),
                .members => self.handleMembersInput(key),
                .messages => self.handleMessagesInput(key),
                .header => {},
            }
        }
    }

    // ---------------------------------------------------------------
    // Modal input dispatch
    // ---------------------------------------------------------------

    fn handleModalInput(self: *ChatClient, key: KeyEvent) void {
        switch (self.modal) {
            .none => {},
            .help => self.handleHelpInput(key),
            .users => self.handleUserPickerInput(key),
            .add_member => self.handleAddMemberInput(key),
            .reaction => self.handleReactionInput(key),
            .settings_menu => self.handleSettingsMenuInput(key),
            .settings_name => self.handleSettingsNameInput(key),
            .settings_color => self.handleSettingsColorInput(key),
            .settings_theme => self.handleSettingsThemeInput(key),
            .settings_keybindings => self.handleSettingsKeybindingsInput(key),
            .settings_avatar => self.handleSettingsAvatarInput(key),
            .settings_layout => self.handleSettingsLayoutInput(key),
        }
    }

    fn handleHelpInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();
        // Escape or F1 closes help
        if (special == .escape or special == .f1) {
            self.closeModal();
        }
    }

    fn handleUserPickerInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();
        const user_count = self.otherUserCount();

        if (special == .escape) {
            self.closeModal();
            return;
        }

        if (user_count == 0) return;

        if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            self.user_picker_idx = @mod(self.user_picker_idx - 1 + @as(i32, @intCast(user_count)), @as(i32, @intCast(user_count)));
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            self.user_picker_idx = @mod(self.user_picker_idx + 1, @as(i32, @intCast(user_count)));
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .space) {
            // Toggle selection
            const idx: usize = @intCast(self.user_picker_idx);
            if (idx < types.MAX_USERS) {
                self.user_picker_selected[idx] = !self.user_picker_selected[idx];
                if (self.user_picker_selected[idx]) {
                    self.user_picker_sel_count += 1;
                } else {
                    if (self.user_picker_sel_count > 0) self.user_picker_sel_count -= 1;
                }
                self.dirty.markAll();
                self.render_requested = true;
            }
        } else if (special == .enter) {
            // Create DM with selected users
            if (self.user_picker_sel_count > 0) {
                var names: [types.MAX_USERS][]const u8 = undefined;
                var name_count: usize = 0;
                const others = self.getOtherUsers();
                for (others, 0..) |*u, i| {
                    if (i < types.MAX_USERS and self.user_picker_selected[i]) {
                        names[name_count] = u.nameSlice();
                        name_count += 1;
                    }
                }
                if (name_count > 0) {
                    _ = self.events.pushCreateDm(names[0..name_count]);
                }
            }
            self.closeModal();
        }
    }

    fn handleAddMemberInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();
        const user_count = self.otherUserCount();

        if (special == .escape) {
            self.closeModal();
            return;
        }

        if (user_count == 0) return;

        if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            self.add_member_idx = @mod(self.add_member_idx - 1 + @as(i32, @intCast(user_count)), @as(i32, @intCast(user_count)));
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            self.add_member_idx = @mod(self.add_member_idx + 1, @as(i32, @intCast(user_count)));
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .enter) {
            const others = self.getOtherUsers();
            const idx: usize = @intCast(self.add_member_idx);
            if (idx < others.len) {
                const name = others[idx].nameSlice();
                _ = self.events.pushTagged(.add_dm_member, name);
            }
            self.closeModal();
        }
    }

    fn handleReactionInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        if (special == .escape) {
            self.closeModal();
            return;
        }

        if (special == .left or (key.isChar() and key.charValue() == 'h')) {
            if (self.reaction_idx > 0) self.reaction_idx -= 1 else self.reaction_idx = 7;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .right or (key.isChar() and key.charValue() == 'l')) {
            if (self.reaction_idx < 7) self.reaction_idx += 1 else self.reaction_idx = 0;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .up) {
            if (self.reaction_idx >= 4) self.reaction_idx -= 4;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .down) {
            if (self.reaction_idx + 4 < 8) self.reaction_idx += 4;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .enter) {
            self.submitReaction();
        } else if (key.isChar() and !key.hasCtrl()) {
            // Number keys 1-8 for quick selection
            if (key.charValue()) |ch| {
                if (ch >= '1' and ch <= '8') {
                    self.reaction_idx = @intCast(ch - '1');
                    self.submitReaction();
                }
            }
        }
    }

    fn submitReaction(self: *ChatClient) void {
        if (self.reaction_target_msg < 0) {
            self.closeModal();
            return;
        }
        const target_idx: usize = @intCast(self.reaction_target_msg);
        if (target_idx >= self.messages.items.len) {
            self.closeModal();
            return;
        }
        const target_msg = &self.messages.items[target_idx];
        const msg_id = target_msg.idSlice();
        const emoji = types.REACTION_EMOJIS[self.reaction_idx];

        // Build event: tag(1) + msg_id_len(1) + msg_id + emoji
        var buf: [2 + 36 + 16]u8 = undefined;
        buf[0] = @intFromEnum(EventTag.toggle_reaction);
        buf[1] = @intCast(msg_id.len);
        @memcpy(buf[2 .. 2 + msg_id.len], msg_id);
        const emoji_len = emoji.len;
        @memcpy(buf[2 + msg_id.len .. 2 + msg_id.len + emoji_len], emoji);
        const total_len = 2 + msg_id.len + emoji_len;

        _ = self.events.push(buf[0..total_len]);
        self.closeModal();
    }

    fn handleSettingsMenuInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        if (special == .escape) {
            self.closeModal();
            return;
        }

        if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            if (self.settings_menu_idx > 0) {
                self.settings_menu_idx -= 1;
            } else {
                self.settings_menu_idx = SETTINGS_MENU_COUNT - 1;
            }
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            if (self.settings_menu_idx < SETTINGS_MENU_COUNT - 1) {
                self.settings_menu_idx += 1;
            } else {
                self.settings_menu_idx = 0;
            }
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .enter) {
            self.openSettingsSubEditor();
        }
    }

    fn openSettingsSubEditor(self: *ChatClient) void {
        switch (self.settings_menu_idx) {
            0 => {
                // Name editor — populate with current name
                if (self.settings_name_edit_buffer) |eb| {
                    eb.clear() catch {};
                    if (self.me) |me| {
                        eb.insertText(me.nameSlice()) catch {};
                    }
                }
                self.openModal(.settings_name);
            },
            1 => {
                // Color editor — set index from current color
                self.settings_color_idx = 0;
                if (self.me) |me| {
                    for (panel_render.COLOR_CHOICES, 0..) |c, i| {
                        if (colorsEqual(c, me.color)) {
                            self.settings_color_idx = @intCast(i);
                            break;
                        }
                    }
                }
                self.openModal(.settings_color);
            },
            2 => {
                // Theme editor — set index from current theme
                self.settings_theme_idx = 0;
                for (&theme_mod.themes, 0..) |t, i| {
                    if (std.mem.eql(u8, t.id, self.theme.id)) {
                        self.settings_theme_idx = @intCast(i);
                        break;
                    }
                }
                self.openModal(.settings_theme);
            },
            3 => {
                // Avatar editor
                self.settings_avatar_col = 0;
                self.settings_avatar_draft = .{ 0, 0, 0 };
                self.openModal(.settings_avatar);
            },
            4 => {
                // Keybindings editor — copy current bindings into draft
                self.settings_kb_idx = 0;
                self.settings_kb_listening = false;
                self.kb_draft = self.keybindings;
                self.openModal(.settings_keybindings);
            },
            5 => {
                // Layout editor — copy current layout into draft
                self.layout_editor_mode = .navigate;
                self.layout_cursor_col = 0;
                self.layout_cursor_row = 0;
                self.layout_panel_type_idx = 0;
                self.layout_error_len = 0;
                self.layout_draft_grid_cols = self.grid_cols;
                self.layout_draft_grid_rows = self.grid_rows;
                self.layout_draft_count = self.panel_count;
                @memcpy(self.layout_draft_panels[0..self.panel_count], self.panels[0..self.panel_count]);
                self.openModal(.settings_layout);
            },
            else => {},
        }
    }

    fn handleSettingsNameInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        if (special == .escape) {
            self.openModal(.settings_menu); // back to menu
            return;
        }

        if (special == .enter) {
            // Save name
            if (self.settings_name_edit_buffer) |eb| {
                const name_len = eb.getText(&_get_text_buf);
                if (name_len > 0 and name_len <= types.MAX_NAME_LEN) {
                    const new_name = _get_text_buf[0..name_len];
                    // Apply locally for immediate feedback
                    if (self.me) |*me| {
                        @memcpy(me.name[0..name_len], new_name);
                        me.name_len = @intCast(name_len);
                    }
                    _ = self.events.pushUpdateProfile("name", new_name);
                }
            }
            self.openModal(.settings_menu); // back to menu
            return;
        }

        // Delegate to editor for text input
        if (self.settings_name_edit_buffer) |eb| {
            self.handleEditorInput(eb, key);
            self.dirty.markAll();
            self.render_requested = true;
        }
    }

    fn handleSettingsColorInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        if (special == .escape) {
            self.openModal(.settings_menu);
            return;
        }

        if (special == .left or (key.isChar() and key.charValue() == 'h')) {
            if (self.settings_color_idx > 0) self.settings_color_idx -= 1 else self.settings_color_idx = 7;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .right or (key.isChar() and key.charValue() == 'l')) {
            if (self.settings_color_idx < 7) self.settings_color_idx += 1 else self.settings_color_idx = 0;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .enter) {
            // Save color — convert RGBA to hex string
            const color = panel_render.COLOR_CHOICES[self.settings_color_idx];
            // Apply locally for immediate feedback
            if (self.me) |*me| {
                me.color = color;
            }
            var hex_buf: [7]u8 = undefined;
            _ = std.fmt.bufPrint(&hex_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{
                @as(u8, @intFromFloat(color[0] * 255.0)),
                @as(u8, @intFromFloat(color[1] * 255.0)),
                @as(u8, @intFromFloat(color[2] * 255.0)),
            }) catch {};
            _ = self.events.pushUpdateProfile("color", &hex_buf);
            self.openModal(.settings_menu);
        }
    }

    fn handleSettingsThemeInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        if (special == .escape) {
            self.openModal(.settings_menu);
            return;
        }

        if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            if (self.settings_theme_idx > 0) self.settings_theme_idx -= 1 else self.settings_theme_idx = @intCast(theme_mod.themes.len - 1);
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            if (self.settings_theme_idx < theme_mod.themes.len - 1) self.settings_theme_idx += 1 else self.settings_theme_idx = 0;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .enter) {
            const theme_entry = &theme_mod.themes[self.settings_theme_idx];
            self.setTheme(theme_entry.id); // apply immediately for instant feedback
            _ = self.events.pushUpdateProfile("theme", theme_entry.id);
            self.openModal(.settings_menu);
        }
    }

    fn handleSettingsKeybindingsInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        // --- Capture mode: next keypress becomes the new binding ---
        if (self.settings_kb_listening) {
            // Build a KeyCombo from the captured keypress
            var combo: types.KeyCombo = .{
                .tag = key.tag,
                .code = key.code,
                .ctrl = key.hasCtrl(),
                .shift = key.hasShift(),
            };
            // Normalise: if it's a shifted letter codepoint, store as lowercase + shift
            if (combo.tag == 0 and combo.code >= 'A' and combo.code <= 'Z') {
                combo.code = combo.code + 32; // lowercase
                combo.shift = true;
            }
            if (self.settings_kb_idx < types.BINDABLE_COMMAND_COUNT) {
                self.kb_draft[self.settings_kb_idx] = combo;
            }
            self.settings_kb_listening = false;
            self.dirty.markAll();
            self.render_requested = true;
            return;
        }

        // Escape → back to settings menu (discards draft)
        if (special == .escape) {
            self.openModal(.settings_menu);
            return;
        }

        // Up/Down (or k/j) → navigate
        if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            if (self.settings_kb_idx > 0) {
                self.settings_kb_idx -= 1;
            } else {
                self.settings_kb_idx = types.BINDABLE_COMMAND_COUNT - 1;
            }
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            if (self.settings_kb_idx < types.BINDABLE_COMMAND_COUNT - 1) {
                self.settings_kb_idx += 1;
            } else {
                self.settings_kb_idx = 0;
            }
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .enter) {
            // Enter → start listening for a new key combo
            self.settings_kb_listening = true;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (key.isChar() and !key.hasCtrl()) {
            if (key.charValue()) |ch| {
                if (ch == 'r') {
                    // Reset selected binding to default
                    if (self.settings_kb_idx < types.BINDABLE_COMMAND_COUNT) {
                        self.kb_draft[self.settings_kb_idx] = types.DEFAULT_KEYBINDINGS[self.settings_kb_idx];
                    }
                    self.dirty.markAll();
                    self.render_requested = true;
                } else if (ch == 's') {
                    // Save keybindings — apply draft and emit to TS
                    self.keybindings = self.kb_draft;
                    self.emitKeybindingsUpdate();
                    self.closeModal();
                }
            }
        }
    }

    fn handleSettingsLayoutInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();
        const gc = self.layout_draft_grid_cols;
        const gr = self.layout_draft_grid_rows;

        switch (self.layout_editor_mode) {
            .navigate => {
                // Escape → back to settings menu (discard draft)
                if (special == .escape) {
                    self.openModal(.settings_menu);
                    return;
                }

                // Arrow keys → move cursor
                if (special == .up) {
                    if (self.layout_cursor_row > 0) self.layout_cursor_row -= 1;
                } else if (special == .down) {
                    if (self.layout_cursor_row < gr - 1) self.layout_cursor_row += 1;
                } else if (special == .left) {
                    if (self.layout_cursor_col > 0) self.layout_cursor_col -= 1;
                } else if (special == .right) {
                    if (self.layout_cursor_col < gc - 1) self.layout_cursor_col += 1;
                }

                if (key.isChar() and !key.hasCtrl()) {
                    if (key.charValue()) |ch| {
                        switch (ch) {
                            'a' => {
                                // Add panel → enter select_panel mode
                                self.layout_editor_mode = .select_panel;
                                self.layout_panel_type_idx = 0;
                                self.layout_error_len = 0;
                            },
                            'd' => {
                                // Delete panel under cursor
                                if (layout_mod.cellOccupant(&self.layout_draft_panels, self.layout_draft_count, self.layout_cursor_col, self.layout_cursor_row)) |idx| {
                                    self.removeLayoutDraftPanel(idx);
                                    self.layout_error_len = 0;
                                }
                            },
                            'r' => {
                                // Reset to default layout
                                self.layout_draft_count = layout_mod.initDefaultLayout(&self.layout_draft_panels);
                                self.layout_draft_grid_cols = layout_mod.DEFAULT_GRID_COLS;
                                self.layout_draft_grid_rows = layout_mod.DEFAULT_GRID_ROWS;
                                self.layout_cursor_col = 0;
                                self.layout_cursor_row = 0;
                                self.layout_error_len = 0;
                            },
                            's' => {
                                // Save — validate then apply
                                if (!layout_mod.validateLayout(&self.layout_draft_panels, self.layout_draft_count)) {
                                    self.setLayoutError("Need messages + compose");
                                } else {
                                    // Apply draft to live layout
                                    self.panel_count = self.layout_draft_count;
                                    @memcpy(self.panels[0..self.panel_count], self.layout_draft_panels[0..self.layout_draft_count]);
                                    self.grid_cols = self.layout_draft_grid_cols;
                                    self.grid_rows = self.layout_draft_grid_rows;
                                    self.dirty.layout = true;
                                    // Fix focus if it's out of range
                                    if (self.focus_idx >= self.panel_count) {
                                        self.focus_idx = self.findPanelByKind(.compose) orelse 0;
                                    }
                                    self.emitLayoutUpdate();
                                    self.closeModal();
                                }
                            },
                            '[' => {
                                // Decrease grid cols
                                if (self.layout_draft_grid_cols > layout_mod.MIN_GRID) {
                                    self.layout_draft_grid_cols -= 1;
                                    self.clampLayoutCursor();
                                }
                            },
                            ']' => {
                                // Increase grid cols
                                if (self.layout_draft_grid_cols < layout_mod.MAX_GRID) {
                                    self.layout_draft_grid_cols += 1;
                                }
                            },
                            '-' => {
                                // Decrease grid rows
                                if (self.layout_draft_grid_rows > layout_mod.MIN_GRID) {
                                    self.layout_draft_grid_rows -= 1;
                                    self.clampLayoutCursor();
                                }
                            },
                            '=' => {
                                // Increase grid rows
                                if (self.layout_draft_grid_rows < layout_mod.MAX_GRID) {
                                    self.layout_draft_grid_rows += 1;
                                }
                            },
                            else => {},
                        }
                    }
                }

                self.dirty.markAll();
                self.render_requested = true;
            },

            .select_panel => {
                // Escape → back to navigate
                if (special == .escape) {
                    self.layout_editor_mode = .navigate;
                    self.dirty.markAll();
                    self.render_requested = true;
                    return;
                }

                // Up/Down → cycle panel type
                if (special == .up) {
                    if (self.layout_panel_type_idx > 0) {
                        self.layout_panel_type_idx -= 1;
                    } else {
                        self.layout_panel_type_idx = types.PANEL_TYPE_COUNT - 1;
                    }
                } else if (special == .down) {
                    if (self.layout_panel_type_idx < types.PANEL_TYPE_COUNT - 1) {
                        self.layout_panel_type_idx += 1;
                    } else {
                        self.layout_panel_type_idx = 0;
                    }
                } else if (special == .enter) {
                    // Confirm selection → move to place mode, anchor at cursor
                    self.layout_anchor_col = self.layout_cursor_col;
                    self.layout_anchor_row = self.layout_cursor_row;
                    self.layout_editor_mode = .place;
                }

                self.dirty.markAll();
                self.render_requested = true;
            },

            .place => {
                // Escape → back to navigate
                if (special == .escape) {
                    self.layout_editor_mode = .navigate;
                    self.dirty.markAll();
                    self.render_requested = true;
                    return;
                }

                // Arrow keys → extend selection rectangle
                if (special == .up) {
                    if (self.layout_cursor_row > 0) self.layout_cursor_row -= 1;
                } else if (special == .down) {
                    if (self.layout_cursor_row < gr - 1) self.layout_cursor_row += 1;
                } else if (special == .left) {
                    if (self.layout_cursor_col > 0) self.layout_cursor_col -= 1;
                } else if (special == .right) {
                    if (self.layout_cursor_col < gc - 1) self.layout_cursor_col += 1;
                } else if (special == .enter) {
                    // Place panel in the selected rectangle
                    const min_col = @min(self.layout_anchor_col, self.layout_cursor_col);
                    const max_col = @max(self.layout_anchor_col, self.layout_cursor_col);
                    const min_row = @min(self.layout_anchor_row, self.layout_cursor_row);
                    const max_row = @max(self.layout_anchor_row, self.layout_cursor_row);
                    const cs = max_col - min_col + 1;
                    const rs = max_row - min_row + 1;

                    // Check for overlap
                    if (layout_mod.hasOverlap(&self.layout_draft_panels, self.layout_draft_count, min_col, min_row, cs, rs)) {
                        self.setLayoutError("Overlaps existing panel");
                    } else if (self.layout_draft_count >= types.MAX_PANELS) {
                        self.setLayoutError("Max panels reached");
                    } else {
                        // Place the panel
                        const kind: types.PanelKind = @enumFromInt(self.layout_panel_type_idx);
                        self.layout_draft_panels[self.layout_draft_count] = .{
                            .kind = kind,
                            .col = min_col,
                            .row = min_row,
                            .col_span = cs,
                            .row_span = rs,
                            .group = 0,
                        };
                        self.layout_draft_count += 1;
                        self.layout_error_len = 0;
                        self.layout_editor_mode = .navigate;
                    }
                }

                self.dirty.markAll();
                self.render_requested = true;
            },
        }
    }

    fn removeLayoutDraftPanel(self: *ChatClient, idx: u8) void {
        if (idx >= self.layout_draft_count) return;
        // Shift remaining panels down
        const count = self.layout_draft_count;
        var i: u8 = idx;
        while (i + 1 < count) : (i += 1) {
            self.layout_draft_panels[i] = self.layout_draft_panels[i + 1];
        }
        self.layout_draft_count -= 1;
    }

    fn setLayoutError(self: *ChatClient, msg: []const u8) void {
        const len = @min(msg.len, self.layout_error.len);
        @memcpy(self.layout_error[0..len], msg[0..len]);
        self.layout_error_len = @intCast(len);
    }

    fn clampLayoutCursor(self: *ChatClient) void {
        if (self.layout_cursor_col >= self.layout_draft_grid_cols) {
            self.layout_cursor_col = self.layout_draft_grid_cols - 1;
        }
        if (self.layout_cursor_row >= self.layout_draft_grid_rows) {
            self.layout_cursor_row = self.layout_draft_grid_rows - 1;
        }
    }

    /// Emit the current layout as a JSON string via update_profile event.
    fn emitLayoutUpdate(self: *ChatClient) void {
        var json_buf: [4096]u8 = undefined;
        var pos: usize = 0;

        // {"gridCols":N,"gridRows":N,"panels":[...]}
        const prefix = "{\"gridCols\":";
        @memcpy(json_buf[pos .. pos + prefix.len], prefix);
        pos += prefix.len;
        pos += writeU16(json_buf[pos..], self.grid_cols);

        const mid1 = ",\"gridRows\":";
        @memcpy(json_buf[pos .. pos + mid1.len], mid1);
        pos += mid1.len;
        pos += writeU16(json_buf[pos..], self.grid_rows);

        const mid2 = ",\"panels\":[";
        @memcpy(json_buf[pos .. pos + mid2.len], mid2);
        pos += mid2.len;

        for (self.panels[0..self.panel_count], 0..) |*p, i| {
            if (i > 0) {
                json_buf[pos] = ',';
                pos += 1;
            }
            pos += self.formatPanelJson(p, json_buf[pos..]);
        }

        json_buf[pos] = ']';
        pos += 1;
        json_buf[pos] = '}';
        pos += 1;

        _ = self.events.pushUpdateProfile("layout", json_buf[0..pos]);
    }

    fn formatPanelJson(_: *const ChatClient, p: *const Panel, out: []u8) usize {
        var pos: usize = 0;
        // {"type":"kind","col":N,"row":N,"colSpan":N,"rowSpan":N}
        const kind_names = [_][]const u8{ "header", "messages", "compose", "channels", "members" };
        const kind_name = kind_names[@intFromEnum(p.kind)];

        const t1 = "{\"type\":\"";
        @memcpy(out[pos .. pos + t1.len], t1);
        pos += t1.len;
        @memcpy(out[pos .. pos + kind_name.len], kind_name);
        pos += kind_name.len;

        const t2 = "\",\"col\":";
        @memcpy(out[pos .. pos + t2.len], t2);
        pos += t2.len;
        pos += writeU16(out[pos..], p.col);

        const t3 = ",\"row\":";
        @memcpy(out[pos .. pos + t3.len], t3);
        pos += t3.len;
        pos += writeU16(out[pos..], p.row);

        const t4 = ",\"colSpan\":";
        @memcpy(out[pos .. pos + t4.len], t4);
        pos += t4.len;
        pos += writeU16(out[pos..], p.col_span);

        const t5 = ",\"rowSpan\":";
        @memcpy(out[pos .. pos + t5.len], t5);
        pos += t5.len;
        pos += writeU16(out[pos..], p.row_span);

        out[pos] = '}';
        pos += 1;
        return pos;
    }

    fn handleSettingsAvatarInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        if (special == .escape) {
            self.openModal(.settings_menu);
            return;
        }

        if (special == .enter) {
            // Save avatar pattern — encode 3 glyph indices as UTF-8 string
            var pattern_buf: [12]u8 = undefined; // max 3 glyphs × 3 bytes each
            var pattern_len: usize = 0;
            for (0..3) |col| {
                const glyph_idx = self.settings_avatar_draft[col] % types.AVATAR_GLYPH_COUNT;
                const glyph = types.AVATAR_GLYPHS[glyph_idx];
                @memcpy(pattern_buf[pattern_len .. pattern_len + glyph.len], glyph);
                pattern_len += glyph.len;
            }
            _ = self.events.pushUpdateProfile("avatarPattern", pattern_buf[0..pattern_len]);
            self.closeModal();
            return;
        }

        // Left/Right to move cursor between glyph columns
        if (special == .left or (key.isChar() and key.charValue() == 'h')) {
            if (self.settings_avatar_col > 0) self.settings_avatar_col -= 1 else self.settings_avatar_col = 2;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .right or (key.isChar() and key.charValue() == 'l')) {
            if (self.settings_avatar_col < 2) self.settings_avatar_col += 1 else self.settings_avatar_col = 0;
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            // Cycle glyph at current column
            if (self.settings_avatar_draft[self.settings_avatar_col] > 0) {
                self.settings_avatar_draft[self.settings_avatar_col] -= 1;
            } else {
                self.settings_avatar_draft[self.settings_avatar_col] = types.AVATAR_GLYPH_COUNT - 1;
            }
            self.dirty.markAll();
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            if (self.settings_avatar_draft[self.settings_avatar_col] < types.AVATAR_GLYPH_COUNT - 1) {
                self.settings_avatar_draft[self.settings_avatar_col] += 1;
            } else {
                self.settings_avatar_draft[self.settings_avatar_col] = 0;
            }
            self.dirty.markAll();
            self.render_requested = true;
        }
    }

    // ---------------------------------------------------------------
    // Modal openers
    // ---------------------------------------------------------------

    fn openSettingsMenu(self: *ChatClient) void {
        self.settings_menu_idx = 0;
        self.openModal(.settings_menu);
    }

    fn openUserPicker(self: *ChatClient) void {
        self.user_picker_idx = 0;
        self.user_picker_sel_count = 0;
        self.user_picker_selected = [_]bool{false} ** types.MAX_USERS;
        self.openModal(.users);
    }

    fn openAddMember(self: *ChatClient) void {
        // Only open if in a DM channel
        const chan = self.currentChannelSlice();
        if (chan.len > 3 and std.mem.startsWith(u8, chan, "dm-")) {
            self.add_member_idx = 0;
            self.openModal(.add_member);
        }
    }

    fn openReactionPicker(self: *ChatClient) void {
        self.reaction_idx = 0;
        // Target the selected message or last message
        if (self.selected_msg_idx >= 0) {
            self.reaction_target_msg = self.selected_msg_idx;
        } else if (self.messages.items.len > 0) {
            self.reaction_target_msg = @intCast(self.messages.items.len - 1);
        } else {
            return; // no messages to react to
        }
        self.openModal(.reaction);
    }

    // ---------------------------------------------------------------
    // Panel-specific input
    // ---------------------------------------------------------------

    fn handleComposeInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        // --- Slash autocomplete navigation (intercepts keys when open) ---
        if (self.slash_ac_open and self.slash_ac_filtered_count > 0) {
            const count = self.slash_ac_filtered_count;

            if (special == .escape) {
                self.slash_ac_open = false;
                self.slash_ac_idx = 0;
                self.slash_ac_filtered_count = 0;
                self.dirty.compose = true;
                self.render_requested = true;
                return;
            }

            if (special == .up) {
                self.slash_ac_idx = if (self.slash_ac_idx == 0) count - 1 else self.slash_ac_idx - 1;
                self.dirty.compose = true;
                self.render_requested = true;
                return;
            }

            if (special == .down) {
                self.slash_ac_idx = (self.slash_ac_idx + 1) % count;
                self.dirty.compose = true;
                self.render_requested = true;
                return;
            }

            if (special == .tab or (special == .enter and !key.hasShift() and !key.hasCtrl())) {
                const cmd_idx = self.slash_ac_filtered[self.slash_ac_idx];
                self.executeSlashCommand(cmd_idx);
                return;
            }
        }

        // Enter (without Shift or Ctrl) → send message
        if (special == .enter and !key.hasShift() and !key.hasCtrl()) {
            self.sendCurrentMessage();
            // Emit typing_stop when message is sent
            if (self.compose_is_typing) {
                self.compose_is_typing = false;
                _ = self.events.pushTagged(.typing_stop, "");
            }
            return;
        }

        // Delegate to EditBuffer for text editing
        if (self.compose_edit_buffer) |eb| {
            self.handleEditorInput(eb, key);
            self.dirty.compose = true;
            self.render_requested = true;

            // Update slash autocomplete filter after text change
            self.updateSlashFilter();

            // Emit typing_start on first keypress in compose
            if (!self.compose_is_typing) {
                self.compose_is_typing = true;
                _ = self.events.pushTagged(.typing_start, "");
            }
        }
    }

    fn handleChannelsInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();
        const channel_count: i32 = @intCast(self.channels.items.len);
        if (channel_count == 0) return;

        if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            self.channel_sel_idx = @mod(self.channel_sel_idx - 1 + channel_count, channel_count);
            self.dirty.channels = true;
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            self.channel_sel_idx = @mod(self.channel_sel_idx + 1, channel_count);
            self.dirty.channels = true;
            self.render_requested = true;
         } else if (special == .enter) {
            // Switch to selected channel
            const idx: usize = @intCast(self.channel_sel_idx);
            if (idx < self.channels.items.len) {
                const chan = &self.channels.items[idx];
                chan.unread_count = 0; // clear unread badge
                const name = chan.nameSlice();
                @memcpy(self.current_channel[0..name.len], name);
                self.current_channel_len = @intCast(name.len);
                _ = self.events.pushTagged(.switch_channel, name);
                self.dirty.channels = true;
                self.dirty.compose = true;
                self.dirty.messages = true;
                self.render_requested = true;
            }
        }
    }

    fn handleMembersInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();
        const user_count: i32 = @intCast(self.users.items.len);
        if (user_count == 0) return;

        if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            self.member_sel_idx = @mod(self.member_sel_idx - 1 + user_count, user_count);
            self.dirty.members = true;
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            self.member_sel_idx = @mod(self.member_sel_idx + 1, user_count);
            self.dirty.members = true;
            self.render_requested = true;
        }
    }

    fn handleMessagesInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();
        const msg_count: i32 = @intCast(self.messages.items.len);
        if (msg_count == 0) return;

        if (special == .up or (key.isChar() and key.charValue() == 'k')) {
            // Select previous message
            if (self.selected_msg_idx < 0) {
                self.selected_msg_idx = msg_count - 1;
            } else if (self.selected_msg_idx > 0) {
                self.selected_msg_idx -= 1;
            }
            // Auto-scroll to keep selection visible
            self.scrollToShowSelection();
            self.dirty.messages = true;
            self.render_requested = true;
        } else if (special == .down or (key.isChar() and key.charValue() == 'j')) {
            if (self.selected_msg_idx >= 0) {
                if (self.selected_msg_idx < msg_count - 1) {
                    self.selected_msg_idx += 1;
                } else {
                    self.selected_msg_idx = -1; // deselect
                }
            }
            // Auto-scroll to keep selection visible
            self.scrollToShowSelection();
            self.dirty.messages = true;
            self.render_requested = true;
        }
        // Note: Page Up/Down handled globally in handleChatInput
    }

    /// Scroll messages by delta rows (positive = up/older, negative = down/newer).
    /// Clamps to valid range [0, max_offset].
    fn scrollMessages(self: *ChatClient, delta: i32) void {
        const msg_count: i32 = @intCast(self.messages.items.len);
        if (msg_count == 0) return;
        const max_offset = self.maxScrollOffset();
        self.msg_scroll_offset = @max(0, @min(max_offset, self.msg_scroll_offset + delta));
        // Clear unread divider when user scrolls back to the bottom
        if (self.msg_scroll_offset == 0) {
            self.unread_divider_idx = -1;
        }
        self.dirty.messages = true;
        self.render_requested = true;
    }

    /// Compute the maximum valid scroll offset (total rows - visible rows, minimum 0).
    fn maxScrollOffset(self: *const ChatClient) i32 {
        const panel_idx = self.findPanelByKind(.messages) orelse return 0;
        const panel = &self.panels[panel_idx];
        const visible_rows: usize = panel.innerHeight();
        const available_width: usize = panel.innerWidth();
        if (visible_rows == 0 or available_width == 0) return 0;
        const total_rows = self.totalMessageRows(available_width);
        if (total_rows <= visible_rows) return 0;
        return @intCast(total_rows - visible_rows);
    }

    /// Get the inner height of the messages panel (visible rows for messages).
    fn messagesVisibleRows(self: *const ChatClient) usize {
        if (self.findPanelByKind(.messages)) |idx| {
            return self.panels[idx].innerHeight();
        }
        return 0;
    }

    /// Number of extra columns used by avatar display (3 glyphs + 1 space, or 0 if disabled).
    pub fn avatarCols(self: *const ChatClient) usize {
        return if (self.show_avatars) 4 else 0;
    }

    /// Total display rows across all messages (accounts for word wrap).
    fn totalMessageRows(self: *const ChatClient, available_width: usize) usize {
        const acols = self.avatarCols();
        var total: usize = 0;
        for (self.messages.items) |*msg| {
            total += types.msgRowCountWithAvatar(msg, available_width, acols);
        }
        return total;
    }

    /// Adjust scroll offset so the selected message is within the visible window.
    fn scrollToShowSelection(self: *ChatClient) void {
        if (self.selected_msg_idx < 0) return;
        const sel: usize = @intCast(self.selected_msg_idx);
        const msgs = self.messages.items;
        if (sel >= msgs.len) return;

        const visible_rows = self.messagesVisibleRows();
        if (visible_rows == 0) return;
        const available_width: usize = @intCast(if (self.findPanelByKind(.messages)) |idx| self.panels[idx].innerWidth() else return);
        const acols = self.avatarCols();

        // Calculate the row range of the selected message (from bottom)
        // Row 0 = bottom-most row of the last message
        var rows_from_bottom: usize = 0;
        var i: usize = msgs.len;
        while (i > sel) {
            i -= 1;
            rows_from_bottom += types.msgRowCountWithAvatar(&msgs[i], available_width, acols);
        }
        // rows_from_bottom now points to the TOP of the selected message
        const sel_rows = types.msgRowCountWithAvatar(&msgs[sel], available_width, acols);
        // The selected message occupies rows [rows_from_bottom - sel_rows + 1 .. rows_from_bottom] from bottom
        // But we computed by summing messages BELOW sel, so rows_from_bottom = total rows below sel (exclusive)
        // Actually: rows_from_bottom = sum of rows for msgs[sel+1..len]
        // The selected message's bottom row is at offset = rows_from_bottom
        // The selected message's top row is at offset = rows_from_bottom + sel_rows - 1

        const sel_bottom = rows_from_bottom;
        const sel_top = rows_from_bottom + sel_rows - 1;
        const offset: usize = @intCast(@max(0, self.msg_scroll_offset));

        // If selected message top is above the visible window, scroll up
        if (sel_top >= offset + visible_rows) {
            self.msg_scroll_offset = @intCast(sel_top - visible_rows + 1);
        }
        // If selected message bottom is below the visible window, scroll down
        if (sel_bottom < offset) {
            self.msg_scroll_offset = @intCast(sel_bottom);
        }
    }

    /// Route a key event to an EditBuffer for text editing operations
    fn handleEditorInput(self: *ChatClient, eb: *EditBuffer, key: KeyEvent) void {
        _ = self;
        const special = key.specialKey();

        if (special) |sp| {
            switch (sp) {
                .backspace => eb.backspace() catch {},
                .delete => eb.deleteForward() catch {},
                .left => {
                    if (key.hasCtrl()) {
                        // Move word left: getCursor → getPrevWordBoundary → setCursor
                        const boundary = eb.getPrevWordBoundary();
                        eb.setCursor(boundary.row, boundary.col) catch {};
                    } else {
                        eb.moveLeft();
                    }
                },
                .right => {
                    if (key.hasCtrl()) {
                        const boundary = eb.getNextWordBoundary();
                        eb.setCursor(boundary.row, boundary.col) catch {};
                    } else {
                        eb.moveRight();
                    }
                },
                .home => {
                    eb.setCursor(0, 0) catch {};
                },
                .end => {
                    const eol = eb.getEOL();
                    eb.setCursor(eol.row, eol.col) catch {};
                },
                .enter => {
                    // Ctrl+Enter or Shift+Enter → insert newline
                    if (key.hasCtrl() or key.hasShift()) {
                        eb.insertText("\n") catch {};
                    }
                },
                .space => {
                    eb.insertText(" ") catch {};
                },
                else => {},
            }
        } else if (key.isChar()) {
            // Regular character input
            if (key.charValue()) |codepoint| {
                if (key.hasCtrl()) return; // don't insert ctrl+letter as text
                // Shift+letter → uppercase (parseKeypress lowercases shifted letters)
                const actual = if (key.hasShift() and codepoint >= 'a' and codepoint <= 'z')
                    codepoint - 32
                else
                    codepoint;
                // Encode codepoint to UTF-8 and insert
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(actual, &buf) catch return;
                eb.insertText(buf[0..len]) catch {};
            }
        }
    }

    fn sendCurrentMessage(self: *ChatClient) void {
        if (self.compose_edit_buffer) |eb| {
            const len = eb.getText(&_get_text_buf);
            if (len == 0) return;
            _ = self.events.pushSendMessage(
                self.currentChannelSlice(),
                _get_text_buf[0..len],
            );
            eb.clear() catch {};
            self.dirty.compose = true;
            self.render_requested = true;
        }
    }

    fn cycleFocus(self: *ChatClient, forward: bool) void {
        if (self.panel_count == 0) return;

        // Find all focusable panels
        var focusable: [types.MAX_PANELS]u8 = undefined;
        var focusable_count: u8 = 0;
        for (self.panels[0..self.panel_count], 0..) |*p, i| {
            if (p.isFocusable()) {
                focusable[focusable_count] = @intCast(i);
                focusable_count += 1;
            }
        }
        if (focusable_count == 0) return;

        // Find current position in focusable list
        var current_pos: u8 = 0;
        for (focusable[0..focusable_count], 0..) |fi, i| {
            if (fi == self.focus_idx) {
                current_pos = @intCast(i);
                break;
            }
        }

        // Advance
        if (forward) {
            current_pos = (current_pos + 1) % focusable_count;
        } else {
            current_pos = (current_pos + focusable_count - 1) % focusable_count;
        }

        const old_focus = self.focus_idx;
        self.focus_idx = focusable[current_pos];

        if (old_focus != self.focus_idx) {
            // Mark both old and new panels dirty
            if (old_focus < self.panel_count) {
                self.markPanelDirty(self.panels[old_focus].kind);
            }
            self.markPanelDirty(self.panels[self.focus_idx].kind);
            // Notify TS about focus change
            const kind_byte: [1]u8 = .{@intFromEnum(self.panels[self.focus_idx].kind)};
            _ = self.events.pushTagged(.focus_changed, &kind_byte);
            self.render_requested = true;
        }
    }

    fn switchToPrevChannel(self: *ChatClient) void {
        const count: i32 = @intCast(self.channels.items.len);
        if (count <= 1) return;
        self.channel_sel_idx = @mod(self.channel_sel_idx - 1 + count, count);
        self.selectCurrentChannelByIdx();
    }

    fn switchToNextChannel(self: *ChatClient) void {
        const count: i32 = @intCast(self.channels.items.len);
        if (count <= 1) return;
        self.channel_sel_idx = @mod(self.channel_sel_idx + 1, count);
        self.selectCurrentChannelByIdx();
    }

    fn selectCurrentChannelByIdx(self: *ChatClient) void {
        const idx: usize = @intCast(self.channel_sel_idx);
        if (idx < self.channels.items.len) {
            const chan = &self.channels.items[idx];
            const name = chan.nameSlice();
            @memcpy(self.current_channel[0..name.len], name);
            self.current_channel_len = @intCast(name.len);
            _ = self.events.pushTagged(.switch_channel, name);
            self.dirty.channels = true;
            self.dirty.compose = true;
            self.dirty.messages = true;
            self.render_requested = true;
        }
    }

    fn markPanelDirty(self: *ChatClient, kind: PanelKind) void {
        switch (kind) {
            .header => self.dirty.header = true,
            .messages => self.dirty.messages = true,
            .compose => self.dirty.compose = true,
            .channels => self.dirty.channels = true,
            .members => self.dirty.members = true,
        }
    }

    // ---------------------------------------------------------------
    // User helpers
    // ---------------------------------------------------------------

    fn otherUserCount(self: *const ChatClient) usize {
        var count: usize = 0;
        for (self.users.items) |*u| {
            if (self.me) |me| {
                if (std.mem.eql(u8, u.nameSlice(), me.nameSlice())) continue;
            }
            count += 1;
        }
        return count;
    }

    pub fn getOtherUsers(self: *const ChatClient) []const User {
        // Returns a view of users excluding self — but since we can't
        // easily return a filtered slice, callers should iterate and skip self.
        // This returns the full list; callers must check.
        return self.users.items;
    }

    // ---------------------------------------------------------------
    // Rendering
    // ---------------------------------------------------------------

    /// Render a frame if needed. Returns true if a frame was emitted.
    pub fn render(self: *ChatClient) bool {
        if (!self.render_requested and !self.dirty.any()) return false;
        self.render_requested = false;

        // Recompute layout if needed
        if (self.dirty.layout) {
            layout_mod.computeLayout(
                self.panels[0..self.panel_count],
                self.width,
                self.height,
                self.grid_cols,
                self.grid_rows,
            );
            self.dirty.layout = false;
            self.dirty.full = true;
        }

        const buf = self.renderer.getNextBuffer();
        const t = self.theme;

        // Clear background on full redraw
        if (self.dirty.full) {
            buf.fillRect(0, 0, @intCast(self.width), @intCast(self.height), t.background) catch {};
        }

        // Draw each panel — always redraw ALL visible panels because
        // getNextBuffer() returns a blank buffer and the diff engine
        // will clear any region we skip.
        switch (self.screen) {
            .loading => panel_render.renderLoadingScreen(self, buf),
            .chat => {
                for (self.panels[0..self.panel_count]) |*p| {
                    if (!p.visible) continue;
                    panel_render.renderPanel(self, p, buf);
                }
                // Render slash autocomplete popup above compose panel
                if (self.slash_ac_open and self.slash_ac_filtered_count > 0) {
                    panel_render.renderSlashAutocomplete(self, buf);
                }
                // Render modal overlay on top
                if (self.modal != .none) {
                    panel_render.renderModal(self, buf);
                } else if (self.show_help) {
                    // Legacy help toggle (F1 without modal system)
                    panel_render.renderModal(self, buf);
                }
            },
        }

        // Clear dirty flags
        self.dirty.clear();

        // Diff and emit ANSI
        self.renderer.render(false);
        return true;
    }

    // ---------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------

    pub fn findPanelByKind(self: *const ChatClient, kind: PanelKind) ?u8 {
        for (self.panels[0..self.panel_count], 0..) |*p, i| {
            if (p.kind == kind and p.visible) return @intCast(i);
        }
        return null;
    }

    pub fn focusedPanel(self: *const ChatClient) ?*const Panel {
        if (self.focus_idx < self.panel_count) {
            return &self.panels[self.focus_idx];
        }
        return null;
    }

    pub fn isFocused(self: *const ChatClient, panel: *const Panel) bool {
        if (self.focusedPanel()) |fp| {
            return fp == panel;
        }
        return false;
    }

    pub fn currentChannelSlice(self: *const ChatClient) []const u8 {
        return self.current_channel[0..self.current_channel_len];
    }

    fn colorsEqual(a: RGBA, b: RGBA) bool {
        return @abs(a[0] - b[0]) < 0.01 and
            @abs(a[1] - b[1]) < 0.01 and
            @abs(a[2] - b[2]) < 0.01;
    }

    // ---------------------------------------------------------------
    // Slash command autocomplete
    // ---------------------------------------------------------------

    /// Simple fuzzy match: every character in query appears in order in target.
    fn fuzzyMatch(query: []const u8, target: []const u8) bool {
        var qi: usize = 0;
        for (target) |tc| {
            if (qi >= query.len) break;
            // Case-insensitive compare
            const qc = if (query[qi] >= 'A' and query[qi] <= 'Z') query[qi] + 32 else query[qi];
            const tl = if (tc >= 'A' and tc <= 'Z') tc + 32 else tc;
            if (qc == tl) qi += 1;
        }
        return qi >= query.len;
    }

    /// Re-filter the slash command list based on current compose text.
    fn updateSlashFilter(self: *ChatClient) void {
        self.slash_ac_filtered_count = 0;
        if (self.compose_edit_buffer == null) return;
        const eb = self.compose_edit_buffer.?;
        const len = eb.getText(&_get_text_buf);
        if (len == 0 or _get_text_buf[0] != '/') {
            self.slash_ac_open = false;
            return;
        }
        // Check for space — close autocomplete if user typed a space (entering args)
        for (_get_text_buf[1..len]) |c| {
            if (c == ' ') {
                self.slash_ac_open = false;
                return;
            }
        }
        const query = _get_text_buf[1..len]; // text after '/'
        for (types.SLASH_COMMANDS, 0..) |cmd, i| {
            if (query.len == 0 or fuzzyMatch(query, cmd.name)) {
                if (self.slash_ac_filtered_count < types.SLASH_COMMAND_COUNT) {
                    self.slash_ac_filtered[self.slash_ac_filtered_count] = @intCast(i);
                    self.slash_ac_filtered_count += 1;
                }
            }
        }
        if (self.slash_ac_filtered_count == 0) {
            self.slash_ac_open = false;
        } else {
            self.slash_ac_open = true;
            // Clamp selection index
            if (self.slash_ac_idx >= self.slash_ac_filtered_count) {
                self.slash_ac_idx = self.slash_ac_filtered_count - 1;
            }
        }
    }

    /// Execute the selected slash command (replace compose text with /command and optionally send).
    fn executeSlashCommand(self: *ChatClient, cmd_idx: usize) void {
        if (cmd_idx >= types.SLASH_COMMAND_COUNT) return;
        const cmd = &types.SLASH_COMMANDS[cmd_idx];

        // Close autocomplete
        self.slash_ac_open = false;
        self.slash_ac_idx = 0;
        self.slash_ac_filtered_count = 0;

        // Handle commands that map directly to Zig UI actions
        if (std.mem.eql(u8, cmd.name, "help")) {
            self.modal = .help;
            self.dirty.markAll();
            self.render_requested = true;
            self.clearCompose();
            return;
        }
        if (std.mem.eql(u8, cmd.name, "quit")) {
            self.clearCompose();
            _ = self.events.pushTagged(.quit, "");
            return;
        }
        if (std.mem.eql(u8, cmd.name, "nick")) {
            self.modal = .settings_name;
            self.dirty.markAll();
            self.render_requested = true;
            self.clearCompose();
            return;
        }
        if (std.mem.eql(u8, cmd.name, "settings")) {
            self.modal = .settings_menu;
            self.dirty.markAll();
            self.render_requested = true;
            self.clearCompose();
            return;
        }
        if (std.mem.eql(u8, cmd.name, "theme")) {
            self.modal = .settings_theme;
            self.dirty.markAll();
            self.render_requested = true;
            self.clearCompose();
            return;
        }
        if (std.mem.eql(u8, cmd.name, "dm")) {
            self.modal = .users;
            self.dirty.markAll();
            self.render_requested = true;
            self.clearCompose();
            return;
        }
        if (std.mem.eql(u8, cmd.name, "react")) {
            self.modal = .reaction;
            self.dirty.markAll();
            self.render_requested = true;
            self.clearCompose();
            return;
        }
        if (std.mem.eql(u8, cmd.name, "leavedm")) {
            self.clearCompose();
            _ = self.events.pushTagged(.leave_dm, "");
            return;
        }

        // Commands with args: replace compose text with "/command " and let user type args
        if (cmd.has_args) {
            if (self.compose_edit_buffer) |eb| {
                eb.clear() catch {};
                // Build "/command " and insert as text
                var cmd_buf: [64]u8 = undefined;
                var pos: usize = 0;
                cmd_buf[pos] = '/';
                pos += 1;
                const nlen = @min(cmd.name.len, cmd_buf.len - pos - 1);
                @memcpy(cmd_buf[pos .. pos + nlen], cmd.name[0..nlen]);
                pos += nlen;
                cmd_buf[pos] = ' ';
                pos += 1;
                eb.insertText(cmd_buf[0..pos]) catch {};
                self.dirty.compose = true;
                self.render_requested = true;
            }
            return;
        }
    }

    /// Emit the current keybindings as a JSON string via update_profile event.
    /// Format: {"quit":{"key":"escape"},"quitImmediate":{"key":"q","ctrl":true},...}
    fn emitKeybindingsUpdate(self: *ChatClient) void {
        // Map BindableCommand enum indices to JSON key names
        const CMD_NAMES = [types.BINDABLE_COMMAND_COUNT][]const u8{
            "quit",
            "quitImmediate",
            "toggleHelp",
            "openSettings",
            "toggleTimestamps",
            "toggleAvatars",
            "toggleUsers",
            "newDm",
            "leaveDm",
            "addDmMember",
            "prevChannel",
            "nextChannel",
            "react",
        };
        // Build JSON string into a buffer
        var json_buf: [2048]u8 = undefined;
        var pos: usize = 0;
        json_buf[pos] = '{';
        pos += 1;

        for (0..types.BINDABLE_COMMAND_COUNT) |i| {
            if (i > 0) {
                json_buf[pos] = ',';
                pos += 1;
            }
            // "cmdName":{"key":"keyname"[,"ctrl":true][,"shift":true]}
            json_buf[pos] = '"';
            pos += 1;
            @memcpy(json_buf[pos .. pos + CMD_NAMES[i].len], CMD_NAMES[i]);
            pos += CMD_NAMES[i].len;
            json_buf[pos] = '"';
            pos += 1;
            json_buf[pos] = ':';
            pos += 1;

            const combo = self.keybindings[i];
            pos += self.formatComboJson(combo, json_buf[pos..]);
        }

        json_buf[pos] = '}';
        pos += 1;

        _ = self.events.pushUpdateProfile("keybindings", json_buf[0..pos]);
    }

    /// Format a single KeyCombo as a JSON object fragment: {"key":"name"[,"ctrl":true][,"shift":true]}
    fn formatComboJson(_: *const ChatClient, combo: types.KeyCombo, out: []u8) usize {
        var pos: usize = 0;

        // Opening brace
        out[pos] = '{';
        pos += 1;

        // "key":"name"
        const key_prefix = "\"key\":\"";
        @memcpy(out[pos .. pos + key_prefix.len], key_prefix);
        pos += key_prefix.len;

        if (combo.tag == 0) {
            // Character key — write as lowercase letter name
            const c: u8 = @intCast(combo.code & 0x7F);
            const lower = if (c >= 'A' and c <= 'Z') c + 32 else c;
            out[pos] = lower;
            pos += 1;
        } else {
            // Special key — write the key name
            const name = comboSpecialKeyJsonName(combo.code);
            @memcpy(out[pos .. pos + name.len], name);
            pos += name.len;
        }

        out[pos] = '"';
        pos += 1;

        if (combo.ctrl) {
            const frag = ",\"ctrl\":true";
            @memcpy(out[pos .. pos + frag.len], frag);
            pos += frag.len;
        }

        if (combo.shift) {
            const frag = ",\"shift\":true";
            @memcpy(out[pos .. pos + frag.len], frag);
            pos += frag.len;
        }

        out[pos] = '}';
        pos += 1;

        return pos;
    }

    /// Set a single keybinding (called from TS when loading saved bindings).
    /// Set layout from a JSON string (called from TS via FFI).
    /// JSON format: {"gridCols":N,"gridRows":N,"panels":[{"type":"kind","col":N,"row":N,"colSpan":N,"rowSpan":N},...]}
    pub fn setLayout(self: *ChatClient, json: []const u8) void {
        // Parse gridCols
        const gc_key = "\"gridCols\":";
        const gc_idx = indexOf(json, gc_key) orelse return;
        const gc_start = gc_idx + gc_key.len;
        const gc_val = parseJsonU16(json[gc_start..]) orelse return;

        // Parse gridRows
        const gr_key = "\"gridRows\":";
        const gr_idx = indexOf(json, gr_key) orelse return;
        const gr_start = gr_idx + gr_key.len;
        const gr_val = parseJsonU16(json[gr_start..]) orelse return;

        // Validate grid bounds
        if (gc_val < layout_mod.MIN_GRID or gc_val > layout_mod.MAX_GRID) return;
        if (gr_val < layout_mod.MIN_GRID or gr_val > layout_mod.MAX_GRID) return;

        // Parse panels array
        const arr_start_idx = indexOf(json, "[") orelse return;
        const arr_end_idx = lastIndexOf(json, "]") orelse return;
        if (arr_end_idx <= arr_start_idx) return;
        const arr_content = json[arr_start_idx + 1 .. arr_end_idx];

        var new_panels: [types.MAX_PANELS]Panel = undefined;
        var count: u8 = 0;

        // Split on },{  — each panel object
        var rest = arr_content;
        while (rest.len > 0 and count < types.MAX_PANELS) {
            // Find start of object
            const obj_start = indexOf(rest, "{") orelse break;
            const obj_end = indexOf(rest[obj_start..], "}") orelse break;
            const obj = rest[obj_start .. obj_start + obj_end + 1];

            if (parsePanelJson(obj)) |panel| {
                new_panels[count] = panel;
                count += 1;
            }

            rest = rest[obj_start + obj_end + 1 ..];
        }

        if (count == 0) return;

        // Apply
        self.grid_cols = gc_val;
        self.grid_rows = gr_val;
        self.panel_count = count;
        for (0..count) |i| {
            self.panels[i] = new_panels[i];
        }

        // Recompute pixel layout
        layout_mod.computeLayout(self.panels[0..self.panel_count], self.width, self.height, self.grid_cols, self.grid_rows);
        self.dirty.markAll();
        self.render_requested = true;
    }

    pub fn setKeybinding(self: *ChatClient, cmd_idx: u8, tag: u8, code: u32, modifiers: u8) void {
        if (cmd_idx >= types.BINDABLE_COMMAND_COUNT) return;
        self.keybindings[cmd_idx] = .{
            .tag = tag,
            .code = code,
            .ctrl = (modifiers & 1) != 0,
            .shift = (modifiers & 2) != 0,
        };
    }

    /// Check if a key event matches a bindable command's current keybinding.
    fn matchesBinding(self: *const ChatClient, key: KeyEvent, cmd: types.BindableCommand) bool {
        const combo = self.keybindings[@intFromEnum(cmd)];
        if (combo.tag == 0) {
            // Character binding
            if (!key.isChar()) return false;
            const ch = key.charValue() orelse return false;
            if (@as(u32, ch) != combo.code) return false;
            if (combo.ctrl != key.hasCtrl()) return false;
            if (combo.shift != key.hasShift()) return false;
            return true;
        } else {
            // Special key binding
            if (!key.isSpecial()) return false;
            const sp = key.specialKey() orelse return false;
            if (@as(u32, @intFromEnum(sp)) != combo.code) return false;
            if (combo.ctrl != key.hasCtrl()) return false;
            if (combo.shift != key.hasShift()) return false;
            return true;
        }
    }

    fn clearCompose(self: *ChatClient) void {
        if (self.compose_edit_buffer) |eb| {
            eb.clear() catch {};
            self.dirty.compose = true;
            self.render_requested = true;
        }
    }
};

/// Write a u16 value as decimal ASCII into buf, returning the number of bytes written.
fn writeU16(buf: []u8, value: u16) usize {
    if (value == 0) {
        buf[0] = '0';
        return 1;
    }
    var v = value;
    var digits: [5]u8 = undefined; // u16 max is 65535 (5 digits)
    var len: usize = 0;
    while (v > 0) {
        digits[len] = @intCast(v % 10 + '0');
        v /= 10;
        len += 1;
    }
    // Reverse into output buffer
    for (0..len) |i| {
        buf[i] = digits[len - 1 - i];
    }
    return len;
}

/// Map SpecialKey code to its JSON key name (matches keybindings.ts key names).
fn comboSpecialKeyJsonName(code: u32) []const u8 {
    return switch (code) {
        1 => "return",
        2 => "tab",
        3 => "escape",
        4 => "backspace",
        5 => "delete",
        6 => "up",
        7 => "down",
        8 => "left",
        9 => "right",
        10 => "home",
        11 => "end",
        12 => "pageup",
        13 => "pagedown",
        14 => "f1",
        15 => "f2",
        16 => "f3",
        17 => "f4",
        18 => "f5",
        19 => "f6",
        20 => "f7",
        21 => "f8",
        22 => "f9",
        23 => "f10",
        24 => "f11",
        25 => "f12",
        26 => "insert",
        27 => "space",
        else => "unknown",
    };
}

/// Find first occurrence of needle in haystack, return index or null.
fn indexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    if (needle.len == 0) return 0;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

/// Find last occurrence of needle in haystack, return index or null.
fn lastIndexOf(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len > haystack.len) return null;
    var result: ?usize = null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.mem.eql(u8, haystack[i .. i + needle.len], needle)) result = i;
    }
    return result;
}

/// Parse a u16 from decimal digits at the start of the slice.
fn parseJsonU16(s: []const u8) ?u16 {
    var val: u16 = 0;
    var count: usize = 0;
    for (s) |c| {
        if (c >= '0' and c <= '9') {
            val = val *% 10 +% @as(u16, c - '0');
            count += 1;
        } else break;
    }
    if (count == 0) return null;
    return val;
}

/// Parse a panel object JSON like {"type":"header","col":0,"row":0,"colSpan":10,"rowSpan":1}
fn parsePanelJson(obj: []const u8) ?types.Panel {
    // Parse type
    const type_key = "\"type\":\"";
    const type_idx = indexOf(obj, type_key) orelse return null;
    const type_start = type_idx + type_key.len;
    const type_end_idx = indexOf(obj[type_start..], "\"") orelse return null;
    const type_str = obj[type_start .. type_start + type_end_idx];

    const kind: types.PanelKind = if (std.mem.eql(u8, type_str, "header"))
        .header
    else if (std.mem.eql(u8, type_str, "messages"))
        .messages
    else if (std.mem.eql(u8, type_str, "compose"))
        .compose
    else if (std.mem.eql(u8, type_str, "channels"))
        .channels
    else if (std.mem.eql(u8, type_str, "members"))
        .members
    else
        return null;

    // Parse col
    const col_key = "\"col\":";
    const col_idx = indexOf(obj, col_key) orelse return null;
    const col_val = parseJsonU16(obj[col_idx + col_key.len ..]) orelse return null;

    // Parse row
    const row_key = "\"row\":";
    const row_idx = indexOf(obj, row_key) orelse return null;
    const row_val = parseJsonU16(obj[row_idx + row_key.len ..]) orelse return null;

    // Parse colSpan
    const cs_key = "\"colSpan\":";
    const cs_idx = indexOf(obj, cs_key) orelse return null;
    const cs_val = parseJsonU16(obj[cs_idx + cs_key.len ..]) orelse return null;

    // Parse rowSpan
    const rs_key = "\"rowSpan\":";
    const rs_idx = indexOf(obj, rs_key) orelse return null;
    const rs_val = parseJsonU16(obj[rs_idx + rs_key.len ..]) orelse return null;

    return .{
        .kind = kind,
        .col = col_val,
        .row = row_val,
        .col_span = cs_val,
        .row_span = rs_val,
        .group = 0,
    };
}
