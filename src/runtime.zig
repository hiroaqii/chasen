const std = @import("std");

pub const ctx = @import("ctx.zig");
pub const Ctx = ctx.Ctx;
pub const Requests = @import("requests.zig").Requests;
pub const TaskStartError = ctx.TaskStartError;
pub const TaskId = ctx.TaskId;
pub const Borrowed = @import("timer.zig").Borrowed;
pub const TimerStartError = @import("timer.zig").TimerStartError;
pub const TimerOutcome = @import("timer.zig").TimerOutcome;

pub const stats = @import("stats.zig");
pub const RuntimeEventKind = stats.RuntimeEventKind;
pub const RuntimeStats = stats.RuntimeStats;
pub const StatsFn = stats.StatsFn;

pub const trace = @import("trace.zig");
pub const TraceEvent = trace.TraceEvent;
pub const TraceFn = trace.TraceFn;

pub const runtime_effect = @import("runtime_effect.zig");
pub const RuntimeEffectKind = runtime_effect.RuntimeEffectKind;
pub const EffectSupport = runtime_effect.EffectSupport;
pub const BrowserInitialEffects = runtime_effect.BrowserInitialEffects;

/// Frame timing delivered by `Event.frame`.
pub const Frame = struct {
    /// Monotonic timestamp for this frame, in nanoseconds.
    now_ns: u64,
    /// Nanoseconds since the previous frame timestamp.
    delta_ns: u64,
    /// Monotonic frame counter starting at 0.
    index: u64,
};

/// Declares how an app root message is disposed when the runtime can no longer
/// deliver it to `App.update`.
///
/// Chasen requires every root `Msg` type to choose explicitly. This prevents an
/// allocator-owning result from silently inheriting plain-value drop semantics.
pub const UndeliveredPolicy = enum {
    /// Every message variant is safe to discard by value. Timer templates must
    /// use this kind of non-owning/copy-safe message.
    plain,
    /// `Msg` provides `deinitUndelivered(*Msg, allocator)`.
    deinit,
};

/// Validate the root message ownership contract used by all runtime producers.
pub fn validateUndeliveredPolicy(comptime Msg: type) void {
    if (!@hasDecl(Msg, "undelivered_policy")) {
        @compileError("App.Msg must declare `pub const undelivered_policy = .plain` or `.deinit`");
    }

    const policy: UndeliveredPolicy = Msg.undelivered_policy;
    switch (policy) {
        .plain => {
            if (@hasDecl(Msg, "deinitUndelivered")) {
                @compileError("App.Msg with `.plain` undelivered_policy must not declare deinitUndelivered");
            }
        },
        .deinit => {
            if (!@hasDecl(Msg, "deinitUndelivered")) {
                @compileError("App.Msg with `.deinit` undelivered_policy must declare `deinitUndelivered(*Msg, allocator) void`");
            }
            const expected: *const fn (*Msg, std.mem.Allocator) void = Msg.deinitUndelivered;
            _ = expected;
        },
    }
}

/// Dispose one message that will not enter `App.update`.
///
/// This runs on the runtime thread before `App.deinit`. Once a message has been
/// passed to `App.update`, the app owns it even when update returns an error.
pub fn deinitUndeliveredMessage(comptime Msg: type, msg: *Msg, allocator: std.mem.Allocator) void {
    const policy: UndeliveredPolicy = Msg.undelivered_policy;
    switch (policy) {
        .plain => {},
        .deinit => msg.deinitUndelivered(allocator),
    }
}

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
