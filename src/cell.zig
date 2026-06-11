const std = @import("std");
const style = @import("style.zig");

pub const CellChar = struct {
    /// UTF-8 grapheme bytes. Borrowed by `Surface.writeCell` and borrowed from
    /// the screen buffer by `Surface.readCell`.
    grapheme: []const u8 = " ",

    /// Display width in terminal cells.
    ///
    /// `0` means unknown/backend-measured width. It is not a trailing or
    /// continuation-cell marker, so app code should not use it to detect the
    /// second cell of a wide grapheme.
    width: u8 = 1,

    pub fn eql(self: CellChar, other: CellChar) bool {
        return self.width == other.width and std.mem.eql(u8, self.grapheme, other.grapheme);
    }
};

/// Backend-neutral text/style cell exposed to apps and components.
///
/// It represents only the drawing state Chasen APIs create directly. Backend
/// metadata such as terminal-image placement or hyperlinks is intentionally not
/// part of this public type.
pub const Cell = struct {
    char: CellChar = .{},
    style: style.TextStyle = .{},

    pub const blank: Cell = .{};

    pub fn eql(self: Cell, other: Cell) bool {
        return self.char.eql(other.char) and self.style.eql(other.style);
    }

    /// Structural blank check. Style is intentionally ignored.
    pub fn isBlank(self: Cell) bool {
        const blank_grapheme = self.char.grapheme.len == 0 or std.mem.eql(u8, self.char.grapheme, " ");
        return blank_grapheme and self.char.width <= 1;
    }

    /// Structural visible-text check. Style is intentionally ignored.
    pub fn isVisibleText(self: Cell) bool {
        return self.char.width > 0 and self.char.grapheme.len > 0 and !std.mem.eql(u8, self.char.grapheme, " ");
    }
};

pub const CursorShape = enum {
    default,
    block,
    beam,
    underline,
};

test "Cell structural predicates ignore style" {
    const blank: Cell = .{ .style = .{ .bg = .{ .index = 2 } } };
    try std.testing.expect(blank.isBlank());
    try std.testing.expect(!blank.isVisibleText());

    const visible: Cell = .{ .char = .{ .grapheme = "x", .width = 1 }, .style = .{ .dim = true } };
    try std.testing.expect(!visible.isBlank());
    try std.testing.expect(visible.isVisibleText());
}

test "CellChar width zero is unknown width, not a continuation marker" {
    const unknown_width: Cell = .{ .char = .{ .grapheme = "x", .width = 0 } };
    try std.testing.expect(!unknown_width.isBlank());
    try std.testing.expect(!unknown_width.isVisibleText());

    const unknown_blank: Cell = .{ .char = .{ .grapheme = " ", .width = 0 } };
    try std.testing.expect(unknown_blank.isBlank());
    try std.testing.expect(!unknown_blank.isVisibleText());
}

test "Cell.eql compares char and style" {
    const a: Cell = .{ .char = .{ .grapheme = "x", .width = 1 }, .style = .{ .fg = .gray } };
    const b: Cell = .{ .char = .{ .grapheme = "x", .width = 1 }, .style = .{ .fg = .{ .index = 8 } } };
    try std.testing.expect(a.eql(b));
}
