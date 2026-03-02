// chat/event-queue.zig — Ring buffer of outgoing events from Zig → TS
// The Zig chat client produces events (send message, switch channel, etc.)
// that TS polls via chatClientPollEvent(). Events are serialized as
// simple tagged byte strings.
const std = @import("std");
const types = @import("types.zig");

pub const MAX_EVENT_SIZE = 4096 + 128; // max message content + metadata
pub const MAX_EVENTS = 32;

/// Event tags — first byte of each event identifies the type.
/// TS reads the tag to determine how to parse the rest.
pub const EventTag = enum(u8) {
    send_message = 1, // payload: channel_len(u8) + channel + content
    switch_channel = 2, // payload: channel name
    register = 3, // payload: name_len(u8) + name + color(4xf32) + theme_id
    quit = 4, // no payload
    typing_start = 5, // no payload (TS infers channel from current state)
    typing_stop = 6, // no payload
    leave_dm = 7, // no payload (TS infers channel)
    toggle_reaction = 8, // payload: msg_id + emoji
    focus_changed = 9, // payload: panel_kind(u8)
    // Future: update_profile, create_dm, etc.
};

pub const EventQueue = struct {
    events: [MAX_EVENTS][MAX_EVENT_SIZE]u8,
    lengths: [MAX_EVENTS]u16,
    head: u8, // next to read
    tail: u8, // next to write
    count: u8,

    pub fn init() EventQueue {
        return .{
            .events = undefined,
            .lengths = [_]u16{0} ** MAX_EVENTS,
            .head = 0,
            .tail = 0,
            .count = 0,
        };
    }

    /// Push an event. Returns false if queue is full (event dropped).
    pub fn push(self: *EventQueue, data: []const u8) bool {
        if (self.count >= MAX_EVENTS) return false;
        if (data.len > MAX_EVENT_SIZE) return false;
        const len: u16 = @intCast(data.len);
        @memcpy(self.events[self.tail][0..data.len], data);
        self.lengths[self.tail] = len;
        self.tail = (self.tail + 1) % MAX_EVENTS;
        self.count += 1;
        return true;
    }

    /// Push a tagged event with a simple string payload.
    pub fn pushTagged(self: *EventQueue, tag: EventTag, payload: []const u8) bool {
        if (self.count >= MAX_EVENTS) return false;
        if (payload.len + 1 > MAX_EVENT_SIZE) return false;
        self.events[self.tail][0] = @intFromEnum(tag);
        @memcpy(self.events[self.tail][1 .. 1 + payload.len], payload);
        self.lengths[self.tail] = @intCast(1 + payload.len);
        self.tail = (self.tail + 1) % MAX_EVENTS;
        self.count += 1;
        return true;
    }

    /// Push a send_message event: tag(1) + channel_len(1) + channel + content
    pub fn pushSendMessage(self: *EventQueue, channel: []const u8, content: []const u8) bool {
        if (self.count >= MAX_EVENTS) return false;
        const total = 1 + 1 + channel.len + content.len;
        if (total > MAX_EVENT_SIZE) return false;
        var buf = &self.events[self.tail];
        buf[0] = @intFromEnum(EventTag.send_message);
        buf[1] = @intCast(channel.len);
        @memcpy(buf[2 .. 2 + channel.len], channel);
        @memcpy(buf[2 + channel.len .. 2 + channel.len + content.len], content);
        self.lengths[self.tail] = @intCast(total);
        self.tail = (self.tail + 1) % MAX_EVENTS;
        self.count += 1;
        return true;
    }

    /// Push a register event: tag(1) + name_len(1) + name + r(f32) + g + b + a + theme_id
    pub fn pushRegister(self: *EventQueue, name: []const u8, color: [4]f32, theme_id: []const u8) bool {
        if (self.count >= MAX_EVENTS) return false;
        const total = 1 + 1 + name.len + 16 + theme_id.len;
        if (total > MAX_EVENT_SIZE) return false;
        var buf = &self.events[self.tail];
        var off: usize = 0;
        buf[off] = @intFromEnum(EventTag.register);
        off += 1;
        buf[off] = @intCast(name.len);
        off += 1;
        @memcpy(buf[off .. off + name.len], name);
        off += name.len;
        // Color as 4 little-endian f32
        inline for (0..4) |ci| {
            const bytes = std.mem.toBytes(color[ci]);
            @memcpy(buf[off .. off + 4], &bytes);
            off += 4;
        }
        @memcpy(buf[off .. off + theme_id.len], theme_id);
        off += theme_id.len;
        self.lengths[self.tail] = @intCast(off);
        self.tail = (self.tail + 1) % MAX_EVENTS;
        self.count += 1;
        return true;
    }

    /// Poll the next event. Copies up to max_len bytes into out_ptr.
    /// Returns the number of bytes written, or 0 if no events.
    pub fn poll(self: *EventQueue, out_ptr: [*]u8, max_len: u32) u32 {
        if (self.count == 0) return 0;
        const len = self.lengths[self.head];
        const copy_len: u32 = @min(len, max_len);
        @memcpy(out_ptr[0..copy_len], self.events[self.head][0..copy_len]);
        self.head = (self.head + 1) % MAX_EVENTS;
        self.count -= 1;
        return copy_len;
    }

    /// Check if there are pending events.
    pub fn hasEvents(self: *const EventQueue) bool {
        return self.count > 0;
    }
};
