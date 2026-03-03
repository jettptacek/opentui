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

// Color choices for user profile (used in settings color picker)
pub const COLOR_CHOICES = [8]RGBA{
    .{ 97.0 / 255.0, 175.0 / 255.0, 239.0 / 255.0, 1.0 }, // #61afef blue
    .{ 152.0 / 255.0, 195.0 / 255.0, 121.0 / 255.0, 1.0 }, // #98c379 green
    .{ 198.0 / 255.0, 120.0 / 255.0, 221.0 / 255.0, 1.0 }, // #c678dd purple
    .{ 224.0 / 255.0, 108.0 / 255.0, 117.0 / 255.0, 1.0 }, // #e06c75 red
    .{ 229.0 / 255.0, 192.0 / 255.0, 123.0 / 255.0, 1.0 }, // #e5c07b yellow
    .{ 86.0 / 255.0, 182.0 / 255.0, 194.0 / 255.0, 1.0 }, // #56b6c2 cyan
    .{ 209.0 / 255.0, 154.0 / 255.0, 102.0 / 255.0, 1.0 }, // #d19a66 orange
    .{ 255.0 / 255.0, 255.0 / 255.0, 255.0 / 255.0, 1.0 }, // #ffffff white
};

/// Check if a byte is a word boundary for @mention detection
fn isMentionBoundary(c: u8) bool {
    return c == ' ' or c == ',' or c == '.' or c == '!' or c == '?' or
        c == ':' or c == ';' or c == '\'' or c == '"' or c == ')' or
        c == ']' or c == '}' or c == '\n' or c == '\r' or c == '\t';
}

/// Find a user by name and return a pointer to their User struct, or null.
fn findUserByName(name: []const u8, client: *const ChatClient) ?*const types.User {
    if (client.me) |*me| {
        if (std.mem.eql(u8, name, me.nameSlice())) return me;
    }
    for (client.users.items) |*u| {
        if (std.mem.eql(u8, name, u.nameSlice())) return u;
    }
    return null;
}

/// Check if a mention word matches any known user name
fn isKnownUser(word: []const u8, client: *const ChatClient) bool {
    // Check current user
    if (client.me) |me| {
        if (std.mem.eql(u8, word, me.nameSlice())) return true;
    }
    // Check other users
    for (client.users.items) |*u| {
        if (std.mem.eql(u8, word, u.nameSlice())) return true;
    }
    return false;
}

/// Draw content text with @mention highlighting.
/// Scans for @word tokens and draws them in accent color if they match a known user.
fn drawTextWithMentions(
    buf: *OptimizedBuffer,
    text: []const u8,
    start_x: u32,
    y: u32,
    default_fg: RGBA,
    mention_fg: RGBA,
    bg: RGBA,
    attr: u32,
    client: *const ChatClient,
) void {
    var x = start_x;
    var i: usize = 0;

    while (i < text.len) {
        if (text[i] == '@' and i + 1 < text.len and !isMentionBoundary(text[i + 1])) {
            // Found potential mention — scan to end of word
            var end = i + 1;
            while (end < text.len and !isMentionBoundary(text[end])) : (end += 1) {}
            const mention_word = text[i + 1 .. end]; // word after @
            if (isKnownUser(mention_word, client)) {
                // Draw "@username" in mention color
                const mention_text = text[i..end];
                buf.drawText(mention_text, x, y, mention_fg, bg, attr | 1) catch {}; // bold mentions
                x += @intCast(mention_text.len);
                i = end;
            } else {
                // Not a known user — draw @ normally
                buf.drawText(text[i .. i + 1], x, y, default_fg, bg, attr) catch {};
                x += 1;
                i += 1;
            }
        } else {
            // Regular character — find the next @ or end of text
            var end = i + 1;
            while (end < text.len and text[end] != '@') : (end += 1) {}
            buf.drawText(text[i..end], x, y, default_fg, bg, attr) catch {};
            x += @intCast(end - i);
            i = end;
        }
    }
}

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

    const acols = client.avatarCols();

    while (msg_idx > 0 and screen_row > 0) {
        msg_idx -= 1;
        const msg = &msgs[msg_idx];
        const msg_rows = types.msgRowCountWithAvatar(msg, available_width, acols);

        const name = msg.fromNameSlice();
        const content = msg.contentSlice();
        const prefix_len: usize = @as(usize, name.len) + 3 + acols; // " [avatar ]name: "
        const content_first = if (prefix_len < available_width) available_width - prefix_len else 0;
        const wrap_width = if (available_width > 2) available_width - 2 else available_width;

        // is_selected check
        const is_selected = client.selected_msg_idx >= 0 and @as(usize, @intCast(client.selected_msg_idx)) == msg_idx;
        const content_fg = if (is_selected) t.accent else t.text;
        const name_attr: u32 = if (is_selected) 1 | 4 else 1; // bold + underline if selected
        const bg = if (is_selected) t.background_panel else t.background;
        const has_reactions = msg.hasReactions();

        // Look up avatar pattern for this sender
        const sender_user: ?*const types.User = if (acols > 0) findUserByName(name, client) else null;

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

            if (has_reactions and line == msg_rows - 1) {
                // Reaction badge row — render emoji badges with counts
                var rx: u32 = @intCast(ix + 2);
                for (0..types.MAX_REACTION_TYPES) |ri| {
                    const count = msg.reaction_counts[ri];
                    if (count > 0) {
                        // Draw "emoji×N " badge
                        const display = types.REACTION_DISPLAY[ri];
                        buf.drawText(display, rx, y_pos, t.warning, bg, 0) catch {};
                        rx += @intCast(display.len);
                        var count_buf: [5]u8 = undefined;
                        const count_str = std.fmt.bufPrint(&count_buf, "\xc3\x97{d} ", .{count}) catch "";
                        buf.drawText(count_str, rx, y_pos, t.text_muted, bg, 0) catch {};
                        rx += @intCast(count_str.len);
                    }
                }
            } else if (line == 0) {
                // First line: "[avatar ]name: content_start"
                var x_cursor: u32 = @intCast(ix + 1);

                // Draw avatar glyphs before username if enabled
                if (acols > 0) {
                    if (sender_user) |su| {
                        const avatar = su.avatarPatternSlice();
                        if (avatar.len > 0) {
                            buf.drawText(avatar, x_cursor, y_pos, msg.from_color, bg, 0) catch {};
                        } else {
                            // No avatar pattern — draw placeholder spaces
                            buf.drawText("   ", x_cursor, y_pos, t.text_dim, bg, 0) catch {};
                        }
                    } else {
                        // Unknown sender — draw placeholder spaces
                        buf.drawText("   ", x_cursor, y_pos, t.text_dim, bg, 0) catch {};
                    }
                    x_cursor += 3; // 3 glyph columns
                    buf.drawText(" ", x_cursor, y_pos, bg, bg, 0) catch {};
                    x_cursor += 1; // space separator
                }

                buf.drawText(name, x_cursor, y_pos, msg.from_color, bg, name_attr) catch {};
                const name_end: u32 = x_cursor + @as(u32, @intCast(name.len));
                buf.drawText(": ", name_end, y_pos, t.text, bg, 0) catch {};

                if (content_first > 0 and content.len > 0) {
                    const first_len = @min(content.len, content_first);
                    drawTextWithMentions(buf, content[0..first_len], name_end + 2, y_pos, content_fg, t.accent, bg, 0, client);
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
                    drawTextWithMentions(buf, content[offset .. offset + line_len], @intCast(ix + 2), y_pos, content_fg, t.accent, bg, 0, client);
                }
            }
        }

        // Draw unread divider above this message if it's the first unread
        if (client.unread_divider_idx >= 0 and msg_idx == @as(usize, @intCast(client.unread_divider_idx)) and screen_row > 0) {
            screen_row -= 1;
            const div_y: u32 = @intCast(iy + @as(u16, @intCast(screen_row)));
            // Draw "──── NEW ────" centered
            const label = " NEW ";
            const label_len: u16 = @intCast(label.len);
            const dash_left = (iw -| label_len) / 2;
            const dash_right = iw -| dash_left -| label_len;
            var dx: u32 = @intCast(ix);
            // Left dashes
            var di: u16 = 0;
            while (di < dash_left) : (di += 1) {
                buf.drawText("\xe2\x94\x80", dx, div_y, t.warning, t.background, 0) catch {};
                dx += 1;
            }
            // Label
            buf.drawText(label, dx, div_y, t.warning, t.background, 1) catch {}; // bold
            dx += label_len;
            // Right dashes
            di = 0;
            while (di < dash_right) : (di += 1) {
                buf.drawText("\xe2\x94\x80", dx, div_y, t.warning, t.background, 0) catch {};
                dx += 1;
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

    // Typing indicator on the bottom border of the compose panel
    if (client.typing_user_count > 0) {
        var typing_buf: [128]u8 = undefined;
        var typing_len: usize = 0;

        // Build "user1, user2 typing..." or "user1 is typing..."
        var i: usize = 0;
        const count = client.typing_user_count;
        while (i < count and i < 3) : (i += 1) {
            const name = client.typing_users[i][0..client.typing_user_lens[i]];
            if (typing_len + name.len + 2 > typing_buf.len - 16) break; // leave room for suffix
            if (i > 0) {
                @memcpy(typing_buf[typing_len .. typing_len + 2], ", ");
                typing_len += 2;
            }
            @memcpy(typing_buf[typing_len .. typing_len + name.len], name);
            typing_len += name.len;
        }

        const suffix = if (count == 1) " is typing..." else " are typing...";
        if (typing_len + suffix.len <= typing_buf.len) {
            @memcpy(typing_buf[typing_len .. typing_len + suffix.len], suffix);
            typing_len += suffix.len;
        }

        // Draw on the bottom border line
        const typing_x: u32 = @intCast(panel.x + 2);
        const typing_y: u32 = @intCast(panel.y + panel.height - 1);
        const max_display = @min(typing_len, @as(usize, panel.width -| 4));
        if (max_display > 0) {
            buf.drawText(typing_buf[0..max_display], typing_x, typing_y, t.text_muted, t.background, 2) catch {}; // italic
        }
    }
}

/// Render the slash command autocomplete popup above the compose panel.
pub fn renderSlashAutocomplete(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const compose_panel_idx = client.findPanelByKind(.compose) orelse return;
    const panel = &client.panels[compose_panel_idx];

    const count = client.slash_ac_filtered_count;
    if (count == 0) return;
    const visible = @min(count, @as(u8, @intCast(types.MAX_SLASH_VISIBLE)));

    // Calculate popup dimensions
    // Each row: "  /name  description" or "> /name  description"
    var max_row_len: usize = 0;
    for (0..visible) |i| {
        const cmd_idx = client.slash_ac_filtered[i];
        const cmd = &types.SLASH_COMMANDS[cmd_idx];
        // "  /name  description" → 2 + 1 + name.len + 2 + description.len
        const row_len = 2 + 1 + cmd.name.len + 2 + cmd.description.len;
        if (row_len > max_row_len) max_row_len = row_len;
    }

    const popup_w: u16 = @intCast(@min(max_row_len + 4, @as(usize, panel.width))); // +4 for border+padding
    const popup_h: u16 = @intCast(visible + 2); // +2 for top/bottom border

    // Position: above the compose panel, left-aligned with it
    const popup_x: u16 = panel.x;
    const popup_y: u16 = if (panel.y >= popup_h) panel.y - popup_h else 0;

    // Draw bordered box for popup
    drawBorderBox(buf, popup_x, popup_y, popup_w, popup_h, t.border_active, t.background, null, t.text);

    // Draw each filtered command row
    const inner_x: u32 = @intCast(popup_x + 1);
    const inner_y: u32 = @intCast(popup_y + 1);
    const inner_w: usize = if (popup_w > 2) popup_w - 2 else 0;

    for (0..visible) |i| {
        const cmd_idx = client.slash_ac_filtered[i];
        const cmd = &types.SLASH_COMMANDS[cmd_idx];
        const row_y: u32 = inner_y + @as(u32, @intCast(i));
        const is_selected = @as(u8, @intCast(i)) == client.slash_ac_idx;

        // Draw background for selected row
        if (is_selected) {
            var col: usize = 0;
            while (col < inner_w) : (col += 1) {
                buf.drawText(" ", inner_x + @as(u32, @intCast(col)), row_y, t.primary, t.primary, 0) catch {};
            }
        }

        const bg = if (is_selected) t.primary else t.background;
        const name_fg = if (is_selected) t.background else t.accent;
        const desc_fg = if (is_selected) t.background else t.text_muted;

        // Draw prefix
        const prefix = if (is_selected) "> " else "  ";
        buf.drawText(prefix, inner_x, row_y, name_fg, bg, 0) catch {};

        // Draw "/name"
        var x: u32 = inner_x + 2;
        buf.drawText("/", x, row_y, name_fg, bg, 0) catch {};
        x += 1;
        buf.drawText(cmd.name, x, row_y, name_fg, bg, 1) catch {}; // bold
        x += @as(u32, @intCast(cmd.name.len));

        // Draw "  description"
        buf.drawText("  ", x, row_y, desc_fg, bg, 0) catch {};
        x += 2;
        const desc_avail = if (inner_w > (x - inner_x)) inner_w - (x - inner_x) else 0;
        const desc_len = @min(cmd.description.len, desc_avail);
        if (desc_len > 0) {
            buf.drawText(cmd.description[0..desc_len], x, row_y, desc_fg, bg, 0) catch {};
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

        // Unread badge
        if (chan.unread_count > 0 and !is_active) {
            var badge_buf: [6]u8 = undefined;
            const badge = std.fmt.bufPrint(&badge_buf, " ({d})", .{chan.unread_count}) catch "";
            const badge_x: u32 = @intCast(ix + 1 + @as(u16, @intCast(max_name)));
            buf.drawText(badge, badge_x, @intCast(iy + row), t.warning, bg, 1) catch {}; // bold
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

    const acols: u16 = if (client.show_avatars) 4 else 0;

    // Show current user first
    if (client.me) |*me| {
        var mx: u32 = @intCast(ix);
        if (acols > 0) {
            const avatar = me.avatarPatternSlice();
            if (avatar.len > 0) {
                buf.drawText(avatar, mx, @intCast(iy), me.color, t.background, 0) catch {};
            }
            mx += 4; // 3 glyphs + 1 space
        }
        const name = me.nameSlice();
        const avail: usize = if (iw > acols) iw - acols else 0;
        const max_name = @min(name.len, avail);
        buf.drawText(name[0..max_name], mx, @intCast(iy), me.color, t.background, 0) catch {};

        const you_suffix = " (you)";
        const suffix_x: u32 = mx + @as(u32, @intCast(max_name));
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

        var ux: u32 = @intCast(ix);
        if (acols > 0) {
            const avatar = user.avatarPatternSlice();
            if (avatar.len > 0) {
                buf.drawText(avatar, ux, @intCast(iy + row), user.color, bg, 0) catch {};
            }
            ux += 4; // 3 glyphs + 1 space
        }
        const avail: usize = if (iw > acols) iw - acols else 0;
        const max_name = @min(name.len, avail);
        buf.drawText(name[0..max_name], ux, @intCast(iy + row), fg, bg, 0) catch {};

        // Role badge
        if (user.role == .admin) {
            const badge = " [A]";
            const bx: u32 = ux + @as(u32, @intCast(max_name));
            buf.drawText(badge, bx, @intCast(iy + row), ADMIN_BADGE_COLOR, bg, 0) catch {};
        } else if (user.role == .moderator) {
            const badge = " [M]";
            const bx: u32 = ux + @as(u32, @intCast(max_name));
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
            .settings_layout => renderSettingsLayoutModal(client, buf),
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
    for (COLOR_CHOICES, 0..) |color, ci| {
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
        const preview_color = COLOR_CHOICES[client.settings_color_idx];
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
    const w: u16 = @min(55, client.width -| 4);
    const h: u16 = @min(22, client.height -| 4);
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    // Title shows listening state
    const title = if (client.settings_kb_listening) "Keybindings \xe2\x80\x94 Press a key..." else "Keybindings";
    const title_fg = if (client.settings_kb_listening) t.warning else t.primary;
    drawBorderBox(buf, x, y, w, h, t.primary, t.background, title, title_fg);

    const ix: u32 = @intCast(x + 2);
    var iy: u32 = @intCast(y + 2);
    const max_rows: u32 = @intCast(h -| 5); // leave room for footer

    // Show keybindings from draft (so edits are visible before save)
    for (0..types.BINDABLE_COMMAND_COUNT) |i| {
        if (iy - @as(u32, @intCast(y + 2)) >= max_rows) break;
        const is_selected = i == client.settings_kb_idx;
        const combo = client.kb_draft[i];
        const is_default = combo.eql(types.DEFAULT_KEYBINDINGS[i]);

        const fg = if (is_selected) t.background else t.text;
        const bg = if (is_selected) t.primary else t.background;

        if (is_selected) {
            buf.fillRect(ix, iy, @intCast(w -| 4), 1, bg) catch {};
        }

        // Command label
        const label = types.COMMAND_LABELS[i];
        buf.drawText(label, ix, iy, fg, bg, 0) catch {};

        // Key combo (or "..." if listening on this row)
        if (is_selected and client.settings_kb_listening) {
            buf.drawText("...", ix + 22, iy, if (is_selected) fg else t.warning, bg, 0) catch {};
        } else {
            var key_buf: [32]u8 = undefined;
            const key_len = types.formatKeyCombo(combo, &key_buf);
            const key_fg = if (is_selected) fg else if (is_default) t.primary else t.warning;
            buf.drawText(key_buf[0..key_len], ix + 22, iy, key_fg, bg, 0) catch {};
            // Show "*" marker for non-default bindings
            if (!is_default) {
                buf.drawText("*", ix + 22 + @as(u32, @intCast(key_len)) + 1, iy, if (is_selected) fg else t.warning, bg, 0) catch {};
            }
        }

        iy += 1;
    }

    // Footer with instructions
    buf.drawText("\xe2\x86\x91/\xe2\x86\x93 select \xc2\xb7 Enter rebind \xc2\xb7 R reset \xc2\xb7 S save \xc2\xb7 Esc cancel", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}

fn renderSettingsLayoutModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const layout = @import("layout.zig");
    // Modal width: 2 chars per grid col + borders + padding, min 50
    const cell_w: u16 = 2; // each grid cell is 2 chars wide
    const grid_cols = client.layout_draft_grid_cols;
    const grid_rows = client.layout_draft_grid_rows;
    const grid_draw_w: u16 = grid_cols * cell_w;
    const grid_draw_h: u16 = grid_rows;
    const w: u16 = @min(@max(grid_draw_w + 6, 50), client.width -| 4);
    const h: u16 = @min(grid_draw_h + 10, client.height -| 4);
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    const mode_label: []const u8 = switch (client.layout_editor_mode) {
        .navigate => "Layout",
        .select_panel => "Layout \xe2\x80\x94 Pick Type",
        .place => "Layout \xe2\x80\x94 Place Panel",
    };
    const title_fg = if (client.layout_editor_mode == .navigate) t.primary else t.warning;
    drawBorderBox(buf, x, y, w, h, t.primary, t.background, mode_label, title_fg);

    const ix: u32 = @intCast(x + 2);
    const iy_base: u32 = @intCast(y + 2);

    // --- Grid info line ---
    var info_buf: [48]u8 = undefined;
    const info_prefix = "Grid: ";
    @memcpy(info_buf[0..info_prefix.len], info_prefix);
    var ipos: usize = info_prefix.len;
    // cols
    if (grid_cols >= 10) {
        info_buf[ipos] = @intCast(grid_cols / 10 + '0');
        ipos += 1;
    }
    info_buf[ipos] = @intCast(grid_cols % 10 + '0');
    ipos += 1;
    info_buf[ipos] = 'x';
    ipos += 1;
    // rows
    if (grid_rows >= 10) {
        info_buf[ipos] = @intCast(grid_rows / 10 + '0');
        ipos += 1;
    }
    info_buf[ipos] = @intCast(grid_rows % 10 + '0');
    ipos += 1;
    const panels_prefix = "  Panels: ";
    @memcpy(info_buf[ipos .. ipos + panels_prefix.len], panels_prefix);
    ipos += panels_prefix.len;
    if (client.layout_draft_count >= 10) {
        info_buf[ipos] = @intCast(client.layout_draft_count / 10 + '0');
        ipos += 1;
    }
    info_buf[ipos] = @intCast(client.layout_draft_count % 10 + '0');
    ipos += 1;
    buf.drawText(info_buf[0..ipos], ix, iy_base, t.text_muted, t.background, 0) catch {};

    // --- Grid rendering ---
    const grid_y: u32 = iy_base + 1;
    const grid_x: u32 = ix;

    // For each grid cell, determine what to draw
    var row: u16 = 0;
    while (row < grid_rows) : (row += 1) {
        var col: u16 = 0;
        while (col < grid_cols) : (col += 1) {
            const cx: u32 = grid_x + @as(u32, col) * cell_w;
            const cy: u32 = grid_y + @as(u32, row);

            // Skip if outside modal
            if (cx + cell_w > @as(u32, x) + @as(u32, w) - 2) break;
            if (cy >= @as(u32, y) + @as(u32, h) - 3) break;

            const is_cursor = (col == client.layout_cursor_col and row == client.layout_cursor_row);

            // Check if cell is in place-mode selection rectangle
            var in_selection = false;
            if (client.layout_editor_mode == .place) {
                const sel_c0 = @min(client.layout_anchor_col, client.layout_cursor_col);
                const sel_c1 = @max(client.layout_anchor_col, client.layout_cursor_col);
                const sel_r0 = @min(client.layout_anchor_row, client.layout_cursor_row);
                const sel_r1 = @max(client.layout_anchor_row, client.layout_cursor_row);
                if (col >= sel_c0 and col <= sel_c1 and row >= sel_r0 and row <= sel_r1) {
                    in_selection = true;
                }
            }

            // Find which panel occupies this cell
            const occupant = layout.cellOccupant(&client.layout_draft_panels, client.layout_draft_count, col, row);

            var fg = t.text_dim;
            var bg = t.background;
            var label: []const u8 = "\xc2\xb7\xc2\xb7"; // "··" (middle dot x2, 2 chars wide)

            if (occupant) |pi| {
                const p = client.layout_draft_panels[pi];
                const kind_idx: usize = @intFromEnum(p.kind);
                // Color panels with muted theme color
                fg = t.text;
                bg = t.background_panel;

                // Show short label at the center of the panel region
                const center_col = p.col + p.col_span / 2;
                const center_row = p.row + p.row_span / 2;
                if (col == center_col and row == center_row and kind_idx < types.PANEL_SHORT.len) {
                    label = types.PANEL_SHORT[kind_idx];
                } else {
                    label = "\xe2\x96\x91\xe2\x96\x91"; // "░░" light shade x2
                }
            }

            if (in_selection) {
                fg = t.background;
                bg = t.warning;
                label = "\xe2\x96\x93\xe2\x96\x93"; // "▓▓" dark shade
            }

            if (is_cursor) {
                fg = t.background;
                bg = t.primary;
                if (in_selection) {
                    bg = t.accent;
                }
            }

            buf.fillRect(cx, cy, cell_w, 1, bg) catch {};
            buf.drawText(label, cx, cy, fg, bg, 0) catch {};
        }
    }

    // --- Panel type picker (shown in select_panel mode) ---
    if (client.layout_editor_mode == .select_panel) {
        const picker_x: u32 = grid_x + @as(u32, grid_draw_w) + 3;
        var picker_y: u32 = grid_y;
        buf.drawText("Panel type:", picker_x, picker_y, t.text, t.background, 1) catch {};
        picker_y += 1;
        for (types.PANEL_TYPE_LABELS, 0..) |lbl, i| {
            if (picker_y >= @as(u32, y) + @as(u32, h) - 3) break;
            const is_sel = i == client.layout_panel_type_idx;
            const pfg = if (is_sel) t.background else t.text;
            const pbg = if (is_sel) t.primary else t.background;
            if (is_sel) {
                buf.fillRect(picker_x, picker_y, 12, 1, pbg) catch {};
                buf.drawText("> ", picker_x, picker_y, pfg, pbg, 1) catch {};
                buf.drawText(lbl, picker_x + 2, picker_y, pfg, pbg, 1) catch {};
            } else {
                buf.drawText("  ", picker_x, picker_y, pfg, pbg, 0) catch {};
                buf.drawText(lbl, picker_x + 2, picker_y, pfg, pbg, 0) catch {};
            }
            picker_y += 1;
        }
    }

    // --- Error message ---
    if (client.layout_error_len > 0) {
        const err_y: u32 = @intCast(y + h - 4);
        buf.drawText(client.layout_error[0..client.layout_error_len], ix, err_y, t.err, t.background, 0) catch {};
    }

    // --- Footer with keybinding hints ---
    const footer_y: u32 = @intCast(y + h - 2);
    switch (client.layout_editor_mode) {
        .navigate => {
            buf.drawText("\xe2\x86\x91\xe2\x86\x93\xe2\x86\x90\xe2\x86\x92 move  A add  D del  [/] cols  -/= rows", ix, footer_y, t.text_dim, t.background, 0) catch {};
            buf.drawText("R reset  S save  Esc back", ix, footer_y + 1, t.text_dim, t.background, 0) catch {};
        },
        .select_panel => {
            buf.drawText("\xe2\x86\x91/\xe2\x86\x93 pick type  Enter place  Esc cancel", ix, footer_y, t.text_dim, t.background, 0) catch {};
        },
        .place => {
            buf.drawText("\xe2\x86\x91\xe2\x86\x93\xe2\x86\x90\xe2\x86\x92 resize  Enter confirm  Esc cancel", ix, footer_y, t.text_dim, t.background, 0) catch {};
        },
    }
}

fn renderSettingsAvatarModal(client: *const ChatClient, buf: *OptimizedBuffer) void {
    const t = client.theme;
    const w: u16 = @min(40, client.width -| 4);
    const h: u16 = 10;
    const x = @max(2, (client.width -| w) / 2);
    const y = @max(2, (client.height -| h) / 2);

    drawBorderBox(buf, x, y, w, h, t.primary, t.background, "Avatar Designer", t.primary);

    const ix: u32 = @intCast(x + 2);
    const iy: u32 = @intCast(y + 2);

    // Show 3 glyph slots with cursor and actual glyphs
    for (0..3) |col| {
        const cx = ix + @as(u32, @intCast(col)) * 4;
        const is_cursor = col == client.settings_avatar_col;
        const glyph_idx = client.settings_avatar_draft[col] % types.AVATAR_GLYPH_COUNT;
        const glyph = types.AVATAR_GLYPHS[glyph_idx];
        const fg = if (is_cursor) t.primary else t.text;
        const attr: u32 = if (is_cursor) 1 else 0; // bold if cursor

        if (is_cursor) {
            buf.drawText("[", cx, iy, t.primary, t.background, 0) catch {};
            buf.drawText("]", cx + 2, iy, t.primary, t.background, 0) catch {};
        }
        buf.drawText(glyph, cx + 1, iy, fg, t.background, attr) catch {};
    }

    // Preview: show all 3 glyphs together
    buf.drawText("Preview: ", ix, iy + 2, t.text_muted, t.background, 0) catch {};
    var preview_x: u32 = ix + 9;
    for (0..3) |col| {
        const glyph_idx = client.settings_avatar_draft[col] % types.AVATAR_GLYPH_COUNT;
        const glyph = types.AVATAR_GLYPHS[glyph_idx];
        buf.drawText(glyph, preview_x, iy + 2, t.accent, t.background, 0) catch {};
        preview_x += 1;
    }

    buf.drawText("\xe2\x86\x90\xe2\x86\x92 move  \xe2\x86\x91\xe2\x86\x93 cycle  Enter save", ix, iy + 4, t.text_dim, t.background, 0) catch {};
    buf.drawText("Esc back", ix, @intCast(y + h - 2), t.text_dim, t.background, 0) catch {};
}
