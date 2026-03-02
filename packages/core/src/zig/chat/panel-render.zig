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

    // Render messages from bottom up, starting from scroll offset
    const max_rows: usize = @intCast(ih);
    var row: usize = max_rows;
    const start_idx: usize = if (msgs.len > @as(usize, @intCast(@max(0, client.msg_scroll_offset))))
        msgs.len - @as(usize, @intCast(@max(0, client.msg_scroll_offset)))
    else
        0;

    var msg_idx: usize = start_idx;
    while (msg_idx > 0 and row > 0) {
        msg_idx -= 1;
        row -= 1;

        const msg = &msgs[msg_idx];
        const y_pos: u32 = @intCast(iy + @as(u16, @intCast(row)));

        // Format: "{username}: {content}"
        const name = msg.fromNameSlice();
        buf.drawText(name, @intCast(ix + 1), y_pos, msg.from_color, t.background, 1) catch {};

        const sep = ": ";
        const name_end: u32 = @intCast(ix + 1 + @as(u16, @intCast(name.len)));
        buf.drawText(sep, name_end, y_pos, t.text, t.background, 0) catch {};

        const content = msg.contentSlice();
        const content_x: u32 = name_end + 2;
        const max_content = @min(content.len, @as(usize, @intCast(ix + iw)) -| @as(usize, content_x));
        if (max_content > 0) {
            buf.drawText(content[0..max_content], content_x, y_pos, t.text, t.background, 0) catch {};
        }

        // Timestamp
        if (client.show_timestamps and msg.timestamp > 0) {
            // Format HH:MM (simplified — just show raw for now)
            var time_buf: [5]u8 = undefined;
            const secs = @divFloor(msg.timestamp, 1000);
            const hours: u32 = @intCast(@mod(@divFloor(secs, 3600), 24));
            const mins: u32 = @intCast(@mod(@divFloor(secs, 60), 60));
            _ = std.fmt.bufPrint(&time_buf, "{d:0>2}:{d:0>2}", .{ hours, mins }) catch {};
            const ts_x: u32 = @intCast(ix + iw - 6);
            buf.drawText(time_buf[0..5], ts_x, y_pos, t.timestamp, t.background, 0) catch {};
        }
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
            const vc = ev.getVisualCursor();
            client.renderer.terminal.setCursorPosition(
                @as(u32, @intCast(prompt_x)) + vc.visual_col,
                @as(u32, @intCast(iy)) + vc.visual_row,
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
            const vc = ev.getVisualCursor();
            client.renderer.terminal.setCursorPosition(
                ix + 10 + vc.visual_col,
                iy + 2 + vc.visual_row,
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
