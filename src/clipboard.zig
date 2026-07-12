const std = @import("std");

/// Opaque id returned when a terminal clipboard copy is queued.
///
/// Apps can correlate the eventual best-effort completion with page or
/// operation-surface metadata captured at request time. The runtime owns only
/// the physical OSC 52 write; semantic result presentation remains app-owned.
pub const ClipboardCopyRequestId = struct {
    id: u64,
};

pub const ClipboardCopyOutcome = union(enum) {
    /// The runtime emitted the OSC 52 sequence to the tty.
    ///
    /// OSC 52 write has no ACK, so this does not prove the terminal accepted
    /// the clipboard payload. If multiple clipboard copies are emitted in one
    /// drain, terminals normally keep the last one.
    sent,
    /// The current runtime cannot perform terminal clipboard writes.
    unsupported_runtime,
    /// The local tty write failed before the OSC 52 sequence was emitted.
    write_failed: []const u8,
};

pub const ClipboardCopyResult = struct {
    request_id: ClipboardCopyRequestId,
    outcome: ClipboardCopyOutcome,
};

test "clipboard copy result preserves request identity" {
    const result: ClipboardCopyResult = .{
        .request_id = .{ .id = 7 },
        .outcome = .sent,
    };

    try std.testing.expectEqual(@as(u64, 7), result.request_id.id);
    try std.testing.expect(result.outcome == .sent);
}
