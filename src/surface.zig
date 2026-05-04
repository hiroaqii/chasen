const std = @import("std");
const vaxis = @import("vaxis");
const style = @import("style.zig");
const TextStyle = style.TextStyle;

/// A terminal cell in the underlying screen buffer.
pub const Cell = vaxis.Cell;

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

    /// Fill `rect` with `cell`.
    pub fn fill(self: *Surface, rect: Rect, cell: Cell) void {
        self.window.child(.{
            .x_off = @intCast(rect.col),
            .y_off = @intCast(rect.row),
            .width = rect.width,
            .height = rect.height,
        }).fill(cell);
    }

    /// Clear `rect` to the default terminal cell.
    pub fn clear(self: *Surface, rect: Rect) void {
        self.fill(rect, .{ .default = true });
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
