// chat/layout.zig — Grid-based proportional layout engine
// Replaces Yoga flexbox with simple grid math
const types = @import("types.zig");
const Panel = types.Panel;

pub const DEFAULT_GRID_COLS: u16 = 10;
pub const DEFAULT_GRID_ROWS: u16 = 10;
pub const MIN_GRID: u16 = 2;
pub const MAX_GRID: u16 = 20;

/// Compute pixel positions for all panels based on grid proportions
pub fn computeLayout(
    panels: []Panel,
    term_width: u16,
    term_height: u16,
    grid_cols: u16,
    grid_rows: u16,
) void {
    if (grid_cols == 0 or grid_rows == 0) return;

    for (panels) |*p| {
        if (!p.visible) continue;

        // Proportional positioning with integer division
        p.x = @intCast(@as(u32, p.col) * @as(u32, term_width) / @as(u32, grid_cols));
        p.y = @intCast(@as(u32, p.row) * @as(u32, term_height) / @as(u32, grid_rows));

        // Width/height: compute end position then subtract start
        const end_col = p.col + p.col_span;
        const end_row = p.row + p.row_span;

        const end_x: u16 = @intCast(@as(u32, end_col) * @as(u32, term_width) / @as(u32, grid_cols));
        const end_y: u16 = @intCast(@as(u32, end_row) * @as(u32, term_height) / @as(u32, grid_rows));

        p.width = end_x - p.x;
        p.height = end_y - p.y;
    }
}

/// Initialize the default layout:
///   Row 0:   Header (full width, 1 row)
///   Row 1-8: Channels (2 cols) | Messages (8 cols)
///   Row 9:   Compose (full width, 1 row)
pub fn initDefaultLayout(panels: []Panel) u8 {
    if (panels.len < 4) return 0;

    panels[0] = .{
        .kind = .header,
        .col = 0,
        .row = 0,
        .col_span = DEFAULT_GRID_COLS,
        .row_span = 1,
        .group = 0,
    };

    panels[1] = .{
        .kind = .channels,
        .col = 0,
        .row = 1,
        .col_span = 2,
        .row_span = 8,
        .group = 0,
    };

    panels[2] = .{
        .kind = .messages,
        .col = 2,
        .row = 1,
        .col_span = 8,
        .row_span = 8,
        .group = 0,
    };

    panels[3] = .{
        .kind = .compose,
        .col = 0,
        .row = 9,
        .col_span = DEFAULT_GRID_COLS,
        .row_span = 1,
        .group = 0,
    };

    return 4;
}
