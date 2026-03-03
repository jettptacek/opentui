// chat/panel-render.zig — Panel rendering functions
// Each panel is drawn directly into the OptimizedBuffer at its computed position
const std = @import("std");
const buffer_mod = @import("../buffer.zig");
const OptimizedBuffer = buffer_mod.OptimizedBuffer;
const RGBA = buffer_mod.RGBA;
const types = @import("types.zig");
const Panel = types.Panel;
const ChatClient = @import("chat-client.zig").ChatClient;
const theme_mod = @import("theme.zig");

// Border characters for "rounded" style (default)
const ROUNDED_BORDER = [8]u32{
    0x256D, // top-left
    0x256E, // top-right
    0x2570, // bottom-left
    0x256F, // bottom-right
    0x2500, // horizontal
    0x2502, // vertical
    0x2500, // horizontal (same)
    0x2502, // vertical (same)
};

// Hardcoded RGBA colors for role badges
const ADMIN_BADGE_COLOR: RGBA = .{ 1.0, 107.0 / 255.0, 107.0 / 255.0, 1.0 }; // #ff6b6b
const MOD_BADGE_COLOR: RGBA = .{ 229.0 / 255.0, 192.0 / 255.0, 123.0 / 255.0, 1.0 }; // #e5c07b

// Registration color choices (matches the 8 colors from the SolidJS RegisterScreen)
pub const REGISTER_COLORS = [8]RGBA{
    .{ 97.0 / 255.0, 175.0 / 255.0, 239.0 / 255.0, 1.0 }, // #61afef blue
    .{ 152.0 / 255.0, 195.0 / 255.0, 121.0 / 255.0, 1.0 }, // #98c379 green
    .{ 198.0 / 255.0, 120.0 / 255.0, 221.0 / 255.0, 1.0 }, // #c678dd purple
    .{ 224.0 / 255.0, 108.0 / 255.0, 117.0 / 255.0, 1.0 }, // #e06c75 red
    .{ 229.0 / 255.0, 192.0 / 255.0, 123.0 / 255.0, 1.0 }, // #e5c07b yellow
    .{ 86.0 / 255.0, 182.0 / 255.0, 194.0 / 255.0, 1.0 }, // #56b6c2 cyan
    .{ 209.0 / 255.0, 154.0 / 255.0, 102.0 / 255.0, 1.0 }, // #d19a66 orange
    .{ 255.0 / 255.0, 255.0 / 255.0, 255.0 / 255.0, 1.0 }, // #ffffff white
};

/// Draw a simple bordered box with a title
fn drawBorderBox(
    buf: *OptimizedBuffer,
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    border_color: RGBA,
    bg_color: RGBA,
    title: ?[]const u8,
    title_color: RGBA,
) void {
    if (w < 2 or h < 2) return;

    const ux: u32 = @intCast(x);
    const uy: u32 = @intCast(y);
    const uw: u32 = @intCast(w);
    const uh: u32 = @intCast(h);

    // Fill background
    buf.fillRect(ux, uy, uw, uh, bg_color) catch {};

    // Draw corners
    buf.drawChar(ROUNDED_BORDER[0], ux, uy, border_color, bg_color, 0) catch {};
    buf.drawChar(ROUNDED_BORDER[1], ux + uw - 1, uy, border_color, bg_color, 0) catch {};
    buf.drawChar(ROUNDED_BORDER[2], ux, uy + uh - 1, border_color, bg_color, 0) catch {};
    buf.drawChar(ROUNDED_BORDER[3], ux + uw - 1, uy + uh - 1, border_color, bg_color, 0) catch {};

    // Draw horizontal edges
    var i: u32 = 1;
    while (i < uw - 1) : (i += 1) {
        buf.drawChar(ROUNDED_BORDER[4], ux + i, uy, border_color, bg_color, 0) catch {};
        buf.drawChar(ROUNDED_BORDER[6], ux + i, uy + uh - 1, border_color, bg_color, 0) catch {};
    }

    // Draw vertical edges
    i = 1;
    while (i < uh - 1) : (i += 1) {
        buf.drawChar(ROUNDED_BORDER[5], ux, uy + i, border_color, bg_color, 0) catch {};
        buf.drawChar(ROUNDED_BORDER[7], ux + uw - 1, uy + i, border_color, bg_color, 0) catch {};
    }

    // Draw title if provided
    if (title) |t| {
        if (t.len > 0 and w > 4) {
            const max_title = @min(t.len, @as(usize, w - 4));
            buf.drawText(t[0..max_title], ux + 2, uy, title_color, bg_color, 0) catch {};
        }
    }
}

/// Render a panel based on its kind
pub fn renderPanel(client: *const ChatClient, panel: *const Panel, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const focused = client.isFocused(panel);
    const border_color = if (focused) t.border_active else t.border;

    // Draw the bordered box
    drawBorderBox(
        buf,
        panel.x,
        panel.y,
        panel.width,
        panel.height,
        border_color,
        t.background,
        null,
        t.text,
    );

    // Render panel-specific content
    switch (panel.kind) {
        .header => renderHeader(client, panel, buf),
        .messages => renderMessages(client, panel, buf),
        .compose => renderCompose(client, panel, buf, focused),
        .channels => renderChannels(client, panel, buf),
        .members => renderMembers(client, panel, buf),
    }
}

fn renderHeader(client: *const ChatClient, panel: *const Panel, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const ix = panel.innerX();
    const iy = panel.innerY();
    const iw = panel.innerWidth();

    if (iw == 0 or panel.innerHeight() == 0) return;

    // "Shush" app name in primary color, bold
    buf.drawText("Shush", @intCast(ix), @intCast(iy), t.primary, t.background, 1) catch {};

    // " · " separator
    buf.drawText(" \xc2\xb7 ", @intCast(ix + 6), @intCast(iy), t.text_muted, t.background, 0) catch {};

    // Username in user color
    if (client.me) |me| {
        const name = me.nameSlice();
        buf.drawText(name, @intCast(ix + 9), @intCast(iy), me.color, t.background, 1) catch {};
    }
}

fn renderMessages(client: *const ChatClient, panel: *const Panel, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const ix = panel.innerX();
    const iy = panel.innerY();
    const iw = panel.innerWidth();
    const ih = panel.innerHeight();

    if (iw == 0 or ih == 0) return;

    // Set scissor rect for content clipping
    buf.pushScissorRect(@intCast(ix), @intCast(iy), @intCast(iw), @intCast(ih)) catch {};
    defer buf.popScissorRect();

    const msgs = client.messages.items;
    if (msgs.len == 0) {
        // Empty state
        const empty = "No messages yet. Start chatting!";
        const cx = ix + (iw -| @as(u16, @intCast(@min(empty.len, iw)))) / 2;
        const cy = iy + ih / 2;
        buf.drawText(empty, @intCast(cx), @intCast(cy), t.text_dim, t.background, 0) catch {};
        return;
    }

    const available_width: usize = @intCast(iw);
    const visible_rows: usize = @intCast(ih);
    const scroll_offset: usize = @intCast(@max(0, client.msg_scroll_offset));

    // Render messages bottom-up with word wrapping.
    // msg_scroll_offset is the number of rows hidden below the viewport.
    // We iterate messages from newest (end) to oldest, tracking how many rows
    // each message contributes. We skip rows for the scroll offset, then draw
    // rows that fall within the visible window.

    var rows_placed: usize = 0; // rows counted from the bottom (including scrolled-off)
    var screen_row: usize = visible_rows; // next screen row to fill (top = 0, bottom = visible_rows-1)
    var msg_idx: usize = msgs.len;

    while (msg_idx > 0 and screen_row > 0) {
        msg_idx -= 1;
        const msg = &msgs[msg_idx];
        const msg_rows = types.msgRowCount(msg, available_width);

        const name = msg.fromNameSlice();
        const content = msg.contentSlice();
        const prefix_len: usize = @as(usize, name.len) + 3; // " name: "
        const content_first = if (prefix_len < available_width) available_width - prefix_len else 0;
        const wrap_width = if (available_width > 2) available_width - 2 else available_width;

        // is_selected check
        const is_selected = client.selected_msg_idx >= 0 and @as(usize, @intCast(client.selected_msg_idx)) == msg_idx;
        const content_fg = if (is_selected) t.accent else t.text;
        const name_attr: u32 = if (is_selected) 1 | 4 else 1; // bold + underline if selected
        const bg = if (is_selected) t.background_panel else t.background;

        // Iterate the rows of this message from bottom (last wrap line) to top (first line with name)
        var line: usize = msg_rows;
        while (line > 0 and screen_row > 0) {
            line -= 1;
            if (rows_placed < scroll_offset) {
                // This row is scrolled off below the viewport
                rows_placed += 1;
                continue;
            }
            screen_row -= 1;
            rows_placed += 1;

            const y_pos: u32 = @intCast(iy + @as(u16, @intCast(screen_row)));

            // Draw selection highlight background across the full row
            if (is_selected) {
                var col: usize = 0;
                while (col < available_width) : (col += 1) {
                    buf.drawText(" ", @intCast(ix + @as(u16, @intCast(col))), y_pos, bg, bg, 0) catch {};
                }
            }

            if (line == 0) {
                // First line: "name: content_start"
                buf.drawText(name, @intCast(ix + 1), y_pos, msg.from_color, bg, name_attr) catch {};
                const name_end: u32 = @intCast(ix + 1 + @as(u16, @intCast(name.len)));
                buf.drawText(": ", name_end, y_pos, t.text, bg, 0) catch {};

                if (content_first > 0 and content.len > 0) {
                    const first_len = @min(content.len, content_first);
                    buf.drawText(content[0..first_len], name_end + 2, y_pos, content_fg, bg, 0) catch {};
                }

                // Timestamp on first line only
                if (client.show_timestamps and msg.timestamp > 0 and !is_selected) {
                    var time_buf: [5]u8 = undefined;
                    const secs = @divFloor(msg.timestamp, 1000);
                    const hours: u32 = @intCast(@mod(@divFloor(secs, 3600), 24));
                    const mins: u32 = @intCast(@mod(@divFloor(secs, 60), 60));
                    _ = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ hours, mins }) catch {};
                    const ts_x: u32 = @intCast(ix + iw - 6);
                    buf.drawText(time_buf[0..5], ts_x, y_pos, t.timestamp, bg, 0) catch {};
                }
            } else {
                // Continuation line: indented content
                const offset = content_first + (line - 1) * wrap_width;
                if (offset < content.len) {
                    const remaining = content.len - offset;
                    const line_len = @min(remaining, wrap_width);
                    buf.drawText(content[offset .. offset + line_len], @intCast(ix + 2), y_pos, content_fg, bg, 0) catch {};
                }
            }
        }
    }

    // Scroll indicator: show "v N more v" at bottom when scrolled up from newest
    if (scroll_offset > 0) {
        var indicator_buf: [32]u8 = undefined;
        const indicator = std.fmt.bufPrint(&indicator_buf, " \xE2\x96\xBC {d} more \xE2\x96\xBC ", .{scroll_offset}) catch " \xE2\x96\xBC more \xE2\x96\xBC ";
        const ind_len: u16 = @intCast(@min(indicator.len, available_width));
        const ind_x = ix + (iw -| ind_len) / 2;
        const ind_y: u32 = @intCast(iy + ih - 1);
        buf.drawText(indicator[0..ind_len], @intCast(ind_x), ind_y, t.warning, t.background, 1) catch {};
    }
}

fn renderCompose(client: *const ChatClient, panel: *const Panel, buf: *OptimizedBuffer, focused: bool) void {
    const t = client.theme;
    const border_color = if (focused) t.success else t.border;

    // Re-draw border with compose-specific color
    drawBorderBox(
        buf,
        panel.x,
        panel.y,
        panel.width,
        panel.height,
        border_color,
        t.background,
        null,
        t.text,
    );

    const ix = panel.innerX();
    const iy = panel.innerY();
    const iw = panel.innerWidth();
    const ih = panel.innerHeight();

    if (iw == 0 or ih == 0) return;

    // Channel label
    const chan = client.currentChannelSlice();
    buf.drawText("#", @intCast(ix), @intCast(iy), t.channel_label, t.background, 0) catch {};
    buf.drawText(chan, @intCast(ix + 1), @intCast(iy), t.channel_label, t.background, 0) catch {};

    const prompt_x: i32 = @intCast(ix + 1 + @as(u16, @intCast(chan.len)) + 1);

    // Draw the compose EditorView (or placeholder if empty and not focused)
    if (client.compose_editor_view) |ev| {
        // Update viewport width based on available space
        const editor_width = @as(u32, @intCast(iw)) -| (@as(u32, @intCast(chan.len)) + 3);
        if (editor_width > 0) {
            ev.setViewportSize(editor_width, @intCast(ih));
        }
        buf.drawEditorView(ev, prompt_x, @intCast(iy)) catch {};

        if (focused) {
            // Show terminal cursor at the editor's visual cursor position
            // setCursorPosition expects 1-based coordinates (ANSI convention)
            const vc = ev.getVisualCursor();
            client.renderer.terminal.setCursorPosition(
                @as(u32, @intCast(prompt_x)) + vc.visual_col + 1,
                @as(u32, @intCast(iy)) + vc.visual_row + 1,
                true,
            );
        }
    } else {
        // Fallback: placeholder text
        if (focused) {
            buf.drawText("Type a message...", @intCast(prompt_x), @intCast(iy), t.text_muted, t.background, 0) catch {};
        } else {
            buf.drawText("Type a message...", @intCast(prompt_x), @intCast(iy), t.text_dim, t.background, 0) catch {};
        }
    }
}

fn renderChannels(client: *const ChatClient, panel: *const Panel, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const ix = panel.innerX();
    const iy = panel.innerY();
    const iw = panel.innerWidth();
    const ih = panel.innerHeight();

    if (iw == 0 or ih == 0) return;

    // Draw title
    const title = "Channels";
    const title_x = ix + (iw -| @as(u16, @intCast(@min(title.len, iw)))) / 2;
    buf.drawText(title, @intCast(title_x), @intCast(panel.y), t.text, t.background, 1) catch {};

    buf.pushScissorRect(@intCast(ix), @intCast(iy), @intCast(iw), @intCast(ih)) catch {};
    defer buf.popScissorRect();

    const channels = client.channels.items;
    var row: u16 = 0;
    for (channels, 0..) |*chan, i| {
        if (row >= ih) break;

        const name = chan.nameSlice();
        const is_active = std.mem.eql(u8, name, client.currentChannelSlice());
        const is_selected = @as(i32, @intCast(i)) == client.channel_sel_idx;

        var fg = t.text_muted;
        var bg = t.background;
        if (is_active) fg = t.channel_label;
        if (is_selected and client.isFocused(panel)) {
            bg = t.primary;
            fg = t.background;
        }

        // Draw "#channelname"
        buf.drawText("#", @intCast(ix), @intCast(iy + row), fg, bg, 0) catch {};
        const max_name = @min(name.len, @as(usize, iw -| 1));
        if (max_name > 0) {
            buf.drawText(name[0..max_name], @intCast(ix + 1), @intCast(iy + row), fg, bg, 0) catch {};
        }

        // Fill remaining width for selection highlight
        if (is_selected and client.isFocused(panel)) {
            const filled = 1 + @as(u16, @intCast(max_name));
            if (filled < iw) {
                buf.fillRect(@intCast(ix + filled), @intCast(iy + row), @intCast(iw - filled), 1, bg) catch {};
            }
        }

        row += 1;
    }
}

fn renderMembers(client: *const ChatClient, panel: *const Panel, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const ix = panel.innerX();
    const iy = panel.innerY();
    const iw = panel.innerWidth();
    const ih = panel.innerHeight();

    if (iw == 0 or ih == 0) return;

    // Draw title
    const title_str = "Members";
    const title_x = ix + (iw -| @as(u16, @intCast(@min(title_str.len, iw)))) / 2;
    buf.drawText(title_str, @intCast(title_x), @intCast(panel.y), t.text, t.background, 1) catch {};

    buf.pushScissorRect(@intCast(ix), @intCast(iy), @intCast(iw), @intCast(ih)) catch {};
    defer buf.popScissorRect();

    const users = client.users.items;
    var row: u16 = 0;

    // Show current user first
    if (client.me) |me| {
        const name = me.nameSlice();
        const max_name = @min(name.len, @as(usize, iw));
        buf.drawText(name[0..max_name], @intCast(ix), @intCast(iy), me.color, t.background, 0) catch {};

        const you_suffix = " (you)";
        const suffix_x: u32 = @intCast(ix + @as(u16, @intCast(max_name)));
        buf.drawText(you_suffix, suffix_x, @intCast(iy), t.text_muted, t.background, 0) catch {};
        row += 1;
    }

    // Show other users
    for (users, 0..) |*user, i| {
        if (row >= ih) break;

        // Skip self
        if (client.me) |me| {
            if (std.mem.eql(u8, user.nameSlice(), me.nameSlice())) continue;
        }

        const name = user.nameSlice();
        const is_selected = @as(i32, @intCast(i)) == client.member_sel_idx;

        var fg = user.color;
        var bg = t.background;
        if (is_selected and client.isFocused(panel)) {
            bg = t.primary;
            fg = t.background;
        }

        const max_name = @min(name.len, @as(usize, iw));
        buf.drawText(name[0..max_name], @intCast(ix), @intCast(iy + row), fg, bg, 0) catch {};

        // Role badge
        if (user.role == .admin) {
            const badge = " [A]";
            const bx: u32 = @intCast(ix + @as(u16, @intCast(max_name)));
            buf.drawText(badge, bx, @intCast(iy + row), ADMIN_BADGE_COLOR, bg, 0) catch {};
        } else if (user.role == .moderator) {
            const badge = " [M]";
            const bx: u32 = @intCast(ix + @as(u16, @intCast(max_name)));
            buf.drawText(badge, bx, @intCast(iy + row), MOD_BADGE_COLOR, bg, 0) catch {};
        }

        row += 1;
    }

    if (row == 0 or (row == 1 and client.me != null)) {
        const empty = "No other members";
        buf.drawText(empty, @intCast(ix), @intCast(iy + row), t.text_dim, t.background, 0) catch {};
    }
}

pub fn renderLoadingScreen(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const cx = client.width / 2;
    const cy = client.height / 2;

    const text = "Connecting...";
    const tx = cx -| @as(u16, @intCast(text.len / 2));
    buf.drawText(text, @intCast(tx), @intCast(cy), t.text_muted, t.background, 0) catch {};
}

pub fn renderRegisterScreen(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w = client.width;
    const h = client.height;

    // Centered box for registration
    const box_w: u16 = @min(50, w -| 4);
    const box_h: u16 = @min(16, h -| 4);
    const box_x = (w - box_w) / 2;
    const box_y = (h - box_h) / 2;

    drawBorderBox(
        buf,
        box_x,
        box_y,
        box_w,
        box_h,
        t.primary,
        t.background,
        "Register",
        t.primary,
    );

    const ix: u32 = @intCast(box_x + 2);
    const iy: u32 = @intCast(box_y + 2);
    const reg_focus = client.register_focus;

    // Welcome text
    buf.drawText("Welcome to Shush!", ix, iy, t.text_muted, t.background, 0) catch {};

    // Username label + input
    const name_label_color = if (reg_focus == .name) t.primary else t.text_muted;
    buf.drawText("Username:", ix, iy + 2, name_label_color, t.background, 1) catch {};

    if (client.register_editor_view) |ev| {
        ev.setViewportSize(25, 1);
        buf.drawEditorView(ev, @intCast(ix + 10), @intCast(iy + 2)) catch {};

        if (reg_focus == .name) {
            // setCursorPosition expects 1-based coordinates (ANSI convention)
            const vc = ev.getVisualCursor();
            client.renderer.terminal.setCursorPosition(
                ix + 10 + vc.visual_col + 1,
                iy + 2 + vc.visual_row + 1,
                true,
            );
        }
    }

    // Color picker
    const color_label_color = if (reg_focus == .color) t.primary else t.text_muted;
    buf.drawText("Color:", ix, iy + 4, color_label_color, t.background, 1) catch {};

    // Draw 8 color swatches
    for (REGISTER_COLORS, 0..) |color, ci| {
        const cx: u32 = ix + 10 + @as(u32, @intCast(ci)) * 3;
        const is_selected = ci == client.register_color_idx;
        if (is_selected and reg_focus == .color) {
            // Draw brackets around selected color
            buf.drawText("[", cx -| 1, iy + 4, t.primary, t.background, 0) catch {};
            buf.drawText("]", cx + 2, iy + 4, t.primary, t.background, 0) catch {};
        }
        // Draw colored block
        buf.fillRect(cx, iy + 4, 2, 1, color) catch {};
    }

    // Theme picker
    const theme_label_color = if (reg_focus == .theme) t.primary else t.text_muted;
    buf.drawText("Theme:", ix, iy + 6, theme_label_color, t.background, 1) catch {};

    // Show current theme name with arrows
    const theme_entry = &theme_mod.themes[client.register_theme_idx];
    if (reg_focus == .theme) {
        buf.drawText("<", ix + 10, iy + 6, t.primary, t.background, 0) catch {};
        buf.drawText(theme_entry.name, ix + 12, iy + 6, t.text, t.background, 1) catch {};
        const name_end: u32 = ix + 12 + @as(u32, @intCast(theme_entry.name.len));
        buf.drawText(">", name_end + 1, iy + 6, t.primary, t.background, 0) catch {};
    } else {
        buf.drawText(theme_entry.name, ix + 10, iy + 6, t.text_dim, t.background, 0) catch {};
    }

    // Submit button
    const submit_y: u32 = iy + 8;
    if (reg_focus == .submit) {
        buf.drawText("[ Submit ]", ix + 10, submit_y, t.primary, t.background, 1) catch {};
    } else {
        buf.drawText("  Submit  ", ix + 10, submit_y, t.text_muted, t.background, 0) catch {};
    }

    // Footer hints
    buf.drawText("Tab to navigate \xc2\xb7 Enter to submit", ix, @intCast(box_y + box_h - 2), t.text_dim, t.background, 0) catch {};
}

// ===================================================================
// Modal overlays
// ===================================================================

const Modal = types.Modal;

pub fn renderModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    // If show_help is set but modal is .none, render help
    const modal = if (client.modal == .none and client.show_help) Modal.help else client.modal;
    switch (modal) {
        .none => {},
        .help => renderHelpModal(client, buf),
        .users => renderUserPickerModal(client, buf),
        .add_member => renderAddMemberModal(client, buf),
        .reaction => renderReactionModal(client, buf),
        .settings_menu => renderSettingsMenuModal(client, buf),
        .settings_name => renderSettingsNameModal(client, buf),
        .settings_color => renderSettingsColorModal(client, buf),
        .settings_theme => renderSettingsThemeModal(client, buf),
        .settings_keybindings => renderSettingsKeybindingsModal(client, buf),
        .settings_avatar => renderSettingsAvatarModal(client, buf),
    }
}

fn renderHelpModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(50, client.width -| 4);
    const h: u16 = @min(22, client.height -| 4);
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.accent, t.background, "Keyboard Shortcuts", t.accent);

    const ix: u32 = @intCast(x + 2);
    var iy: u32 = @intCast(y + 2);

    const bindings = [_][2][]const u8{
        .{ "Tab / Shift+Tab", "Cycle focus" },
        .{ "Enter", "Send message / select" },
        .{ "Up/Down", "Navigate lists" },
        .{ "Ctrl+Left/Right", "Prev/next channel" },
        .{ "F1", "Toggle this help" },
        .{ "Ctrl+S", "Settings" },
        .{ "Ctrl+T", "Toggle timestamps" },
        .{ "Ctrl+G", "Toggle avatars" },
        .{ "Ctrl+U", "User picker / DM" },
        .{ "Ctrl+N", "New DM" },
        .{ "Ctrl+A", "Add DM member" },
        .{ "Ctrl+R", "React to message" },
        .{ "Ctrl+L", "Leave DM" },
        .{ "Ctrl+Q", "Quit" },
        .{ "Escape", "Close / back" },
    };

    const max_rows: u32 = @intCast(h -| 4);
    for (bindings) |b| {
        if (iy - @as(u32, @intCast(y + 2)) >= max_rows) break;
        buf.drawText(b[0], ix, iy, t.primary, t.background, 1) catch {};
        const desc_x = ix + 20;
        buf.drawText(b[1], desc_x, iy, t.text, t.background, 0) catch {};
        iy += 1;
    }

    // Footer
    buf.drawText("Press F1 or Esc to close", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderUserPickerModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(40, client.width -| 4);
    const h: u16 = @min(20, client.height -| 4);
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.accent, t.background, "Online Users", t.accent);

    const ix: u32 = @intCast(x + 2);
    var iy: u32 = @intCast(y + 2);
    const max_rows: u32 = @intCast(h -| 4);

    // Show current user first
    if (client.me) |me| {
        const name = me.nameSlice();
        buf.drawText(name, ix + 4, iy, me.color, t.background, 0) catch {};
        buf.drawText(" (you)", ix + 4 + @as(u32, @intCast(name.len)), iy, t.text_muted, t.background, 0) catch {};
        iy += 1;
    }

    // Other users with selection
    var other_idx: usize = 0;
    for (client.users.items) |*u| {
        if (iy - @as(u32, @intCast(y + 2)) >= max_rows) break;
        if (client.me) |me| {
            if (std.mem.eql(u8, u.nameSlice(), me.nameSlice())) continue;
        }

        const is_highlighted = @as(i32, @intCast(other_idx)) == client.user_picker_idx;
        const is_selected = other_idx < types.MAX_USERS and client.user_picker_selected[other_idx];

        // Checkbox
        const check = if (is_selected) "[x] " else "[ ] ";
        const fg = if (is_highlighted) t.background else u.color;
        const bg = if (is_highlighted) t.primary else t.background;

        // Fill line background for highlight
        if (is_highlighted) {
            buf.fillRect(ix, iy, @intCast(w -| 4), 1, bg) catch {};
        }

        buf.drawText(check, ix, iy, fg, bg, 0) catch {};
        buf.drawText(u.nameSlice(), ix + 4, iy, fg, bg, 0) catch {};

        // Role badge
        if (u.role == .admin) {
            buf.drawText(" [A]", ix + 4 + @as(u32, @intCast(u.name_len)), iy, ADMIN_BADGE_COLOR, bg, 0) catch {};
        } else if (u.role == .moderator) {
            buf.drawText(" [M]", ix + 4 + @as(u32, @intCast(u.name_len)), iy, MOD_BADGE_COLOR, bg, 0) catch {};
        }

        iy += 1;
        other_idx += 1;
    }

    if (other_idx == 0) {
        buf.drawText("No other users online", ix, iy, t.text_dim, t.background, 0) catch {};
    }

    // Footer
    buf.drawText("Space toggle, Enter DM, Esc close", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderAddMemberModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(36, client.width -| 4);
    const h: u16 = @min(16, client.height -| 4);
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.accent, t.background, "Add Member to DM", t.accent);

    const ix: u32 = @intCast(x + 2);
    var iy: u32 = @intCast(y + 2);
    const max_rows: u32 = @intCast(h -| 4);

    var other_idx: usize = 0;
    for (client.users.items) |*u| {
        if (iy - @as(u32, @intCast(y + 2)) >= max_rows) break;
        if (client.me) |me| {
            if (std.mem.eql(u8, u.nameSlice(), me.nameSlice())) continue;
        }

        const is_highlighted = @as(i32, @intCast(other_idx)) == client.add_member_idx;
        const fg = if (is_highlighted) t.background else u.color;
        const bg = if (is_highlighted) t.primary else t.background;

        if (is_highlighted) {
            buf.fillRect(ix, iy, @intCast(w -| 4), 1, bg) catch {};
        }
        buf.drawText(u.nameSlice(), ix, iy, fg, bg, 0) catch {};

        iy += 1;
        other_idx += 1;
    }

    buf.drawText("Enter add, Esc cancel", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderReactionModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(38, client.width -| 4);
    const h: u16 = 7;
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.warning, t.background, "React to Message", t.warning);

    const ix: u32 = @intCast(x + 2);
    const iy: u32 = @intCast(y + 2);

    // Draw 8 emoji slots in a 4x2 grid
    for (0..8) |i| {
        const col: u32 = @intCast(i % 4);
        const row: u32 = @intCast(i / 4);
        const cx = ix + col * 8;
        const cy = iy + row;
        const is_selected = i == client.reaction_idx;

        const label = types.REACTION_EMOJIS[i];
        const fg = if (is_selected) t.background else t.text;
        const bg2 = if (is_selected) t.warning else t.background;

        if (is_selected) {
            buf.fillRect(cx, cy, @intCast(@min(label.len + 2, 8)), 1, bg2) catch {};
        }
        // Draw emoji name as label (since terminal emoji support varies)
        const display = @min(label.len, 6);
        buf.drawText(label[0..display], cx + 1, cy, fg, bg2, 0) catch {};
    }

    // Footer
    buf.drawText("Arrows, 1-8 quick, Enter, Esc", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderSettingsMenuModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(36, client.width -| 4);
    const h: u16 = @min(12, client.height -| 4);
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.accent, t.background, "Settings", t.accent);

    const ix: u32 = @intCast(x + 2);
    var iy: u32 = @intCast(y + 2);

    for (ChatClient.SETTINGS_MENU_ITEMS, 0..) |item, i| {
        const is_selected = i == client.settings_menu_idx;
        const fg = if (is_selected) t.background else t.text;
        const bg = if (is_selected) t.primary else t.background;

        if (is_selected) {
            buf.fillRect(ix, iy, @intCast(w -| 4), 1, bg) catch {};
            buf.drawText("> ", ix, iy, fg, bg, 1) catch {};
            buf.drawText(item, ix + 2, iy, fg, bg, 1) catch {};
        } else {
            buf.drawText("  ", ix, iy, fg, bg, 0) catch {};
            buf.drawText(item, ix + 2, iy, fg, bg, 0) catch {};
        }

        // Show current value
        const val_x = ix + 18;
        switch (i) {
            0 => {
                // Name
                if (client.me) |me| {
                    buf.drawText(me.nameSlice(), val_x, iy, t.text_muted, bg, 0) catch {};
                }
            },
            1 => {
                // Color — show swatch
                if (client.me) |me| {
                    buf.fillRect(val_x, iy, 2, 1, me.color) catch {};
                }
            },
            2 => {
                // Theme
                buf.drawText(client.theme.name, val_x, iy, t.text_muted, bg, 0) catch {};
            },
            else => {},
        }

        iy += 1;
    }

    buf.drawText("Enter open, Esc close", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderSettingsNameModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(40, client.width -| 4);
    const h: u16 = 7;
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.primary, t.background, "Change Name", t.primary);

    const ix: u32 = @intCast(x + 2);
    const iy: u32 = @intCast(y + 2);

    buf.drawText("Name: ", ix, iy, t.text_muted, t.background, 0) catch {};

    if (client.settings_name_editor_view) |ev| {
        ev.setViewportSize(25, 1);
        const editor_x: i32 = @intCast(ix + 6);
        buf.drawEditorView(ev, editor_x, @intCast(iy)) catch {};

        // Show cursor (1-based)
        const vc = ev.getVisualCursor();
        client.renderer.terminal.setCursorPosition(
            @as(u32, @intCast(editor_x)) + vc.visual_col + 1,
            iy + vc.visual_row + 1,
            true,
        );
    }

    buf.drawText("Enter save, Esc back", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderSettingsColorModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(44, client.width -| 4);
    const h: u16 = 8;
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.primary, t.background, "Change Color", t.primary);

    const ix: u32 = @intCast(x + 2);
    const iy: u32 = @intCast(y + 2);

    // Draw 8 color swatches
    for (REGISTER_COLORS, 0..) |color, ci| {
        const cx: u32 = ix + @as(u32, @intCast(ci)) * 4;
        const is_selected = ci == client.settings_color_idx;
        if (is_selected) {
            buf.drawText("[", cx, iy, t.primary, t.background, 0) catch {};
            buf.drawText("]", cx + 3, iy, t.primary, t.background, 0) catch {};
        }
        buf.fillRect(cx + 1, iy, 2, 1, color) catch {};
    }

    // Preview
    if (client.me) |me| {
        const preview_color = REGISTER_COLORS[client.settings_color_idx];
        buf.drawText(me.nameSlice(), ix, iy + 2, preview_color, t.background, 1) catch {};
    }

    buf.drawText("Left/Right pick, Enter save, Esc back", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderSettingsThemeModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(44, client.width -| 4);
    const max_h: u16 = @min(18, client.height -| 4);
    const theme_count: u16 = @intCast(theme_mod.themes.len);
    const h: u16 = @min(max_h, theme_count + 4);
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.primary, t.background, "Change Theme", t.primary);

    const ix: u32 = @intCast(x + 2);
    var iy: u32 = @intCast(y + 2);
    const max_rows: u32 = @intCast(h -| 4);

    for (&theme_mod.themes, 0..) |theme_entry, i| {
        if (iy - @as(u32, @intCast(y + 2)) >= max_rows) break;
        const is_selected = i == client.settings_theme_idx;
        const is_current = std.mem.eql(u8, theme_entry.id, client.theme.id);
        const fg = if (is_selected) t.background else t.text;
        const bg = if (is_selected) t.primary else t.background;

        if (is_selected) {
            buf.fillRect(ix, iy, @intCast(w -| 4), 1, bg) catch {};
        }

        const prefix: []const u8 = if (is_selected) "> " else "  ";
        buf.drawText(prefix, ix, iy, fg, bg, 0) catch {};
        buf.drawText(theme_entry.name, ix + 2, iy, fg, bg, 1) catch {};

        // Color swatches
        const swatch_x = ix + 20;
        buf.fillRect(swatch_x, iy, 2, 1, theme_entry.accent) catch {};
        buf.fillRect(swatch_x + 2, iy, 2, 1, theme_entry.success) catch {};
        buf.fillRect(swatch_x + 4, iy, 2, 1, theme_entry.warning) catch {};
        buf.fillRect(swatch_x + 6, iy, 2, 1, theme_entry.err) catch {};

        if (is_current) {
            buf.drawText(" *", swatch_x + 8, iy, t.text_muted, bg, 0) catch {};
        }

        iy += 1;
    }

    buf.drawText("Up/Down pick, Enter save, Esc back", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderSettingsKeybindingsModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(50, client.width -| 4);
    const h: u16 = @min(20, client.height -| 4);
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.primary, t.background, "Keybindings", t.primary);

    const ix: u32 = @intCast(x + 2);
    var iy: u32 = @intCast(y + 2);
    const max_rows: u32 = @intCast(h -| 4);

    // Show current keybindings (read-only view)
    const bindings = [_][2][]const u8{
        .{ "Escape", "Close / quit" },
        .{ "Ctrl+Q", "Quit immediately" },
        .{ "F1", "Toggle help" },
        .{ "Ctrl+S", "Settings" },
        .{ "Ctrl+T", "Toggle timestamps" },
        .{ "Ctrl+G", "Toggle avatars" },
        .{ "Ctrl+U", "User picker" },
        .{ "Ctrl+N", "New DM" },
        .{ "Ctrl+L", "Leave DM" },
        .{ "Ctrl+A", "Add DM member" },
        .{ "Ctrl+Left", "Prev channel" },
        .{ "Ctrl+Right", "Next channel" },
        .{ "Ctrl+R", "React" },
    };

    for (bindings, 0..) |b, i| {
        if (iy - @as(u32, @intCast(y + 2)) >= max_rows) break;
        const is_selected = i == client.settings_kb_idx;
        const fg = if (is_selected) t.background else t.text;
        const bg = if (is_selected) t.primary else t.background;

        if (is_selected) {
            buf.fillRect(ix, iy, @intCast(w -| 4), 1, bg) catch {};
        }

        buf.drawText(b[0], ix, iy, if (is_selected) fg else t.primary, bg, 1) catch {};
        buf.drawText(b[1], ix + 18, iy, fg, bg, 0) catch {};
        iy += 1;
    }

    buf.drawText("(Read-only) Esc back", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderSettingsAvatarModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(40, client.width -| 4);
    const h: u16 = 8;
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.primary, t.background, "Avatar Designer", t.primary);

    const ix: u32 = @intCast(x + 2);
    const iy: u32 = @intCast(y + 2);

    // Show 3 glyph slots with cursor
    for (0..3) |col| {
        const cx = ix + @as(u32, @intCast(col)) * 6;
        const is_cursor = col == client.settings_avatar_col;
        const glyph_idx = client.settings_avatar_draft[col];

        if (is_cursor) {
            buf.drawText("[", cx, iy, t.primary, t.background, 0) catch {};
            buf.drawText("]", cx + 4, iy, t.primary, t.background, 0) catch {};
        }

        // Show glyph index as a placeholder
        var idx_buf: [3]u8 = undefined;
        _ = std.fmt.bufPrint(&idx_buf, "{d:0>2}", .{glyph_idx}) catch {};
        buf.drawText(idx_buf[0..2], cx + 1, iy, t.text, t.background, 0) catch {};
    }

    buf.drawText("Left/Right move, Up/Down cycle", ix, iy + 2, t.text_dim, t.background, 0) catch {};
    buf.drawText("Esc back", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}
