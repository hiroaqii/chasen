const std = @import("std");

/// Runtime lifecycle boundary reported by `TraceFn`.
///
/// Trace events are notifications, not measurements. They are intended to show
/// which runtime boundary was reached and in what order. Use `RuntimeStats` for
/// per-iteration timing summaries.
pub const TraceEvent = enum {
    startup,
    shutdown,
    event_received,
    handle_event_start,
    handle_event_end,
    update_start,
    update_end,
    effect_drain_start,
    effect_drain_end,
    view_start,
    view_end,
    render_start,
    render_end,
};

/// Optional callback invoked when a runtime lifecycle boundary is reached.
///
/// `context` is the value from `RunOptions.runtime.trace_context`. Chasen does
/// not store, format, aggregate, or export trace events. The callback should
/// avoid expensive work because it runs on the runtime path.
pub const TraceFn = *const fn (context: ?*anyopaque, event: TraceEvent) void;

test "TraceEvent exposes lifecycle boundaries" {
    try std.testing.expectEqual(@as(usize, 13), @typeInfo(TraceEvent).@"enum".fields.len);
    try std.testing.expectEqualStrings("startup", @tagName(TraceEvent.startup));
    try std.testing.expectEqualStrings("render_end", @tagName(TraceEvent.render_end));
}
