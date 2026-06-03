const std = @import("std");

pub const ctx = @import("ctx.zig");
pub const Ctx = ctx.Ctx;

pub const cmd = @import("cmd.zig");
pub const Cmd = cmd.Cmd;

pub const stats = @import("stats.zig");
pub const RuntimeEventKind = stats.RuntimeEventKind;
pub const RuntimeStats = stats.RuntimeStats;
pub const StatsFn = stats.StatsFn;

pub const trace = @import("trace.zig");
pub const TraceEvent = trace.TraceEvent;
pub const TraceFn = trace.TraceFn;

/// Cleanup context passed to optional app `deinit`.
///
/// This context is intentionally smaller than `Ctx`: shutdown cleanup cannot
/// queue effects, spawn work, or request frames.
pub const AppDeinitContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
};

/// Backend-independent runtime options.
pub const RuntimeOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// Optional callback called after each runtime event loop iteration.
    ///
    /// The callback receives lightweight timing information. Chasen does not
    /// store, aggregate, format, or export these stats. When this is `null`,
    /// Chasen skips runtime timing measurements.
    stats_fn: ?StatsFn = null,
    /// Optional caller-owned context passed to `stats_fn`.
    stats_context: ?*anyopaque = null,
    /// Optional callback called at runtime lifecycle boundaries.
    ///
    /// The callback receives event notifications, not timings. Chasen does not
    /// store, aggregate, format, or export trace events.
    trace_fn: ?TraceFn = null,
    /// Optional caller-owned context passed to `trace_fn`.
    trace_context: ?*anyopaque = null,
};

test {
    std.testing.refAllDecls(@This());
}
