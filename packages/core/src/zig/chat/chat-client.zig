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

    // Dirty tracking — only re-render what changed
    dirty: DirtyFlags,
    render_requested: bool,

    // Theme
    theme: *const Theme,

    // Scroll state for messages panel
    msg_scroll_offset: i32, // 0 = bottom (newest), positive = scrolled up

    // Channel list selection
    channel_sel_idx: i32,
    // Member list selection
    member_sel_idx: i32,
    // Selected message index (-1 = none)
    selected_msg_idx: i32,

    // Compose input (EditBuffer + EditorView for text editing)
    compose_edit_buffer: ?*EditBuffer,
    compose_editor_view: ?*EditorView,

    // Register screen input
    register_edit_buffer: ?*EditBuffer,
    register_editor_view: ?*EditorView,
    register_focus: RegisterFocus,
    register_color_idx: u8,
    register_theme_idx: u8,

    // Event queue (outgoing events from Zig → TS)
    events: EventQueue,

    pub const RegisterFocus = enum(u8) {
        name = 0,
        color = 1,
        theme = 2,
        submit = 3,
    };

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

        // Create register EditBuffer + EditorView
        const register_eb = try EditBuffer.init(allocator, pool, .wcwidth);
        errdefer register_eb.deinit();
        const register_ev = try EditorView.init(allocator, register_eb, 30, 1);
        errdefer register_ev.deinit();

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
            .dirty = .{}, // all dirty by default
            .render_requested = true,
            .theme = theme_mod.getDefaultTheme(),
            .msg_scroll_offset = 0,
            .channel_sel_idx = 0,
            .member_sel_idx = 0,
            .selected_msg_idx = -1,
            .compose_edit_buffer = compose_eb,
            .compose_editor_view = compose_ev,
            .register_edit_buffer = register_eb,
            .register_editor_view = register_ev,
            .register_focus = .name,
            .register_color_idx = 0,
            .register_theme_idx = 0,
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
        if (self.register_editor_view) |ev| ev.deinit();
        if (self.register_edit_buffer) |eb| eb.deinit();
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

    pub fn setUser(self: *ChatClient, name: []const u8, color: RGBA, role: types.Role) void {
        var user = User{};
        const len = @min(name.len, types.MAX_NAME_LEN);
        @memcpy(user.name[0..len], name[0..len]);
        user.name_len = @intCast(len);
        user.color = color;
        user.role = role;
        self.me = user;
        self.dirty.header = true;
        self.render_requested = true;
    }

    pub fn addMessage(self: *ChatClient, msg: Message) !void {
        if (self.messages.items.len >= types.MAX_MESSAGES) {
            _ = self.messages.orderedRemove(0);
        }
        try self.messages.append(self.allocator, msg);
        self.dirty.messages = true;
        self.render_requested = true;
    }

    // ---------------------------------------------------------------
    // Input handling — TS parses raw bytes into KeyEvent, passes here
    // ---------------------------------------------------------------

    pub fn processKeyEvent(self: *ChatClient, key: KeyEvent) void {
        switch (self.screen) {
            .loading => {}, // no input on loading screen
            .register => self.handleRegisterInput(key),
            .chat => self.handleChatInput(key),
        }
    }

    fn handleRegisterInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        // Escape → quit
        if (special == .escape) {
            _ = self.events.pushTagged(.quit, "");
            return;
        }

        // Tab / Shift+Tab → cycle focus
        if (special == .tab) {
            if (key.hasShift()) {
                self.register_focus = switch (self.register_focus) {
                    .name => .submit,
                    .color => .name,
                    .theme => .color,
                    .submit => .theme,
                };
            } else {
                self.register_focus = switch (self.register_focus) {
                    .name => .color,
                    .color => .theme,
                    .theme => .submit,
                    .submit => .name,
                };
            }
            self.dirty.markAll();
            self.render_requested = true;
            return;
        }

        switch (self.register_focus) {
            .name => {
                // Text input for name field
                if (self.register_edit_buffer) |eb| {
                    if (special == .enter) {
                        // Move to next field
                        self.register_focus = .color;
                        self.dirty.markAll();
                        self.render_requested = true;
                        return;
                    }
                    self.handleEditorInput(eb, key);
                    self.dirty.markAll();
                    self.render_requested = true;
                }
            },
            .color => {
                if (special == .left) {
                    if (self.register_color_idx > 0) {
                        self.register_color_idx -= 1;
                    } else {
                        self.register_color_idx = 7; // 8 colors, wrap around
                    }
                    self.dirty.markAll();
                    self.render_requested = true;
                } else if (special == .right) {
                    if (self.register_color_idx < 7) {
                        self.register_color_idx += 1;
                    } else {
                        self.register_color_idx = 0;
                    }
                    self.dirty.markAll();
                    self.render_requested = true;
                } else if (special == .enter) {
                    self.submitRegistration();
                }
            },
            .theme => {
                if (special == .left) {
                    if (self.register_theme_idx > 0) {
                        self.register_theme_idx -= 1;
                    } else {
                        self.register_theme_idx = @intCast(theme_mod.themes.len - 1);
                    }
                    self.dirty.markAll();
                    self.render_requested = true;
                } else if (special == .right) {
                    if (self.register_theme_idx < theme_mod.themes.len - 1) {
                        self.register_theme_idx += 1;
                    } else {
                        self.register_theme_idx = 0;
                    }
                    self.dirty.markAll();
                    self.render_requested = true;
                } else if (special == .enter) {
                    self.submitRegistration();
                }
            },
            .submit => {
                if (special == .enter) {
                    self.submitRegistration();
                }
            },
        }
    }

    fn submitRegistration(self: *ChatClient) void {
        if (self.register_edit_buffer) |eb| {
            const name_len = eb.getText(&_get_text_buf);
            if (name_len == 0) return; // validation: name required
            if (name_len > types.MAX_NAME_LEN) return;

            const color = panel_render.REGISTER_COLORS[self.register_color_idx];
            const theme_id = theme_mod.themes[self.register_theme_idx].id;

            _ = self.events.pushRegister(
                _get_text_buf[0..name_len],
                color,
                theme_id,
            );
        }
    }

    fn handleChatInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        // --- Global keys (always processed) ---

        // Ctrl+Q → immediate quit
        if (key.isChar() and key.hasCtrl()) {
            if (key.charValue()) |ch| {
                if (ch == 'q') {
                    _ = self.events.pushTagged(.quit, "");
                    return;
                }
            }
        }

        // Escape → close help or quit
        if (special == .escape) {
            if (self.show_help) {
                self.show_help = false;
                self.dirty.markAll();
                self.render_requested = true;
                return;
            }
            // If a message is selected, deselect it
            if (self.selected_msg_idx >= 0) {
                self.selected_msg_idx = -1;
                self.dirty.messages = true;
                self.render_requested = true;
                return;
            }
            _ = self.events.pushTagged(.quit, "");
            return;
        }

        // F1 → toggle help
        if (special == .f1) {
            self.show_help = !self.show_help;
            self.dirty.markAll();
            self.render_requested = true;
            return;
        }

        // Ctrl+T → toggle timestamps
        if (key.isChar() and key.hasCtrl()) {
            if (key.charValue()) |ch| {
                if (ch == 't') {
                    self.show_timestamps = !self.show_timestamps;
                    self.dirty.messages = true;
                    self.render_requested = true;
                    return;
                }
            }
        }

        // Tab / Shift+Tab → focus cycling
        if (special == .tab) {
            self.cycleFocus(!key.hasShift());
            return;
        }

        // Ctrl+Left / Ctrl+Right → prev/next channel
        if (special == .left and key.hasCtrl()) {
            self.switchToPrevChannel();
            return;
        }
        if (special == .right and key.hasCtrl()) {
            self.switchToNextChannel();
            return;
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

    fn handleComposeInput(self: *ChatClient, key: KeyEvent) void {
        const special = key.specialKey();

        // Enter (without Shift) → send message
        if (special == .enter and !key.hasShift()) {
            self.sendCurrentMessage();
            return;
        }

        // Delegate to EditBuffer for text editing
        if (self.compose_edit_buffer) |eb| {
            self.handleEditorInput(eb, key);
            self.dirty.compose = true;
            self.render_requested = true;
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
            // Scroll up or select previous message
            if (self.selected_msg_idx < 0) {
                self.selected_msg_idx = msg_count - 1;
            } else if (self.selected_msg_idx > 0) {
                self.selected_msg_idx -= 1;
            }
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
            self.dirty.messages = true;
            self.render_requested = true;
        } else if (special == .page_up) {
            self.msg_scroll_offset += 10;
            self.dirty.messages = true;
            self.render_requested = true;
        } else if (special == .page_down) {
            self.msg_scroll_offset = @max(0, self.msg_scroll_offset - 10);
            self.dirty.messages = true;
            self.render_requested = true;
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
                    // Shift+Enter or in contexts that allow newlines
                    if (key.hasShift()) {
                        eb.insertText("\n") catch {};
                    }
                },
                else => {},
            }
        } else if (key.isChar()) {
            // Regular character input
            if (key.charValue()) |codepoint| {
                if (key.hasCtrl()) return; // don't insert ctrl+letter as text
                // Encode codepoint to UTF-8 and insert
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(codepoint, &buf) catch return;
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
            .register => panel_render.renderRegisterScreen(self, buf),
            .chat => {
                for (self.panels[0..self.panel_count]) |*p| {
                    if (!p.visible) continue;
                    panel_render.renderPanel(self, p, buf);
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
};
