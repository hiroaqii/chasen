const std = @import("std");
const vaxis = @import("vaxis");
const style = @import("style.zig");
const TextStyle = style.TextStyle;

/// A terminal cell in the underlying screen buffer.
pub const Cell = vaxis.Cell;

/// Terminal cursor shape.
pub const CursorShape = vaxis.Cell.CursorShape;

/// Size of a drawable surface, in terminal cells.
pub const Size = struct {
    width: u16,
    height: u16,
};

/// A rectangular region, in terminal cells.
pub const Rect = struct {
    col: u16,
    row: u16,
    width: u16,
    height: u16,
};

/// Result of printing text into a surface.
pub const PrintResult = struct {
    col: u16,
    row: u16,
    overflow: bool,

    fn fromVaxis(result: vaxis.Window.PrintResult) PrintResult {
        return .{
            .col = result.col,
            .row = result.row,
            .overflow = result.overflow,
        };
    }
};

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

    /// Return the current drawable size in terminal cells.
    pub fn size(self: *const Surface) Size {
        return .{
            .width = self.window.width,
            .height = self.window.height,
        };
    }

    /// Return the frame-scoped allocator.
    ///
    /// Memory allocated from this allocator is reset after the current frame.
    /// Do not store references to it in Model, Msg, or ComponentStore state.
    pub fn frameAllocator(self: *const Surface) std.mem.Allocator {
        return self.arena;
    }

    /// Write one cell at `col`, `row`.
    ///
    /// Out-of-bounds writes are ignored by libvaxis.
    pub fn writeCell(self: *Surface, col: u16, row: u16, cell: Cell) void {
        self.window.writeCell(col, row, cell);
    }

    /// Read one cell at `col`, `row`.
    pub fn readCell(self: *const Surface, col: u16, row: u16) ?Cell {
        return self.window.readCell(col, row);
    }

    /// Print styled text at `col`, `row` without wrapping.
    pub fn textAt(self: *Surface, col: u16, row: u16, str: []const u8, ts: TextStyle) PrintResult {
        return .fromVaxis(self.window.printSegment(.{
            .text = str,
            .style = ts.toVaxis(),
        }, .{
            .col_offset = col,
            .row_offset = row,
            .wrap = .none,
        }));
    }

    /// Return the terminal display width of `str`.
    pub fn displayWidth(self: *const Surface, str: []const u8) u16 {
        return self.window.gwidth(str);
    }

    /// Alias for `displayWidth`.
    pub fn gwidth(self: *const Surface, str: []const u8) u16 {
        return self.displayWidth(str);
    }

    /// Fill `rect` with `cell`.
    pub fn fill(self: *Surface, rect: Rect, cell: Cell) void {
        self.windowForRect(rect).fill(cell);
    }

    /// Clear `rect` to the default terminal cell.
    pub fn clear(self: *Surface, rect: Rect) void {
        self.fill(rect, .{ .default = true });
    }

    /// Create a child surface clipped to `rect`.
    pub fn child(self: *Surface, rect: Rect) Surface {
        return .{
            .window = self.windowForRect(rect),
            .arena = self.arena,
        };
    }

    /// Scroll `rect` upward by `rows`, inserting blank rows at the bottom.
    pub fn scroll(self: *Surface, rect: Rect, rows: u16) void {
        if (rows == 0 or rect.width == 0 or rect.height == 0) return;

        var child_surface = self.child(rect);
        if (rows >= child_surface.window.height) {
            child_surface.clearAll();
            return;
        }

        var row: u16 = 0;
        while (row < child_surface.window.height - rows) : (row += 1) {
            var col: u16 = 0;
            while (col < child_surface.window.width) : (col += 1) {
                const cell = child_surface.readCell(col, row + rows) orelse Cell{};
                child_surface.writeCell(col, row, cell);
            }
        }

        child_surface.clear(.{
            .col = 0,
            .row = child_surface.window.height - rows,
            .width = child_surface.window.width,
            .height = rows,
        });
    }

    fn windowForRect(self: *Surface, rect: Rect) vaxis.Window {
        return self.window.child(.{
            .x_off = @intCast(rect.col),
            .y_off = @intCast(rect.row),
            .width = rect.width,
            .height = rect.height,
        });
    }

    /// Show the terminal cursor at `col`, `row`.
    pub fn showCursor(self: *Surface, col: u16, row: u16) void {
        self.window.showCursor(col, row);
    }

    /// Hide the terminal cursor.
    pub fn hideCursor(self: *Surface) void {
        self.window.hideCursor();
    }

    /// Set the terminal cursor shape.
    pub fn setCursorShape(self: *Surface, shape: CursorShape) void {
        self.window.setCursorShape(shape);
    }

    /// Fill the entire surface with `cell`.
    pub fn fillAll(self: *Surface, cell: Cell) void {
        self.window.fill(cell);
    }

    /// Clear the entire surface to the default terminal cell.
    pub fn clearAll(self: *Surface) void {
        self.window.clear();
    }

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

const TestSurface = struct {
    screen: vaxis.Screen,
    surface: Surface,

    fn deinit(self: *@This()) void {
        self.screen.deinit(std.testing.allocator);
    }

    /// Window stores a pointer to Screen, so bind after TestSurface has moved
    /// into the caller's stack slot.
    fn bind(self: *@This()) void {
        self.surface.window.screen = &self.screen;
    }
};

fn testSurface(width: u16, height: u16) !TestSurface {
    const screen = try vaxis.Screen.init(std.testing.allocator, .{
        .cols = width,
        .rows = height,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    const window: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = undefined,
    };
    return .{
        .screen = screen,
        .surface = .{
            .window = window,
            .arena = std.testing.allocator,
        },
    };
}

test "Surface.size returns window dimensions" {
    var ts = try testSurface(12, 7);
    ts.bind();
    defer ts.deinit();

    const size_value = ts.surface.size();
    try std.testing.expectEqual(@as(u16, 12), size_value.width);
    try std.testing.expectEqual(@as(u16, 7), size_value.height);
}

test "Surface.frameAllocator returns configured allocator" {
    var ts = try testSurface(2, 2);
    ts.bind();
    defer ts.deinit();

    const ptr = try ts.surface.frameAllocator().create(u32);
    defer ts.surface.frameAllocator().destroy(ptr);
    ptr.* = 42;
    try std.testing.expectEqual(@as(u32, 42), ptr.*);
}

test "Surface.writeCell writes through to the window" {
    var ts = try testSurface(3, 2);
    ts.bind();
    defer ts.deinit();

    ts.surface.writeCell(1, 0, .{
        .char = .{ .grapheme = "x", .width = 1 },
        .style = .{ .bold = true },
    });

    const cell = ts.surface.window.readCell(1, 0).?;
    try std.testing.expectEqualStrings("x", cell.char.grapheme);
    try std.testing.expect(cell.style.bold);
}

test "Surface.readCell reads through from the window" {
    var ts = try testSurface(3, 2);
    ts.bind();
    defer ts.deinit();

    ts.surface.writeCell(2, 1, .{ .char = .{ .grapheme = "r", .width = 1 } });

    const cell = ts.surface.readCell(2, 1).?;
    try std.testing.expectEqualStrings("r", cell.char.grapheme);
    try std.testing.expect(ts.surface.readCell(3, 1) == null);
}

test "Surface.displayWidth and gwidth use terminal width rules" {
    var ts = try testSurface(10, 2);
    ts.bind();
    defer ts.deinit();

    try std.testing.expectEqual(@as(u16, 3), ts.surface.displayWidth("abc"));
    try std.testing.expectEqual(ts.surface.displayWidth("abc"), ts.surface.gwidth("abc"));
}

test "Surface.displayWidth handles wide characters" {
    var ts = try testSurface(10, 2);
    ts.bind();
    defer ts.deinit();

    try std.testing.expectEqual(@as(u16, 2), ts.surface.displayWidth("あ"));
}

test "Surface.textAt prints unwrapped styled text at coordinates" {
    var ts = try testSurface(4, 2);
    ts.bind();
    defer ts.deinit();

    const result = ts.surface.textAt(1, 0, "abc", .{ .fg = .{ .index = 2 } });

    try std.testing.expectEqual(@as(u16, 4), result.col);
    try std.testing.expectEqual(@as(u16, 0), result.row);
    try std.testing.expect(!result.overflow);

    const a = ts.surface.window.readCell(1, 0).?;
    const c = ts.surface.window.readCell(3, 0).?;
    try std.testing.expectEqualStrings("a", a.char.grapheme);
    try std.testing.expectEqualStrings("c", c.char.grapheme);
    try std.testing.expect(a.style.fg.eql(.{ .index = 2 }));
}

test "Surface.fill and clear affect a rect" {
    var ts = try testSurface(3, 3);
    ts.bind();
    defer ts.deinit();

    ts.surface.fill(.{ .col = 1, .row = 1, .width = 2, .height = 2 }, .{
        .char = .{ .grapheme = "#", .width = 1 },
        .style = .{ .dim = true },
    });

    const outside = ts.surface.window.readCell(0, 0).?;
    const inside = ts.surface.window.readCell(2, 2).?;
    try std.testing.expectEqualStrings(" ", outside.char.grapheme);
    try std.testing.expectEqualStrings("#", inside.char.grapheme);
    try std.testing.expect(inside.style.dim);

    ts.surface.clear(.{ .col = 1, .row = 1, .width = 2, .height = 2 });

    const cleared = ts.surface.window.readCell(2, 2).?;
    try std.testing.expectEqualStrings(" ", cleared.char.grapheme);
    try std.testing.expect(!cleared.style.dim);
}

test "Surface.child returns a clipped child surface" {
    var ts = try testSurface(4, 3);
    ts.bind();
    defer ts.deinit();

    var child = ts.surface.child(.{ .col = 1, .row = 1, .width = 2, .height = 1 });

    const child_size = child.size();
    try std.testing.expectEqual(@as(u16, 2), child_size.width);
    try std.testing.expectEqual(@as(u16, 1), child_size.height);
    try std.testing.expectEqual(ts.surface.frameAllocator().ptr, child.frameAllocator().ptr);

    child.writeCell(0, 0, .{ .char = .{ .grapheme = "a", .width = 1 } });
    child.writeCell(1, 0, .{ .char = .{ .grapheme = "b", .width = 1 } });
    child.writeCell(2, 0, .{ .char = .{ .grapheme = "x", .width = 1 } });

    const outside = ts.surface.window.readCell(0, 1).?;
    const a = ts.surface.window.readCell(1, 1).?;
    const b = ts.surface.window.readCell(2, 1).?;
    const clipped = ts.surface.window.readCell(3, 1).?;

    try std.testing.expectEqualStrings(" ", outside.char.grapheme);
    try std.testing.expectEqualStrings("a", a.char.grapheme);
    try std.testing.expectEqualStrings("b", b.char.grapheme);
    try std.testing.expectEqualStrings(" ", clipped.char.grapheme);
}

test "Surface.child clamps rect to parent bounds" {
    var ts = try testSurface(4, 3);
    ts.bind();
    defer ts.deinit();

    var child = ts.surface.child(.{ .col = 3, .row = 2, .width = 5, .height = 5 });

    const child_size = child.size();
    try std.testing.expectEqual(@as(u16, 1), child_size.width);
    try std.testing.expectEqual(@as(u16, 1), child_size.height);

    child.fillAll(.{ .char = .{ .grapheme = "x", .width = 1 } });

    const outside = ts.surface.window.readCell(2, 2).?;
    const inside = ts.surface.window.readCell(3, 2).?;

    try std.testing.expectEqualStrings(" ", outside.char.grapheme);
    try std.testing.expectEqualStrings("x", inside.char.grapheme);
}

test "Surface.scroll affects only the requested rect" {
    var ts = try testSurface(4, 4);
    ts.bind();
    defer ts.deinit();

    ts.surface.writeCell(1, 1, .{ .char = .{ .grapheme = "a", .width = 1 } });
    ts.surface.writeCell(1, 2, .{ .char = .{ .grapheme = "b", .width = 1 } });
    ts.surface.writeCell(1, 3, .{ .char = .{ .grapheme = "c", .width = 1 } });
    ts.surface.writeCell(0, 2, .{ .char = .{ .grapheme = "x", .width = 1 } });

    ts.surface.scroll(.{ .col = 1, .row = 1, .width = 2, .height = 3 }, 1);

    const unchanged = ts.surface.readCell(0, 2).?;
    const row1 = ts.surface.readCell(1, 1).?;
    const row2 = ts.surface.readCell(1, 2).?;
    const row3 = ts.surface.readCell(1, 3).?;

    try std.testing.expectEqualStrings("x", unchanged.char.grapheme);
    try std.testing.expectEqualStrings("b", row1.char.grapheme);
    try std.testing.expectEqualStrings("c", row2.char.grapheme);
    try std.testing.expectEqualStrings(" ", row3.char.grapheme);
}

test "Surface.scroll clears rect when rows reaches height" {
    var ts = try testSurface(4, 4);
    ts.bind();
    defer ts.deinit();

    ts.surface.writeCell(1, 1, .{ .char = .{ .grapheme = "a", .width = 1 } });
    ts.surface.writeCell(1, 2, .{ .char = .{ .grapheme = "b", .width = 1 } });
    ts.surface.writeCell(0, 2, .{ .char = .{ .grapheme = "x", .width = 1 } });

    ts.surface.scroll(.{ .col = 1, .row = 1, .width = 2, .height = 2 }, 2);

    const unchanged = ts.surface.readCell(0, 2).?;
    const cleared_top = ts.surface.readCell(1, 1).?;
    const cleared_bottom = ts.surface.readCell(1, 2).?;

    try std.testing.expectEqualStrings("x", unchanged.char.grapheme);
    try std.testing.expectEqualStrings(" ", cleared_top.char.grapheme);
    try std.testing.expectEqualStrings(" ", cleared_bottom.char.grapheme);
}

test "Surface cursor APIs update screen cursor state" {
    var ts = try testSurface(4, 3);
    ts.bind();
    defer ts.deinit();

    ts.surface.showCursor(2, 1);
    try std.testing.expect(ts.screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 2), ts.screen.cursor.col);
    try std.testing.expectEqual(@as(u16, 1), ts.screen.cursor.row);

    ts.surface.setCursorShape(.beam);
    try std.testing.expectEqual(CursorShape.beam, ts.screen.cursor_shape);

    ts.surface.hideCursor();
    try std.testing.expect(!ts.screen.cursor_vis);
}

test "Surface.fillAll and clearAll affect the whole surface" {
    var ts = try testSurface(2, 2);
    ts.bind();
    defer ts.deinit();

    ts.surface.fillAll(.{
        .char = .{ .grapheme = "#", .width = 1 },
        .style = .{ .dim = true },
    });

    const filled = ts.surface.window.readCell(1, 1).?;
    try std.testing.expectEqualStrings("#", filled.char.grapheme);
    try std.testing.expect(filled.style.dim);

    ts.surface.clearAll();

    const cleared = ts.surface.window.readCell(1, 1).?;
    try std.testing.expectEqualStrings(" ", cleared.char.grapheme);
    try std.testing.expect(!cleared.style.dim);
}
