const std = @import("std");

const style = @import("style.zig");
const surface_mod = @import("surface.zig");
const text = @import("text.zig");

const Surface = surface_mod.Surface;
const TextStyle = style.TextStyle;

/// A key/action pair such as `Enter: open` or `Esc/q: quit`.
///
/// Slices are borrowed. They must remain valid until `draw` or `width`
/// returns.
pub const Item = struct {
    keys: []const u8,
    action: []const u8,
};

/// Behavior when the next whole item does not fit on the current line.
pub const Overflow = enum {
    /// Draw ellipsis and stop. This is the default for single-line hints.
    ellipsis,

    /// Move the next item to the next line, up to `DrawOptions.max_lines`.
    wrap,
};

/// Presentation options for `draw`.
///
/// Hints are rendered as item-boundary units:
///
///   keys + delimiter + action + separator + keys + delimiter + action ...
///
/// Individual styles default to `style` when left null. `max_lines` controls
/// the number of rows available to the helper; it is also clipped by the
/// surface height.
pub const DrawOptions = struct {
    /// Fallback style for every segment.
    style: TextStyle = .{},

    /// Optional style for the key text.
    key_style: ?TextStyle = null,

    /// Optional style for `delimiter`.
    delimiter_style: ?TextStyle = null,

    /// Optional style for the action text.
    action_style: ?TextStyle = null,

    /// Optional style for `separator` and `ellipsis`.
    separator_style: ?TextStyle = null,

    /// Text between rendered items.
    separator: []const u8 = "  ",

    /// Text between key and action.
    delimiter: []const u8 = ": ",

    /// Text drawn when `.ellipsis` overflow is reached.
    ellipsis: []const u8 = "...",

    /// Maximum number of lines to use.
    max_lines: u16 = 1,

    /// Overflow behavior after an item does not fit.
    overflow: Overflow = .ellipsis,
};

/// Summary of the work performed by `draw`.
pub const DrawResult = struct {
    /// Number of lines touched by the helper.
    lines_used: u16 = 0,

    /// Number of complete items drawn.
    items_drawn: usize = 0,

    /// True when at least one item was omitted or clipped by available space.
    overflow: bool = false,
};

/// Construct an `Item` without repeating field names at call sites.
pub fn item(keys: []const u8, action: []const u8) Item {
    return .{ .keys = keys, .action = action };
}

/// Return the terminal-cell width needed to draw all items on one line.
pub fn width(items: []const Item, opts: DrawOptions) u16 {
    var used: u16 = 0;
    for (items, 0..) |footer_item, index| {
        if (index > 0) used = saturatingAddWidth(used, text.displayWidth(opts.separator));
        used = saturatingAddWidth(used, itemWidth(footer_item, opts));
    }
    return used;
}

/// Draw key/action hints at `(x, y)`.
///
/// The helper preserves item boundaries when deciding whether to wrap or
/// ellipsize. If an individual item is wider than the remaining line, only
/// that item may be clipped by `text.clipToWidth`; Unicode grapheme clusters
/// are not split.
pub fn draw(surface: *Surface, x: u16, y: u16, items: []const Item, opts: DrawOptions) DrawResult {
    const size = surface.size();
    if (items.len == 0 or opts.max_lines == 0 or x >= size.width or y >= size.height) return .{};

    const line_limit = @min(opts.max_lines, size.height - y);
    if (line_limit == 0) return .{};

    const line_width = size.width - x;
    var cursor = Cursor{ .x = x, .y = y };
    var result = DrawResult{ .lines_used = 1 };
    var drew_on_line = false;

    for (items) |footer_item| {
        const separator_width = if (drew_on_line) text.displayWidth(opts.separator) else 0;
        const needed_width = saturatingAddWidth(separator_width, itemWidth(footer_item, opts));
        var remaining = remainingWidth(size.width, cursor.x);

        if (needed_width > remaining) {
            if (opts.overflow == .wrap and cursor.y - y + 1 < line_limit and drew_on_line) {
                cursor = .{ .x = x, .y = cursor.y + 1 };
                result.lines_used += 1;
                drew_on_line = false;
                remaining = line_width;
            } else {
                result.overflow = true;
                drawEllipsis(surface, &cursor, size.width, drew_on_line, opts);
                return result;
            }
        }

        if (drew_on_line) {
            drawSegment(surface, &cursor, size.width, opts.separator, opts.separator_style orelse opts.style);
        }

        const before_item_x = cursor.x;
        drawKeyHintItem(surface, &cursor, size.width, footer_item, opts);
        if (cursor.x == before_item_x and itemWidth(footer_item, opts) > remainingWidth(size.width, cursor.x)) {
            result.overflow = true;
            return result;
        }
        result.items_drawn += 1;
        drew_on_line = true;
    }

    return result;
}

const Cursor = struct {
    x: u16,
    y: u16,
};

fn drawKeyHintItem(surface: *Surface, cursor: *Cursor, max_x: u16, footer_item: Item, opts: DrawOptions) void {
    drawSegment(surface, cursor, max_x, footer_item.keys, opts.key_style orelse opts.style);
    drawSegment(surface, cursor, max_x, opts.delimiter, opts.delimiter_style orelse opts.style);
    drawSegment(surface, cursor, max_x, footer_item.action, opts.action_style orelse opts.style);
}

fn drawEllipsis(surface: *Surface, cursor: *Cursor, max_x: u16, needs_separator: bool, opts: DrawOptions) void {
    if (remainingWidth(max_x, cursor.x) == 0) return;

    // Keep ellipsis visually attached to previous items, but avoid drawing a
    // leading separator when the first item itself cannot fit.
    if (needs_separator and text.displayWidth(opts.separator) + text.displayWidth(opts.ellipsis) <= remainingWidth(max_x, cursor.x)) {
        drawSegment(surface, cursor, max_x, opts.separator, opts.separator_style orelse opts.style);
    }
    drawSegment(surface, cursor, max_x, opts.ellipsis, opts.separator_style orelse opts.style);
}

fn drawSegment(surface: *Surface, cursor: *Cursor, max_x: u16, str: []const u8, ts: TextStyle) void {
    const remaining = remainingWidth(max_x, cursor.x);
    if (remaining == 0 or str.len == 0) return;

    const clipped = text.clipToWidth(str, remaining);
    if (clipped.len == 0) return;

    _ = surface.borrowTextAt(cursor.x, cursor.y, clipped, ts);
    cursor.x += text.displayWidth(clipped);
}

fn itemWidth(footer_item: Item, opts: DrawOptions) u16 {
    return saturatingAddWidth(
        saturatingAddWidth(text.displayWidth(footer_item.keys), text.displayWidth(opts.delimiter)),
        text.displayWidth(footer_item.action),
    );
}

fn remainingWidth(max_x: u16, x: u16) u16 {
    if (x >= max_x) return 0;
    return max_x - x;
}

fn saturatingAddWidth(a: u16, b: u16) u16 {
    return std.math.add(u16, a, b) catch std.math.maxInt(u16);
}

test "key hint width sums item widths and separators" {
    const items = [_]Item{
        item("q", "quit"),
        item("Enter", "open"),
    };

    try std.testing.expectEqual(@as(u16, 20), width(&items, .{}));
}

test "key hint draw writes styled key action items" {
    var ts: @import("testing.zig").TestSurface = undefined;
    try ts.init(24, 2);
    defer ts.deinit();

    const result = draw(&ts.surface, 0, 0, &.{
        item("q", "quit"),
        item("Enter", "open"),
    }, .{
        .style = .{ .dim = true },
        .key_style = .{ .bold = true },
    });

    try std.testing.expectEqual(@as(u16, 1), result.lines_used);
    try std.testing.expectEqual(@as(usize, 2), result.items_drawn);
    try std.testing.expect(!result.overflow);

    const q = ts.surface.readCell(0, 0).?;
    const quit = ts.surface.readCell(3, 0).?;
    try std.testing.expectEqualStrings("q", q.char.grapheme);
    try std.testing.expect(q.style.bold);
    try std.testing.expectEqualStrings("q", quit.char.grapheme);
    try std.testing.expect(quit.style.dim);
}

test "key hint draw ellipsizes at item boundary" {
    var ts: @import("testing.zig").TestSurface = undefined;
    try ts.init(22, 1);
    defer ts.deinit();

    const result = draw(&ts.surface, 0, 0, &.{
        item("Up/Down/j/k", "move"),
        item("Enter", "detail"),
        item("q", "quit"),
    }, .{});

    try std.testing.expectEqual(@as(u16, 1), result.lines_used);
    try std.testing.expectEqual(@as(usize, 1), result.items_drawn);
    try std.testing.expect(result.overflow);
    try std.testing.expectEqualStrings(".", ts.surface.readCell(19, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(".", ts.surface.readCell(20, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(".", ts.surface.readCell(21, 0).?.char.grapheme);
}

test "key hint draw does not prefix ellipsis with separator before first item" {
    var ts: @import("testing.zig").TestSurface = undefined;
    try ts.init(12, 1);
    defer ts.deinit();

    const result = draw(&ts.surface, 5, 0, &.{
        item("LongKey", "long action"),
    }, .{});

    try std.testing.expectEqual(@as(u16, 1), result.lines_used);
    try std.testing.expectEqual(@as(usize, 0), result.items_drawn);
    try std.testing.expect(result.overflow);
    try std.testing.expectEqualStrings(".", ts.surface.readCell(5, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(".", ts.surface.readCell(6, 0).?.char.grapheme);
    try std.testing.expectEqualStrings(".", ts.surface.readCell(7, 0).?.char.grapheme);
}

test "key hint draw wraps at item boundary" {
    var ts: @import("testing.zig").TestSurface = undefined;
    try ts.init(22, 2);
    defer ts.deinit();

    const result = draw(&ts.surface, 0, 0, &.{
        item("Up/Down", "move"),
        item("Enter", "detail"),
        item("q", "quit"),
    }, .{ .max_lines = 2, .overflow = .wrap });

    try std.testing.expectEqual(@as(u16, 2), result.lines_used);
    try std.testing.expectEqual(@as(usize, 3), result.items_drawn);
    try std.testing.expect(!result.overflow);
    try std.testing.expectEqualStrings("E", ts.surface.readCell(0, 1).?.char.grapheme);
}

test {
    std.testing.refAllDecls(@This());
}
