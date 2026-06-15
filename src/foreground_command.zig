const std = @import("std");

/// Opaque id returned when a foreground command is queued.
///
/// Apps can use this to ignore stale command results if future UI state changes
/// while the command is running.
pub const ForegroundCommandRequestId = struct {
    id: u64,
};

/// Result of a terminal foreground command.
///
/// Spawn/wait failures are distinct from child exit status so apps can show a
/// useful status message without treating every failure as a non-zero command.
pub const ForegroundCommandOutcome = union(enum) {
    exited: u8,
    signaled: u32,
    spawn_failed: []const u8,
    wait_failed: []const u8,
};

pub const ForegroundCommandResult = struct {
    request_id: ForegroundCommandRequestId,
    outcome: ForegroundCommandOutcome,
};

test "foreground command result can represent spawn failure" {
    const result = ForegroundCommandResult{
        .request_id = .{ .id = 1 },
        .outcome = .{ .spawn_failed = "FileNotFound" },
    };

    try std.testing.expectEqual(@as(u64, 1), result.request_id.id);
    try std.testing.expectEqualStrings("FileNotFound", result.outcome.spawn_failed);
}
