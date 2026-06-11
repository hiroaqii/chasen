/// Terminal color. Use `.default` for the terminal's default color,
/// `.gray` as a convenience alias for ANSI index 8, or specify an
/// explicit palette index or RGB value.
pub const Color = union(enum) {
    default,
    gray,
    index: u8,
    rgb: [3]u8,

    pub fn eql(self: Color, other: Color) bool {
        return switch (self) {
            .default => other == .default,
            .gray => switch (other) {
                .gray => true,
                .index => |i| i == 8,
                else => false,
            },
            .index => |i| switch (other) {
                .gray => i == 8,
                .index => |j| i == j,
                else => false,
            },
            .rgb => |a| switch (other) {
                .rgb => |b| a[0] == b[0] and a[1] == b[1] and a[2] == b[2],
                else => false,
            },
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
};

/// Text styling attributes for use with `Surface` and `Column` drawing APIs.
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

    pub fn eql(self: TextStyle, other: TextStyle) bool {
        return self.bold == other.bold and
            self.italic == other.italic and
            self.dim == other.dim and
            self.reverse == other.reverse and
            self.strikethrough == other.strikethrough and
            self.fg.eql(other.fg) and
            self.bg.eql(other.bg) and
            self.underline == other.underline and
            self.underline_color.eql(other.underline_color);
    }
};

test "Color.eql treats gray and index 8 as equivalent" {
    const gray: Color = .gray;
    try @import("std").testing.expect(gray.eql(.{ .index = 8 }));
    try @import("std").testing.expect((Color{ .index = 8 }).eql(.gray));
    try @import("std").testing.expect(!(Color{ .index = 7 }).eql(.gray));
}

test "Color.eql compares rgb values" {
    try @import("std").testing.expect((Color{ .rgb = .{ 255, 128, 0 } }).eql(.{ .rgb = .{ 255, 128, 0 } }));
    try @import("std").testing.expect(!(Color{ .rgb = .{ 255, 128, 0 } }).eql(.{ .rgb = .{ 255, 128, 1 } }));
}

test "TextStyle.eql compares all Chasen-owned fields" {
    const a: TextStyle = .{
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
    var b = a;
    try @import("std").testing.expect(a.eql(b));
    b.underline = .single;
    try @import("std").testing.expect(!a.eql(b));
}

test "TextStyle default is all false/default" {
    const text_style: TextStyle = .{};
    try @import("std").testing.expect(!text_style.bold);
    try @import("std").testing.expect(!text_style.italic);
    try @import("std").testing.expect(!text_style.dim);
    try @import("std").testing.expect(!text_style.reverse);
    try @import("std").testing.expect(!text_style.strikethrough);
    try @import("std").testing.expect(text_style.fg.eql(.default));
    try @import("std").testing.expect(text_style.bg.eql(.default));
    try @import("std").testing.expectEqual(Underline.off, text_style.underline);
    try @import("std").testing.expect(text_style.underline_color.eql(.default));
}
