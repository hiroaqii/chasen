const std = @import("std");
const vaxis = @import("vaxis");
const runtime = @import("runtime.zig");
const runtime_limits = @import("runtime_limits.zig");
const terminal_image = @import("terminal_image.zig");
const terminal_mouse = @import("terminal_mouse.zig");

/// Terminal event type passed to `handleEvent`.
pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    /// Bracketed-paste content. Only valid during the current event dispatch.
    /// OSC 52 clipboard-read responses are not exposed as application events.
    paste: []const u8,
    focus_in,
    focus_out,
    /// Requested animation/media frame.
    frame: runtime.Frame,
};

pub const KeyboardProtocol = enum {
    /// Do not enable enhanced keyboard protocols. This is the most compatible
    /// mode for IME composition and language toggles.
    legacy,
    /// Enable Kitty keyboard protocol when the terminal reports support.
    ///
    /// This can improve modified-key reporting, but some terminal/IME
    /// combinations deliver language toggle keys to the app instead of the
    /// input method while this mode is active.
    kitty,
};

/// Coordinate protocol used for terminal mouse reports.
pub const MouseCoordinateProtocol = terminal_mouse.CoordinateProtocol;

/// Terminal-backend options for `runWith`.
pub const TerminalOptions = struct {
    env_map: *std.process.Environ.Map,
    /// Optional terminal image path loader.
    ///
    /// Leave null when the app does not load terminal images. Terminal-only
    /// runners can provide an adapter outside core when image decode/transmit
    /// support is needed.
    image_path_loader: ?terminal_image.PathLoaderFn = null,
    /// Optional caller-owned context passed to `image_path_loader`.
    image_loader_context: ?*anyopaque = null,
    /// Enable terminal mouse reporting for apps that handle `Event.mouse`.
    ///
    /// This is opt-in because terminal mouse reporting can interfere with
    /// normal text selection/copy in many terminal emulators.
    mouse: bool = false,
    /// Coordinate protocol used when mouse reporting is enabled.
    ///
    /// Cell SGR is the portable default across terminals and multiplexers.
    /// Use `.auto` only when the complete terminal path preserves pixel SGR.
    mouse_coordinate_protocol: MouseCoordinateProtocol = .cell_sgr,
    /// Keyboard protocol used by the terminal backend.
    keyboard_protocol: KeyboardProtocol = .legacy,
};

/// Options for the low-level `runWith` entry point.
pub const RunOptions = struct {
    runtime: runtime.RuntimeOptions,
    terminal: TerminalOptions,
};

// Shared with the OSC 52 regression executable so it uses the runtime's exact
// event type. This is internal to Chasen and is not re-exported by root.zig.
pub fn InternalEvent(comptime Msg: type) type {
    return union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
        mouse: vaxis.Mouse,
        focus_in,
        focus_out,
        // Deliberately no libvaxis `.paste` field. Chasen does not expose an
        // OSC 52 clipboard-read request; ordinary user paste is assembled from
        // the bracketed-paste markers below. Without this field libvaxis frees
        // an unsolicited OSC 52 response immediately instead of transferring
        // allocator-owned text through its blocking event-queue post.
        paste_start,
        paste_end,
        frame: runtime.Frame,
        frame_canceled,
        /// Non-owning wake for a coalesced resize poll. The latest size is
        /// stored outside the bounded queue so a full queue never loses the
        /// final resize.
        resize_pending,
        /// Wakes the main loop when a bounded synchronous effect drain leaves
        /// work for another pass. It carries no app-owned payload.
        continue_effect_drain,
        /// Payload-free wake after a timer publishes completion. A full queue
        /// needs no extra wake; every effect-drain entrance reaps completed nodes.
        timers_completed,

        /// Async task result injected via postEvent.
        user_msg: Msg,
        /// Copied non-owning notice; the runtime creates a Msg only on dispatch.
        timer_notification: @import("timer.zig").Notification(Msg),
    };
}

pub fn RuntimeCompletionBuffer(comptime Msg: type) type {
    return struct {
        const Self = @This();
        // A single drain pass can manufacture at most one completion per
        // queued task/tick/every start failure and terminal image load. Preallocating the
        // sum keeps completion transport allocation-free, which avoids an
        // error path that would otherwise need another callback transport.
        pub const capacity = runtime_limits.max_tasks + runtime_limits.max_ticks +
            runtime_limits.max_everys + runtime_limits.max_terminal_image_loads;

        items: std.ArrayList(Msg) = .empty,

        pub fn init(self: *Self, allocator: std.mem.Allocator) !void {
            try self.items.ensureTotalCapacityPrecise(allocator, capacity);
        }

        pub fn append(self: *Self, msg: Msg) error{RuntimeCompletionLimitExceeded}!void {
            if (self.items.items.len >= capacity) return error.RuntimeCompletionLimitExceeded;
            self.items.appendAssumeCapacity(msg);
        }

        pub fn deinitUndelivered(self: *Self, allocator: std.mem.Allocator) void {
            for (self.items.items) |*msg| {
                runtime.deinitUndeliveredMessage(Msg, msg, allocator);
            }
            self.items.deinit(allocator);
            self.* = .{};
        }
    };
}

test "InternalEvent instantiation" {
    const TestMsg = union(enum) { hello, value: u32 };
    const TestEvent = InternalEvent(TestMsg);

    const ev: TestEvent = .{ .user_msg = .hello };
    try std.testing.expect(ev == .user_msg);

    const key_ev: TestEvent = .{ .key_press = .{ .codepoint = 'a' } };
    try std.testing.expect(key_ev == .key_press);

    const paste_start_ev: TestEvent = .paste_start;
    try std.testing.expect(paste_start_ev == .paste_start);

    const paste_end_ev: TestEvent = .paste_end;
    try std.testing.expect(paste_end_ev == .paste_end);

    const frame_ev: TestEvent = .{ .frame = .{ .now_ns = 100, .delta_ns = 16, .index = 2 } };
    try std.testing.expect(frame_ev == .frame);
}

/// Post a plain/copy-safe internal event without blocking shutdown behind a
/// full queue. Timer events contain non-owning notices, never generated Msgs.
/// Propagate cancellation so a repeating producer exits instead of retrying.
pub fn postPlainUntilShutdown(
    comptime Msg: type,
    event: InternalEvent(Msg),
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    shutting_down: *const std.atomic.Value(bool),
) std.Io.Cancelable!void {
    while (!shutting_down.load(.seq_cst)) {
        const posted = try loop.tryPostEvent(event);
        if (posted) return;
        try io.sleep(.fromNanoseconds(100 * std.time.ns_per_us), .awake);
    }
}

test "postPlainUntilShutdown propagates cancellation from the queue mutex" {
    const CancelWait = struct {
        fn wait(_: ?*anyopaque, _: *const u32, _: u32, _: std.Io.Timeout) std.Io.Cancelable!void {
            return error.Canceled;
        }
    };
    var io = std.testing.io;
    var vtable = io.vtable.*;
    vtable.futexWait = CancelWait.wait;
    io.vtable = &vtable;
    const Msg = enum { noop };
    var loop = vaxis.Loop(InternalEvent(Msg)).init(io, undefined, undefined);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    try std.testing.expect(try loop.tryPostEvent(.frame_canceled));
    {
        // Force tryPostEvent to reach its cancellable lock wait, independently
        // of the retry-sleep cancellation exercised by the real timer worker.
        loop.queue.mutex.lockUncancelable(io);
        defer loop.queue.mutex.unlock(io);
        try std.testing.expectError(error.Canceled, postPlainUntilShutdown(Msg, .continue_effect_drain, io, &loop, &shutting_down));
    }
    try std.testing.expect(!shutting_down.load(.seq_cst));
    try std.testing.expect((try loop.tryEvent()).? == .frame_canceled);
    try std.testing.expectEqual(@as(?InternalEvent(Msg), null), try loop.tryEvent());
}

// Shared synchronous observation helpers; no runtime owner is borrowed.
fn timestampNs(io: std.Io) u64 {
    const ns = std.Io.Clock.now(.awake, io).nanoseconds;
    if (ns <= 0) return 0;
    return std.math.lossyCast(u64, ns);
}

pub fn timingStart(enabled: bool, io: std.Io) u64 {
    return if (enabled) timestampNs(io) else 0;
}

pub fn timingElapsed(start_ns: u64, io: std.Io) u64 {
    return elapsedNs(start_ns, timestampNs(io));
}

fn elapsedNs(start_ns: u64, end_ns: u64) u64 {
    return if (end_ns >= start_ns) end_ns - start_ns else 0;
}

pub fn trace(opts: RunOptions, event: runtime.TraceEvent) void {
    if (opts.runtime.trace_fn) |trace_fn| {
        trace_fn(opts.runtime.trace_context, event);
    }
}

test "elapsedNs uses deltaNs clamping" {
    try std.testing.expectEqual(@as(u64, 5), elapsedNs(10, 15));
    try std.testing.expectEqual(@as(u64, 0), elapsedNs(10, 9));
}

test "timingStart returns zero when timing is disabled" {
    const io: std.Io = undefined;
    try std.testing.expectEqual(@as(u64, 0), timingStart(false, io));
}
