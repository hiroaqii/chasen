const std = @import("std");

/// Working directory requested for a foreground command.
///
/// The value is borrowed only for the duration of
/// `Ctx.terminal().runForegroundCommand`. Chasen copies `.path` bytes and
/// duplicates `.dir` before publishing the queued command. The caller keeps
/// ownership of the original directory descriptor.
///
/// `.inherit` is resolved when the child is spawned. `.path` preserves only
/// the queued bytes and is also resolved at spawn time; only `.dir` preserves
/// an already-open directory identity across rename or path replacement.
/// Directory descriptors are supported on Linux and macOS. Other targets
/// reject `.dir` while retaining their existing `.inherit` and `.path`
/// behavior. On POSIX, `std.Io.Dir.cwd()` is a pseudo descriptor rather than
/// an opened directory and is rejected; use `.inherit` for that intent.
pub const ForegroundCommandCwd = union(enum) {
    inherit,
    path: []const u8,
    dir: std.Io.Dir,
};

/// Errors that can occur before a foreground command is published.
///
/// Rejection leaves all caller inputs owned by the caller and does not consume
/// a request id.
pub const ForegroundCommandQueueError = error{
    ForegroundCommandLimitExceeded,
    ForegroundCommandEmptyArgv,
    ForegroundCommandCwdUnsupported,
    ForegroundCommandInvalidCwd,
    ForegroundCommandProcessFdQuotaExceeded,
    ForegroundCommandSystemFdQuotaExceeded,
    ForegroundCommandDuplicateCwdFailed,
} || std.mem.Allocator.Error;

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
