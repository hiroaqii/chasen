const std = @import("std");
const vaxis = @import("vaxis");
const style = @import("style.zig");
const TextStyle = style.TextStyle;

/// Options for creating a `Column` layout.
pub const ColumnOptions = struct {
    /// Line distance between elements. gap=1 means adjacent rows (default),
    /// gap=2 leaves one blank line between elements.
    gap: u16 = 1,
};

/// A drawable surface backed by a vaxis `Window`.
pub const Surface = struct {
    window: vaxis.Window,
    arena: std.mem.Allocator,

    /// Create a vertical column layout within this surface.
    pub fn column(self: *Surface, opts: ColumnOptions) Column {
        return .{
            .window = self.window,
            .arena = self.arena,
            .row = 0,
            .gap = opts.gap,
        };
    }
};

/// A vertical layout that places text elements top-to-bottom.
pub const Column = struct {
    window: vaxis.Window,
    arena: std.mem.Allocator,
    row: u16,
    gap: u16,

    /// Print a styled text segment at the current row, then advance
    /// the cursor by `gap` rows.
    pub fn text(self: *Column, str: []const u8, ts: TextStyle) void {
        const result = self.window.printSegment(.{
            .text = str,
            .style = ts.toVaxis(),
        }, .{ .row_offset = self.row });
        self.row = result.row + self.gap;
    }

    /// Format and print text using the default style.
    /// Returns an error if formatting allocation fails.
    pub fn textf(self: *Column, comptime fmt: []const u8, args: anytype) !void {
        const str = try std.fmt.allocPrint(self.arena, fmt, args);
        self.text(str, .{});
    }
};
