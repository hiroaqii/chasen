const std = @import("std");
const vaxis = @import("vaxis");

/// A Unicode grapheme cluster location in a UTF-8 string.
pub const Grapheme = vaxis.unicode.Grapheme;

/// Iterator over Unicode grapheme clusters in a UTF-8 string.
pub const GraphemeIterator = vaxis.unicode.GraphemeIterator;

/// Create an iterator over Unicode grapheme clusters.
pub fn graphemeIterator(str: []const u8) GraphemeIterator {
    return vaxis.unicode.graphemeIterator(str);
}

/// Return terminal display width using libvaxis' Unicode width rules.
///
/// This is useful for component logic that needs width calculations without a
/// live `Surface`.
pub fn displayWidth(str: []const u8) u16 {
    return vaxis.gwidth.gwidth(str, .unicode);
}

/// Return the longest prefix that fits in `max_width` terminal cells.
///
/// The returned slice always points into `str` and never splits a Unicode
/// grapheme cluster. This helper intentionally does not add ellipsis or
/// padding; callers own those presentation choices.
pub fn clipToWidth(str: []const u8, max_width: u16) []const u8 {
    if (max_width == 0 or str.len == 0) return str[0..0];

    var used_width: u16 = 0;
    var end: usize = 0;
    var iter = graphemeIterator(str);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(str);
        const width = displayWidth(bytes);
        if (width > max_width - used_width) break;
        used_width += width;
        end = @intFromPtr(bytes.ptr) - @intFromPtr(str.ptr) + bytes.len;
    }
    return str[0..end];
}

test "displayWidth handles ascii and wide characters" {
    try std.testing.expectEqual(@as(u16, 3), displayWidth("abc"));
    try std.testing.expectEqual(@as(u16, 2), displayWidth("あ"));
}

test "displayWidth handles grapheme clusters" {
    try std.testing.expectEqual(@as(u16, 1), displayWidth("e\u{301}"));
    try std.testing.expectEqual(@as(u16, 2), displayWidth("👩‍🚀"));
    try std.testing.expectEqual(@as(u16, 2), displayWidth("🇯🇵"));
}

test "graphemeIterator yields cluster byte ranges" {
    var iter = graphemeIterator("aあe\u{301}");

    const first = iter.next().?;
    try std.testing.expectEqualStrings("a", first.bytes("aあe\u{301}"));

    const second = iter.next().?;
    try std.testing.expectEqualStrings("あ", second.bytes("aあe\u{301}"));

    const third = iter.next().?;
    try std.testing.expectEqualStrings("e\u{301}", third.bytes("aあe\u{301}"));

    try std.testing.expect(iter.next() == null);
}

test "clipToWidth does not split grapheme clusters" {
    try std.testing.expectEqualStrings("", clipToWidth("abc", 0));
    try std.testing.expectEqualStrings("abc", clipToWidth("abc", 3));
    try std.testing.expectEqualStrings("ab", clipToWidth("abc", 2));
    try std.testing.expectEqualStrings("Aあ", clipToWidth("AあB", 3));
    try std.testing.expectEqualStrings("A", clipToWidth("AあB", 2));
    try std.testing.expectEqualStrings("e\u{301}", clipToWidth("e\u{301}x", 1));
    try std.testing.expectEqualStrings("", clipToWidth("あ", 1));
}

test "clipToWidth keeps maxInt width within bounds" {
    const max_width = std.math.maxInt(u16);
    const text = try std.testing.allocator.alloc(u8, @as(usize, max_width) + 1);
    defer std.testing.allocator.free(text);
    @memset(text, 'a');

    const clipped = clipToWidth(text, max_width);
    try std.testing.expectEqual(@as(usize, max_width), clipped.len);
}

test {
    std.testing.refAllDecls(@This());
}
