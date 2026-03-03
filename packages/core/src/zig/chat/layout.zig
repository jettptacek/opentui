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
///   Row 1-8: Channels (cols 0-1) | Messages (cols 2-7) | Members (cols 8-9)
///   Row 9:   Compose (full width, 1 row)
pub fn initDefaultLayout(panels: []Panel) u8 {
    if (panels.len < 5) return 0;

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
        .col_span = 6,
        .row_span = 8,
        .group = 0,
    };

    panels[3] = .{
        .kind = .members,
        .col = 8,
        .row = 1,
        .col_span = 2,
        .row_span = 8,
        .group = 0,
    };

    panels[4] = .{
        .kind = .compose,
        .col = 0,
        .row = 9,
        .col_span = DEFAULT_GRID_COLS,
        .row_span = 1,
        .group = 0,
    };

    return 5;
}

/// Check whether two rectangles overlap in the grid.
pub fn regionOverlaps(
    a_col: u16, a_row: u16, a_cs: u16, a_rs: u16,
    b_col: u16, b_row: u16, b_cs: u16, b_rs: u16,
) bool {
    if (a_col + a_cs <= b_col) return false;
    if (b_col + b_cs <= a_col) return false;
    if (a_row + a_rs <= b_row) return false;
    if (b_row + b_rs <= a_row) return false;
    return true;
}

/// Find which panel index occupies a given grid cell, or null if empty.
pub fn cellOccupant(panels: []const Panel, count: u8, col: u16, row: u16) ?u8 {
    for (panels[0..count], 0..) |*p, i| {
        if (col >= p.col and col < p.col + p.col_span and
            row >= p.row and row < p.row + p.row_span)
        {
            return @intCast(i);
        }
    }
    return null;
}

/// Check if placing a panel at the given region would overlap any existing panel.
pub fn hasOverlap(panels: []const Panel, count: u8, col: u16, row: u16, cs: u16, rs: u16) bool {
    for (panels[0..count]) |*p| {
        if (regionOverlaps(col, row, cs, rs, p.col, p.row, p.col_span, p.row_span)) {
            return true;
        }
    }
    return false;
}

/// Check if a layout has at least one messages panel and one compose panel.
pub fn validateLayout(panels: []const Panel, count: u8) bool {
    var has_messages = false;
    var has_compose = false;
    for (panels[0..count]) |*p| {
        if (p.kind == .messages) has_messages = true;
        if (p.kind == .compose) has_compose = true;
    }
    return has_messages and has_compose;
}
