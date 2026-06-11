const vaxis = @import("vaxis");
const cell_mod = @import("cell.zig");
const style = @import("style.zig");

pub fn colorToVaxis(color: style.Color) vaxis.Cell.Color {
    return switch (color) {
        .default => .default,
        .gray => .{ .index = 8 },
        .index => |i| .{ .index = i },
        .rgb => |c| .{ .rgb = c },
    };
}

pub fn colorFromVaxis(color: vaxis.Cell.Color) style.Color {
    return switch (color) {
        .default => .default,
        .index => |i| if (i == 8) .gray else .{ .index = i },
        .rgb => |c| .{ .rgb = c },
    };
}

pub fn underlineToVaxis(underline: style.Underline) vaxis.Cell.Style.Underline {
    return switch (underline) {
        .off => .off,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

pub fn underlineFromVaxis(underline: vaxis.Cell.Style.Underline) style.Underline {
    return switch (underline) {
        .off => .off,
        .single => .single,
        .double => .double,
        .curly => .curly,
        .dotted => .dotted,
        .dashed => .dashed,
    };
}

pub fn textStyleToVaxis(text_style: style.TextStyle) vaxis.Cell.Style {
    return .{
        .bold = text_style.bold,
        .italic = text_style.italic,
        .dim = text_style.dim,
        .reverse = text_style.reverse,
        .strikethrough = text_style.strikethrough,
        .fg = colorToVaxis(text_style.fg),
        .bg = colorToVaxis(text_style.bg),
        .ul = colorToVaxis(text_style.underline_color),
        .ul_style = underlineToVaxis(text_style.underline),
    };
}

pub fn textStyleFromVaxis(text_style: vaxis.Cell.Style) style.TextStyle {
    return .{
        .bold = text_style.bold,
        .italic = text_style.italic,
        .dim = text_style.dim,
        .reverse = text_style.reverse,
        .strikethrough = text_style.strikethrough,
        .fg = colorFromVaxis(text_style.fg),
        .bg = colorFromVaxis(text_style.bg),
        .underline_color = colorFromVaxis(text_style.ul),
        .underline = underlineFromVaxis(text_style.ul_style),
    };
}

pub fn cellToVaxis(cell: cell_mod.Cell) vaxis.Cell {
    return .{
        .char = .{
            .grapheme = cell.char.grapheme,
            .width = cell.char.width,
        },
        .style = textStyleToVaxis(cell.style),
    };
}

pub fn cellFromVaxis(cell: vaxis.Cell) cell_mod.Cell {
    return .{
        .char = .{
            .grapheme = cell.char.grapheme,
            .width = cell.char.width,
        },
        .style = textStyleFromVaxis(cell.style),
    };
}

pub fn cursorShapeToVaxis(shape: cell_mod.CursorShape) vaxis.Cell.CursorShape {
    return switch (shape) {
        .default => .default,
        .block => .block,
        .beam => .beam,
        .underline => .underline,
    };
}

test "color conversion normalizes gray to ANSI index 8" {
    try @import("std").testing.expect(colorToVaxis(.gray).eql(.{ .index = 8 }));
    try @import("std").testing.expectEqual(style.Color.gray, colorFromVaxis(.{ .index = 8 }));
}

test "style conversion preserves Chasen-owned style fields" {
    const original: style.TextStyle = .{
        .bold = true,
        .italic = true,
        .dim = true,
        .reverse = true,
        .strikethrough = true,
        .fg = .{ .rgb = .{ 1, 2, 3 } },
        .bg = .{ .index = 4 },
        .underline = .curly,
        .underline_color = .{ .index = 5 },
    };
    const roundtrip = textStyleFromVaxis(textStyleToVaxis(original));
    try @import("std").testing.expect(original.eql(roundtrip));
}
