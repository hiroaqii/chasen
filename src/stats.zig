const std = @import("std");

/// Runtime event category reported with `RuntimeStats`.
///
/// This is intentionally smaller than `Event`: it is for profiling and
/// debugging summaries, not for reconstructing input details.
pub const RuntimeEventKind = enum {
    key_press,
    mouse,
    winsize,
    paste,
    focus_in,
    focus_out,
    frame,
    user_msg,
};

/// Per-iteration runtime timings and counters.
///
/// `RuntimeStats` is reported after one runtime event has been handled. Counts
/// are cumulative since program start. Durations describe only the just-finished
/// event loop iteration and are measured in nanoseconds.
///
/// Terminal resize work performed by the runtime before app `handleEvent`
/// currently is not included in any phase duration.
///
/// These values are a lightweight observation point for apps and tests. They
/// are not a replacement for external profilers such as Linux `perf`; use them
/// to find whether work is in handleEvent, update, effect draining, view, or
/// render, then use a profiler to investigate inside that phase.
///
/// When `RunOptions.stats_fn` is `null`, the runtime does not construct
/// `RuntimeStats` or perform these timing measurements.
pub const RuntimeStats = struct {
    /// Category of runtime event handled in this iteration.
    event_kind: RuntimeEventKind,
    /// Number of runtime events handled since program start.
    event_count: u64,
    /// Number of frame events handled since program start.
    frame_count: u64,
    /// Whether app update ran in this iteration.
    did_update: bool = false,
    /// Whether app view and terminal render ran in this iteration.
    did_render: bool = false,
    /// Time spent in app handleEvent for this iteration.
    handle_event_ns: u64 = 0,
    /// Time spent in app update for this iteration.
    update_ns: u64 = 0,
    /// Time spent checking and draining Ctx effects for this iteration.
    ///
    /// This includes the no-op check cost when no effects were queued.
    effect_drain_ns: u64 = 0,
    /// Time spent in app view for this iteration.
    view_ns: u64 = 0,
    /// Time spent in libvaxis render for this iteration.
    render_ns: u64 = 0,
};

/// Optional callback invoked by the runtime after one event loop iteration.
///
/// `context` is the value from `RunOptions.stats_context`. The callback should
/// avoid expensive work because it runs on the runtime path.
pub const StatsFn = *const fn (context: ?*anyopaque, stats: RuntimeStats) void;

test "RuntimeStats initializes with phase duration defaults" {
    const stats: RuntimeStats = .{
        .event_kind = .key_press,
        .event_count = 1,
        .frame_count = 0,
    };

    try std.testing.expectEqual(RuntimeEventKind.key_press, stats.event_kind);
    try std.testing.expectEqual(@as(u64, 1), stats.event_count);
    try std.testing.expectEqual(@as(u64, 0), stats.frame_count);
    try std.testing.expect(!stats.did_update);
    try std.testing.expect(!stats.did_render);
    try std.testing.expectEqual(@as(u64, 0), stats.handle_event_ns);
    try std.testing.expectEqual(@as(u64, 0), stats.update_ns);
    try std.testing.expectEqual(@as(u64, 0), stats.effect_drain_ns);
    try std.testing.expectEqual(@as(u64, 0), stats.view_ns);
    try std.testing.expectEqual(@as(u64, 0), stats.render_ns);
}
