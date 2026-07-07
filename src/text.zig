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

/// Result of clipping text with an optional marker such as `…`.
///
/// `prefix` and `marker` are borrowed slices. Draw `prefix` first and then
/// `marker` when `marker.len > 0`.
pub const MarkedClip = struct {
    prefix: []const u8,
    marker: []const u8 = "",
    clipped: bool = false,
};

/// Return a clipped prefix and append `marker` when text does not fit.
///
/// The helper is allocation-free and never splits a Unicode grapheme cluster.
/// If `marker` itself does not fit, it falls back to plain clipping.
pub fn clipToWidthWithMarker(str: []const u8, max_width: u16, marker: []const u8) MarkedClip {
    const clipped = clipToWidth(str, max_width);
    if (clipped.len == str.len) return .{ .prefix = clipped };

    const marker_width = displayWidth(marker);
    if (marker.len == 0 or marker_width == 0 or marker_width > max_width) {
        return .{ .prefix = clipped, .clipped = true };
    }

    return .{
        .prefix = clipToWidth(str, max_width - marker_width),
        .marker = marker,
        .clipped = true,
    };
}

/// Drop leading text until at least `width` terminal cells have been skipped.
///
/// The returned slice always points into `str` and starts on a Unicode
/// grapheme boundary. If `width` lands in the middle of a wide grapheme, that
/// whole grapheme is skipped and the result snaps to the next boundary.
pub fn dropToWidth(str: []const u8, width: u16) []const u8 {
    if (width == 0 or str.len == 0) return str;

    var skipped_width: usize = 0;
    var start: usize = str.len;
    var iter = graphemeIterator(str);
    while (iter.next()) |grapheme| {
        const bytes = grapheme.bytes(str);
        skipped_width += displayWidth(bytes);
        start = @intFromPtr(bytes.ptr) - @intFromPtr(str.ptr) + bytes.len;
        if (skipped_width >= width) return str[start..];
    }
    return str[str.len..];
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

test "clipToWidthWithMarker appends marker when clipped" {
    const clipped = clipToWidthWithMarker("abcdef", 4, "…");
    try std.testing.expect(clipped.clipped);
    try std.testing.expectEqualStrings("abc", clipped.prefix);
    try std.testing.expectEqualStrings("…", clipped.marker);
}

test "clipToWidthWithMarker does not append marker when text fits" {
    const clipped = clipToWidthWithMarker("abc", 4, "…");
    try std.testing.expect(!clipped.clipped);
    try std.testing.expectEqualStrings("abc", clipped.prefix);
    try std.testing.expectEqualStrings("", clipped.marker);
}

test "clipToWidthWithMarker falls back when marker cannot fit" {
    const clipped = clipToWidthWithMarker("abcdef", 1, "xx");
    try std.testing.expect(clipped.clipped);
    try std.testing.expectEqualStrings("a", clipped.prefix);
    try std.testing.expectEqualStrings("", clipped.marker);
}

test "clipToWidthWithMarker preserves grapheme boundaries" {
    const clipped = clipToWidthWithMarker("AあB", 3, "…");
    try std.testing.expect(clipped.clipped);
    try std.testing.expectEqualStrings("A", clipped.prefix);
    try std.testing.expectEqualStrings("…", clipped.marker);
}

test "dropToWidth does not split grapheme clusters" {
    try std.testing.expectEqualStrings("AあB", dropToWidth("AあB", 0));
    try std.testing.expectEqualStrings("あB", dropToWidth("AあB", 1));
    try std.testing.expectEqualStrings("B", dropToWidth("AあB", 2));
    try std.testing.expectEqualStrings("B", dropToWidth("AあB", 3));
    try std.testing.expectEqualStrings("", dropToWidth("AあB", 4));
    try std.testing.expectEqualStrings("x", dropToWidth("e\u{301}x", 1));
}

test "dropToWidth keeps maxInt width within bounds" {
    const ascii_width = @as(usize, std.math.maxInt(u16)) - 1;
    const text = try std.testing.allocator.alloc(u8, ascii_width + "あ".len);
    defer std.testing.allocator.free(text);

    @memset(text[0..ascii_width], 'a');
    @memcpy(text[ascii_width..], "あ");

    const dropped = dropToWidth(text, std.math.maxInt(u16));
    try std.testing.expectEqualStrings("", dropped);
}

test {
    std.testing.refAllDecls(@This());
}
