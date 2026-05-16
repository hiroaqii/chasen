const vaxis = @import("vaxis");

/// Terminal color. Use `.default` for the terminal's default color,
/// `.gray` as a convenience alias for ANSI index 8, or specify an
/// explicit palette index or RGB value.
pub const Color = union(enum) {
    default,
    gray,
    index: u8,
    rgb: [3]u8,

    /// Convert to the underlying vaxis color representation.
    pub fn toVaxis(self: Color) vaxis.Cell.Color {
        return switch (self) {
            .default => .default,
            .gray => .{ .index = 8 },
            .index => |i| .{ .index = i },
            .rgb => |c| .{ .rgb = c },
        };
    }
};

/// Terminal underline style.
pub const Underline = enum {
    off,
    single,
    double,
    curly,
    dotted,
    dashed,

    /// Convert to the underlying vaxis underline representation.
    pub fn toVaxis(self: Underline) vaxis.Cell.Style.Underline {
        return switch (self) {
            .off => .off,
            .single => .single,
            .double => .double,
            .curly => .curly,
            .dotted => .dotted,
            .dashed => .dashed,
        };
    }
};

/// Text styling attributes for use with `Column.text()`.
/// All fields default to off/default, so `.{ .bold = true }` is sufficient
/// to create a bold style with default colors.
pub const TextStyle = struct {
    bold: bool = false,
    italic: bool = false,
    dim: bool = false,
    reverse: bool = false,
    strikethrough: bool = false,
    fg: Color = .default,
    bg: Color = .default,
    underline: Underline = .off,
    underline_color: Color = .default,

    /// Convert to the underlying vaxis style representation.
    pub fn toVaxis(self: TextStyle) vaxis.Cell.Style {
        return .{
            .bold = self.bold,
            .italic = self.italic,
            .dim = self.dim,
            .reverse = self.reverse,
            .strikethrough = self.strikethrough,
            .fg = self.fg.toVaxis(),
            .bg = self.bg.toVaxis(),
            .ul = self.underline_color.toVaxis(),
            .ul_style = self.underline.toVaxis(),
        };
    }
};

test "Color.toVaxis default" {
    const c: Color = .default;
    const vc = c.toVaxis();
    try @import("std").testing.expect(vc.eql(.default));
}

test "Color.toVaxis gray maps to index 8" {
    const c: Color = .gray;
    const vc = c.toVaxis();
    try @import("std").testing.expect(vc.eql(.{ .index = 8 }));
}

test "Color.toVaxis index" {
    const c: Color = .{ .index = 42 };
    const vc = c.toVaxis();
    try @import("std").testing.expect(vc.eql(.{ .index = 42 }));
}

test "Color.toVaxis rgb" {
    const c: Color = .{ .rgb = .{ 255, 128, 0 } };
    const vc = c.toVaxis();
    try @import("std").testing.expect(vc.eql(.{ .rgb = .{ 255, 128, 0 } }));
}

test "TextStyle.toVaxis preserves all fields" {
    const style: TextStyle = .{
        .bold = true,
        .italic = true,
        .dim = true,
        .reverse = true,
        .strikethrough = true,
        .fg = .{ .rgb = .{ 255, 0, 0 } },
        .bg = .{ .index = 4 },
        .underline = .curly,
        .underline_color = .{ .index = 5 },
    };
    const vs = style.toVaxis();
    try @import("std").testing.expect(vs.bold);
    try @import("std").testing.expect(vs.italic);
    try @import("std").testing.expect(vs.dim);
    try @import("std").testing.expect(vs.reverse);
    try @import("std").testing.expect(vs.strikethrough);
    try @import("std").testing.expect(vs.fg.eql(.{ .rgb = .{ 255, 0, 0 } }));
    try @import("std").testing.expect(vs.bg.eql(.{ .index = 4 }));
    try @import("std").testing.expect(vs.ul.eql(.{ .index = 5 }));
    try @import("std").testing.expectEqual(vaxis.Cell.Style.Underline.curly, vs.ul_style);
}

test "TextStyle default is all false/default" {
    const style: TextStyle = .{};
    const vs = style.toVaxis();
    try @import("std").testing.expect(!vs.bold);
    try @import("std").testing.expect(!vs.italic);
    try @import("std").testing.expect(!vs.dim);
    try @import("std").testing.expect(!vs.reverse);
    try @import("std").testing.expect(!vs.strikethrough);
    try @import("std").testing.expect(vs.fg.eql(.default));
    try @import("std").testing.expect(vs.bg.eql(.default));
    try @import("std").testing.expect(vs.ul.eql(.default));
    try @import("std").testing.expectEqual(vaxis.Cell.Style.Underline.off, vs.ul_style);
}
