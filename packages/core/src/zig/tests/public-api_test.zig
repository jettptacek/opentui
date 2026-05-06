// Pins the public Zig consumer surface from opentui.zig. If a symbol here
// stops resolving, downstream `@import("opentui")` users break — fix the
// re-export in opentui.zig (or update this list intentionally).

const std = @import("std");
const opentui = @import("../opentui.zig");

test "opentui re-exports resolve" {
    _ = opentui.OptimizedBuffer;
    _ = opentui.RGBA;
    _ = opentui.CliRenderer;
    _ = opentui.GraphemePool;
    _ = opentui.EditBuffer;
    _ = opentui.EditorView;

    _ = opentui.buffer;
    _ = opentui.renderer;
    _ = opentui.grapheme;
    _ = opentui.edit_buffer;
    _ = opentui.editor_view;
    _ = opentui.text_buffer;
    _ = opentui.text_buffer_view;
    _ = opentui.terminal;
    _ = opentui.utf8;
}

test "opentui types are usable end-to-end" {
    var pool = opentui.GraphemePool.init(std.testing.allocator);
    defer pool.deinit();

    const buf = try opentui.OptimizedBuffer.init(
        std.testing.allocator,
        80,
        24,
        .{ .pool = &pool },
    );
    defer buf.deinit();

    try std.testing.expectEqual(@as(u32, 80), buf.width);
    try std.testing.expectEqual(@as(u32, 24), buf.height);
}
