const std = @import("std");
const vaxis = @import("vaxis");
const cell_mod = @import("cell.zig");
const style = @import("style.zig");
const terminal_image = @import("terminal_image.zig");
const vaxis_convert = @import("vaxis_convert.zig");
const TextStyle = style.TextStyle;

pub const Cell = cell_mod.Cell;
pub const CellChar = cell_mod.CellChar;

/// Terminal cursor shape.
pub const CursorShape = cell_mod.CursorShape;

pub const TerminalImageHandle = terminal_image.TerminalImageHandle;
pub const TerminalImageOptions = terminal_image.TerminalImageOptions;

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

/// A drawable surface.
///
/// The current terminal backend stores a vaxis window internally, but app and
/// component code should draw through `Surface` methods instead of reaching
/// into backend-specific handles.
pub const Surface = struct {
    backend: BackendStorage align(@alignOf(vaxis.Window)),
    arena: std.mem.Allocator,
    image_registry: ?*terminal_image.Registry = null,

    const BackendStorage = [@sizeOf(vaxis.Window)]u8;

    /// Construct a vaxis-backed `Surface`.
    ///
    /// This is an internal terminal-runtime/testing hook. App and component
    /// code should receive a `Surface` from Chasen and draw through its public
    /// methods rather than constructing one directly.
    pub fn initVaxis(win: vaxis.Window, arena: std.mem.Allocator, image_registry: ?*terminal_image.Registry) Surface {
        var surface: Surface = .{
            .backend = undefined,
            .arena = arena,
            .image_registry = image_registry,
        };
        surface.vaxisWindow().* = win;
        return surface;
    }

    /// Rebind the underlying vaxis screen for `chasen.testing.TestSurface`.
    ///
    /// This is not part of the stable app-facing drawing API.
    pub fn bindVaxisScreenForTesting(self: *Surface, screen: *vaxis.Screen) void {
        self.vaxisWindow().screen = screen;
    }

    fn vaxisWindow(self: *Surface) *vaxis.Window {
        return @ptrCast(&self.backend);
    }

    fn vaxisWindowConst(self: *const Surface) *const vaxis.Window {
        return @ptrCast(&self.backend);
    }

    /// Return the current drawable size in terminal cells.
    pub fn size(self: *const Surface) Size {
        const win = self.vaxisWindowConst();
        return .{
            .width = win.width,
            .height = win.height,
        };
    }

    /// Return the frame-scoped allocator.
    ///
    /// Memory allocated from this allocator is reset after the current frame.
    /// Do not store references to it in Model, Msg, or ComponentStateStore state.
    pub fn frameAllocator(self: *const Surface) std.mem.Allocator {
        return self.arena;
    }

    /// Write one cell at `col`, `row`.
    ///
    /// Out-of-bounds writes are ignored by libvaxis.
    pub fn writeCell(self: *Surface, col: u16, row: u16, cell: Cell) void {
        self.vaxisWindow().writeCell(col, row, vaxis_convert.cellToVaxis(cell));
    }

    /// Read one cell at `col`, `row`.
    ///
    /// The returned cell is a borrowed view of screen-buffer text. Use it for
    /// same-frame inspection or read-modify-write operations. Copy
    /// `cell.char.grapheme` before storing the result in app or component state.
    pub fn readCell(self: *const Surface, col: u16, row: u16) ?Cell {
        const cell = self.vaxisWindowConst().readCell(col, row) orelse return null;
        return vaxis_convert.cellFromVaxis(cell);
    }

    /// Print borrowed styled text at `col`, `row` without wrapping.
    ///
    /// This is the explicit borrowed-text escape hatch. The string is not
    /// copied, so the caller must guarantee that `str` stays valid until the
    /// current frame finishes rendering.
    ///
    /// Good inputs are string literals, model/state-owned text, and
    /// component-owned buffers that outlive the frame. Do not pass stack
    /// buffers, `std.fmt.bufPrint` results, or allocations that may be freed
    /// before render completion. For text created during `view`, prefer
    /// `copyTextAt` or `printAt`.
    pub fn borrowTextAt(self: *Surface, col: u16, row: u16, str: []const u8, ts: TextStyle) PrintResult {
        return .fromVaxis(self.vaxisWindow().printSegment(.{
            .text = str,
            .style = vaxis_convert.textStyleToVaxis(ts),
        }, .{
            .col_offset = col,
            .row_offset = row,
            .wrap = .none,
        }));
    }

    /// Copy `str` into the frame allocator and return the copied text.
    ///
    /// The returned slice remains valid until the current frame finishes
    /// rendering. This is useful when dynamic text must be passed through a
    /// borrowed API, such as a component view option.
    pub fn copyText(self: *Surface, str: []const u8) ![]const u8 {
        return self.arena.dupe(u8, str);
    }

    /// Copy `str` into the frame allocator, then print it with `borrowTextAt`.
    ///
    /// Use this for dynamic text that already exists as a slice but may not
    /// live until render completion. It is the safe default when a caller is
    /// unsure whether `borrowTextAt` is valid.
    pub fn copyTextAt(self: *Surface, col: u16, row: u16, str: []const u8, ts: TextStyle) !PrintResult {
        const copied = try self.copyText(str);
        return self.borrowTextAt(col, row, copied, ts);
    }

    /// Format text into the frame allocator, then print it with `borrowTextAt`.
    ///
    /// This is the safe default for formatted text created during `view`. It
    /// avoids borrowing a temporary stack buffer or short-lived formatting
    /// result.
    pub fn printAt(
        self: *Surface,
        col: u16,
        row: u16,
        ts: TextStyle,
        comptime fmt: []const u8,
        args: anytype,
    ) !PrintResult {
        const str = try std.fmt.allocPrint(self.arena, fmt, args);
        return self.borrowTextAt(col, row, str, ts);
    }

    /// Return the terminal display width of `str`.
    pub fn displayWidth(self: *const Surface, str: []const u8) u16 {
        return self.vaxisWindowConst().gwidth(str);
    }

    /// Fill `rect` with `cell`.
    pub fn fill(self: *Surface, rect: Rect, cell: Cell) void {
        self.windowForRect(rect).fill(vaxis_convert.cellToVaxis(cell));
    }

    /// Clear `rect` to the default terminal cell.
    pub fn clear(self: *Surface, rect: Rect) void {
        self.windowForRect(rect).clear();
    }

    /// Create a child surface clipped to `rect`.
    pub fn child(self: *Surface, rect: Rect) Surface {
        return .initVaxis(self.windowForRect(rect), self.arena, self.image_registry);
    }

    /// Draw a previously loaded terminal image into this surface.
    ///
    /// Loading/transmitting images is a runtime effect. `view` should only use
    /// handles already delivered to the application model.
    pub fn drawTerminalImage(self: *Surface, handle: TerminalImageHandle, opts: TerminalImageOptions) terminal_image.DrawError!void {
        const registry = self.image_registry orelse return error.TerminalImageRegistryUnavailable;
        return registry.draw(self.vaxisWindow().*, handle, opts);
    }

    /// Scroll `rect` upward by `rows`, inserting blank rows at the bottom.
    pub fn scroll(self: *Surface, rect: Rect, rows: u16) void {
        if (rows == 0 or rect.width == 0 or rect.height == 0) return;

        var child_window = self.windowForRect(rect);
        if (rows >= child_window.height) {
            child_window.clear();
            return;
        }

        var row: u16 = 0;
        while (row < child_window.height - rows) : (row += 1) {
            var col: u16 = 0;
            while (col < child_window.width) : (col += 1) {
                const cell = child_window.readCell(col, row + rows) orelse vaxis.Cell{};
                child_window.writeCell(col, row, cell);
            }
        }

        child_window.child(.{
            .x_off = 0,
            .y_off = @intCast(child_window.height - rows),
            .width = child_window.width,
            .height = rows,
        }).clear();
    }

    fn windowForRect(self: *Surface, rect: Rect) vaxis.Window {
        return self.vaxisWindow().child(.{
            .x_off = @intCast(rect.col),
            .y_off = @intCast(rect.row),
            .width = rect.width,
            .height = rect.height,
        });
    }

    /// Show the terminal cursor at `col`, `row`.
    pub fn showCursor(self: *Surface, col: u16, row: u16) void {
        self.vaxisWindow().showCursor(col, row);
    }

    /// Hide the terminal cursor.
    pub fn hideCursor(self: *Surface) void {
        self.vaxisWindow().hideCursor();
    }

    /// Set the terminal cursor shape.
    pub fn setCursorShape(self: *Surface, shape: CursorShape) void {
        self.vaxisWindow().setCursorShape(vaxis_convert.cursorShapeToVaxis(shape));
    }

    /// Fill the entire surface with `cell`.
    pub fn fillAll(self: *Surface, cell: Cell) void {
        self.vaxisWindow().fill(vaxis_convert.cellToVaxis(cell));
    }

    /// Clear the entire surface to the default terminal cell.
    pub fn clearAll(self: *Surface) void {
        self.vaxisWindow().clear();
    }

    /// Create a vertical column layout within this surface.
    pub fn column(self: *Surface, opts: ColumnOptions) Column {
        return .initVaxis(self.vaxisWindow().*, self.arena, opts);
    }
};

/// A vertical layout that places text elements top-to-bottom.
pub const Column = struct {
    backend: BackendStorage align(@alignOf(vaxis.Window)),
    arena: std.mem.Allocator,
    row: u16,
    gap: u16,

    const BackendStorage = [@sizeOf(vaxis.Window)]u8;

    fn initVaxis(win: vaxis.Window, arena: std.mem.Allocator, opts: ColumnOptions) Column {
        var column: Column = .{
            .backend = undefined,
            .arena = arena,
            .row = 0,
            .gap = opts.gap,
        };
        column.vaxisWindow().* = win;
        return column;
    }

    fn vaxisWindow(self: *Column) *vaxis.Window {
        return @ptrCast(&self.backend);
    }

    /// Print a borrowed styled text segment at the current row, then advance
    /// the cursor by `gap` rows.
    ///
    /// This has the same lifetime requirement as `Surface.borrowTextAt`: the
    /// text is not copied, and the caller must keep it alive until the current
    /// frame finishes rendering. Use this for string literals and app-owned or
    /// component-owned text. Use `copyText` or `print` for text created during
    /// `view`.
    pub fn borrowText(self: *Column, str: []const u8, ts: TextStyle) void {
        const result = self.vaxisWindow().printSegment(.{
            .text = str,
            .style = vaxis_convert.textStyleToVaxis(ts),
        }, .{ .row_offset = self.row });
        self.row = result.row + self.gap;
    }

    /// Copy text into the frame allocator, print it, then advance by `gap`.
    ///
    /// This is the safe column API for dynamic slices whose original storage
    /// may not live until render completion.
    pub fn copyText(self: *Column, str: []const u8, ts: TextStyle) !void {
        const copied = try self.arena.dupe(u8, str);
        self.borrowText(copied, ts);
    }

    /// Format text into the frame allocator, print it with the default style,
    /// then advance by `gap`.
    ///
    /// This is the safe column API for formatted text created during `view`.
    /// Returns an error if formatting allocation fails.
    pub fn print(self: *Column, comptime fmt: []const u8, args: anytype) !void {
        const str = try std.fmt.allocPrint(self.arena, fmt, args);
        self.borrowText(str, .{});
    }
};

const TestSurface = struct {
    screen: vaxis.Screen,
    arena: std.heap.ArenaAllocator,
    surface: Surface,

    fn deinit(self: *@This()) void {
        self.arena.deinit();
        self.screen.deinit(std.testing.allocator);
    }

    /// Window stores a pointer to Screen and Surface stores an allocator backed
    /// by the arena, so bind after TestSurface has moved into the caller's
    /// stack slot.
    fn bind(self: *@This()) void {
        self.surface.bindVaxisScreenForTesting(&self.screen);
        self.surface.arena = self.arena.allocator();
    }
};

fn testSurface(width: u16, height: u16) !TestSurface {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .cols = width,
        .rows = height,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    screen.width_method = .unicode;
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
        .arena = .init(std.testing.allocator),
        .surface = .initVaxis(window, undefined, null),
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

    const cell = ts.surface.readCell(1, 0).?;
    try std.testing.expectEqualStrings("x", cell.char.grapheme);
    try std.testing.expect(cell.style.bold);
}

test "Surface.writeCell and readCell roundtrip Chasen-owned cell fields" {
    var ts = try testSurface(3, 2);
    ts.bind();
    defer ts.deinit();

    const expected: Cell = .{
        .char = .{ .grapheme = "x", .width = 1 },
        .style = .{
            .bold = true,
            .fg = .gray,
            .underline = .curly,
            .underline_color = .{ .index = 5 },
        },
    };
    ts.surface.writeCell(1, 0, expected);

    const actual = ts.surface.readCell(1, 0).?;
    try std.testing.expect(actual.eql(expected));
}

test "Surface.writeCell and readCell roundtrip wide text cell" {
    var ts = try testSurface(3, 2);
    ts.bind();
    defer ts.deinit();

    ts.surface.writeCell(1, 0, .{ .char = .{ .grapheme = "あ", .width = 2 } });

    const actual = ts.surface.readCell(1, 0).?;
    try std.testing.expectEqualStrings("あ", actual.char.grapheme);
    try std.testing.expectEqual(@as(u8, 2), actual.char.width);
}

test "Surface.writeCell and readCell preserve unknown text width" {
    var ts = try testSurface(3, 2);
    ts.bind();
    defer ts.deinit();

    ts.surface.writeCell(1, 0, .{ .char = .{ .grapheme = "x", .width = 0 } });

    const actual = ts.surface.readCell(1, 0).?;
    try std.testing.expectEqualStrings("x", actual.char.grapheme);
    try std.testing.expectEqual(@as(u8, 0), actual.char.width);
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

test "Surface.displayWidth uses terminal width rules" {
    var ts = try testSurface(10, 2);
    ts.bind();
    defer ts.deinit();

    try std.testing.expectEqual(@as(u16, 3), ts.surface.displayWidth("abc"));
}

test "Surface.displayWidth handles wide characters" {
    var ts = try testSurface(10, 2);
    ts.bind();
    defer ts.deinit();

    try std.testing.expectEqual(@as(u16, 2), ts.surface.displayWidth("あ"));
}

test "Surface.displayWidth matches chasen text unicode width" {
    var ts = try testSurface(10, 2);
    ts.bind();
    defer ts.deinit();

    const text = @import("text.zig");
    try std.testing.expectEqual(text.displayWidth("👩‍🚀"), ts.surface.displayWidth("👩‍🚀"));
    try std.testing.expectEqual(text.displayWidth("🇯🇵"), ts.surface.displayWidth("🇯🇵"));
}

test "Surface.borrowTextAt prints unwrapped styled text at coordinates" {
    var ts = try testSurface(4, 2);
    ts.bind();
    defer ts.deinit();

    const result = ts.surface.borrowTextAt(1, 0, "abc", .{ .fg = .{ .index = 2 } });

    try std.testing.expectEqual(@as(u16, 4), result.col);
    try std.testing.expectEqual(@as(u16, 0), result.row);
    try std.testing.expect(!result.overflow);

    const a = ts.surface.readCell(1, 0).?;
    const c = ts.surface.readCell(3, 0).?;
    try std.testing.expectEqualStrings("a", a.char.grapheme);
    try std.testing.expectEqualStrings("c", c.char.grapheme);
    try std.testing.expect(a.style.fg.eql(.{ .index = 2 }));
}

test "Surface.copyText copies text into the frame allocator" {
    var ts = try testSurface(4, 2);
    ts.bind();
    defer ts.deinit();

    var buf: [4]u8 = .{ 'a', 'b', 'c', 'd' };
    const copied = try ts.surface.copyText(buf[0..]);
    buf[0] = 'z';

    try std.testing.expectEqualStrings("abcd", copied);
}

test "Surface.copyTextAt copies and prints dynamic text" {
    var ts = try testSurface(8, 2);
    ts.bind();
    defer ts.deinit();

    var buf: [4]u8 = .{ 't', 'e', 's', 't' };
    const result = try ts.surface.copyTextAt(1, 0, buf[0..], .{ .bold = true });
    buf[0] = 'x';

    try std.testing.expectEqual(@as(u16, 5), result.col);
    try std.testing.expectEqual(@as(u16, 0), result.row);
    try std.testing.expect(!result.overflow);

    const first = ts.surface.readCell(1, 0).?;
    try std.testing.expectEqualStrings("t", first.char.grapheme);
    try std.testing.expect(first.style.bold);
}

test "Surface.printAt formats text into the frame allocator" {
    var ts = try testSurface(12, 2);
    ts.bind();
    defer ts.deinit();

    const result = try ts.surface.printAt(0, 0, .{ .fg = .{ .index = 3 } }, "line {d}", .{3});

    try std.testing.expectEqual(@as(u16, 6), result.col);
    try std.testing.expectEqual(@as(u16, 0), result.row);
    try std.testing.expect(!result.overflow);

    const l = ts.surface.readCell(0, 0).?;
    const three = ts.surface.readCell(5, 0).?;
    try std.testing.expectEqualStrings("l", l.char.grapheme);
    try std.testing.expectEqualStrings("3", three.char.grapheme);
    try std.testing.expect(l.style.fg.eql(.{ .index = 3 }));
}

test "Surface.fill and clear affect a rect" {
    var ts = try testSurface(3, 3);
    ts.bind();
    defer ts.deinit();

    ts.surface.fill(.{ .col = 1, .row = 1, .width = 2, .height = 2 }, .{
        .char = .{ .grapheme = "#", .width = 1 },
        .style = .{ .dim = true },
    });

    const outside = ts.surface.readCell(0, 0).?;
    const inside = ts.surface.readCell(2, 2).?;
    try std.testing.expectEqualStrings(" ", outside.char.grapheme);
    try std.testing.expectEqualStrings("#", inside.char.grapheme);
    try std.testing.expect(inside.style.dim);

    ts.surface.clear(.{ .col = 1, .row = 1, .width = 2, .height = 2 });

    const cleared = ts.surface.readCell(2, 2).?;
    try std.testing.expectEqualStrings(" ", cleared.char.grapheme);
    try std.testing.expect(!cleared.style.dim);

    const cleared_raw = ts.screen.readCell(2, 2).?;
    try std.testing.expect(cleared_raw.default);
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

    const outside = ts.surface.readCell(0, 1).?;
    const a = ts.surface.readCell(1, 1).?;
    const b = ts.surface.readCell(2, 1).?;
    const clipped = ts.surface.readCell(3, 1).?;

    try std.testing.expectEqualStrings(" ", outside.char.grapheme);
    try std.testing.expectEqualStrings("a", a.char.grapheme);
    try std.testing.expectEqualStrings("b", b.char.grapheme);
    try std.testing.expectEqualStrings(" ", clipped.char.grapheme);
}

test "Surface.child preserves terminal image registry reference" {
    var ts = try testSurface(4, 3);
    ts.bind();
    defer ts.deinit();

    var registry: terminal_image.Registry = .{};
    defer registry.deinit(std.testing.allocator);
    ts.surface.image_registry = &registry;

    const child = ts.surface.child(.{ .col = 1, .row = 1, .width = 2, .height = 1 });

    try std.testing.expect(child.image_registry != null);
    try std.testing.expectEqual(&registry, child.image_registry.?);
}

test "Surface.drawTerminalImage reports missing registry" {
    var ts = try testSurface(4, 3);
    ts.bind();
    defer ts.deinit();

    try std.testing.expectError(
        error.TerminalImageRegistryUnavailable,
        ts.surface.drawTerminalImage(.{ .id = 1, .generation = 1 }, .{}),
    );
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

    const outside = ts.surface.readCell(2, 2).?;
    const inside = ts.surface.readCell(3, 2).?;

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

test "Surface.scroll preserves backend cell metadata" {
    var ts = try testSurface(4, 4);
    ts.bind();
    defer ts.deinit();

    ts.screen.writeCell(1, 2, .{
        .char = .{ .grapheme = "i", .width = 1 },
        .image = .{ .img_id = 42, .options = .{} },
    });

    ts.surface.scroll(.{ .col = 1, .row = 1, .width = 2, .height = 2 }, 1);

    const moved = ts.screen.readCell(1, 1).?;
    try std.testing.expect(moved.image != null);
    try std.testing.expectEqual(@as(u32, 42), moved.image.?.img_id);
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

    const cleared_raw = ts.screen.readCell(1, 1).?;
    try std.testing.expect(cleared_raw.default);
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
    try std.testing.expectEqual(vaxis.Cell.CursorShape.beam, ts.screen.cursor_shape);

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

    const filled = ts.surface.readCell(1, 1).?;
    try std.testing.expectEqualStrings("#", filled.char.grapheme);
    try std.testing.expect(filled.style.dim);

    ts.surface.clearAll();

    const cleared = ts.surface.readCell(1, 1).?;
    try std.testing.expectEqualStrings(" ", cleared.char.grapheme);
    try std.testing.expect(!cleared.style.dim);

    const cleared_raw = ts.screen.readCell(1, 1).?;
    try std.testing.expect(cleared_raw.default);
}
