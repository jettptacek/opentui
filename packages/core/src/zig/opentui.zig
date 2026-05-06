// opentui.zig — Public Zig API surface.
// For TS / FFI consumers, see lib.zig.

pub const buffer = @import("buffer.zig");
pub const OptimizedBuffer = buffer.OptimizedBuffer;
pub const RGBA = buffer.RGBA;

pub const renderer = @import("renderer.zig");
pub const CliRenderer = renderer.CliRenderer;

pub const grapheme = @import("grapheme.zig");
pub const GraphemePool = grapheme.GraphemePool;

pub const edit_buffer = @import("edit-buffer.zig");
pub const EditBuffer = edit_buffer.EditBuffer;

pub const editor_view = @import("editor-view.zig");
pub const EditorView = editor_view.EditorView;

pub const text_buffer = @import("text-buffer.zig");
pub const text_buffer_view = @import("text-buffer-view.zig");
pub const terminal = @import("terminal.zig");
pub const utf8 = @import("utf8.zig");
