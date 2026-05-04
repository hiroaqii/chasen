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

test {
    std.testing.refAllDecls(@This());
}
