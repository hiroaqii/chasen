const std = @import("std");
const vaxis = @import("vaxis");
const runtime = @import("../runtime.zig");
const types = @import("../program_types.zig");
const requests_mod = @import("../requests.zig");
const InternalEvent = types.InternalEvent;
const frame_interval_ns: u64 = std.time.ns_per_s / 60;

/// Owns the single scheduled frame and its delivered timeline.
pub fn FrameRuntime(comptime Msg: type) type {
    return struct {
        const Self = @This();

        io: std.Io,
        future: ?std.Io.Future(void) = null,
        in_flight: bool = false,
        last_frame_ns: u64,
        next_index: u64 = 0,

        pub fn init(io: std.Io) Self {
            return .{ .io = io, .last_frame_ns = timestampNs(io) };
        }

        pub fn startRequested(
            self: *Self,
            requests: *requests_mod.Requests(Msg),
            loop: *vaxis.Loop(InternalEvent(Msg)),
            suspended: *const std.atomic.Value(bool),
            shutting_down: *const std.atomic.Value(bool),
        ) void {
            if (!requests.takeFrameRequest()) return;
            if (self.in_flight) return;
            const after_ns = frameDelayNs(self.last_frame_ns, timestampNs(self.io));
            self.future = self.io.concurrent(
                FrameHelper(Msg).run,
                .{ after_ns, self.last_frame_ns, self.next_index, self.io, loop, suspended, shutting_down },
            ) catch return;
            self.in_flight = true;
        }

        pub fn receiveFrame(self: *Self, frame: runtime.Frame) runtime.Frame {
            self.awaitFrame();
            self.last_frame_ns = frame.now_ns;
            self.next_index = frame.index + 1;
            return frame;
        }

        pub fn receiveCanceled(self: *Self, requests: *requests_mod.Requests(Msg)) void {
            self.awaitFrame();
            // Keep the delivered timeline through a foreground suspension.
            requests.frame().request();
        }

        fn awaitFrame(self: *Self) void {
            if (self.future) |*future| {
                _ = future.await(self.io);
                self.future = null;
            }
            self.in_flight = false;
        }

        pub fn shutdown(self: *Self) void {
            if (self.future) |*future| {
                _ = future.cancel(self.io);
                self.future = null;
            }
            self.in_flight = false;
        }
    };
}

/// Sleeps until the next frame slot then posts a frame event.
fn FrameHelper(comptime Msg: type) type {
    const Event = InternalEvent(Msg);
    return struct {
        fn run(
            after_ns: u64,
            last_frame_ns: u64,
            index: u64,
            frame_io: std.Io,
            loop_ptr: *vaxis.Loop(Event),
            suspended: *const std.atomic.Value(bool),
            shutting_down: *const std.atomic.Value(bool),
        ) void {
            frame_io.sleep(.fromNanoseconds(@intCast(after_ns)), .awake) catch return;
            if (suspended.load(.seq_cst)) {
                types.postPlainUntilShutdown(Msg, .frame_canceled, frame_io, loop_ptr, shutting_down);
                return;
            }
            const now_ns = timestampNs(frame_io);
            types.postPlainUntilShutdown(Msg, .{ .frame = .{
                .now_ns = now_ns,
                .delta_ns = deltaNs(last_frame_ns, now_ns),
                .index = index,
            } }, frame_io, loop_ptr, shutting_down);
        }
    };
}

pub fn timestampNs(io: std.Io) u64 {
    const ns = std.Io.Clock.now(.awake, io).nanoseconds;
    if (ns <= 0) return 0;
    return std.math.lossyCast(u64, ns);
}

pub fn deltaNs(previous_ns: u64, now_ns: u64) u64 {
    if (now_ns <= previous_ns) return 0;
    return now_ns - previous_ns;
}

fn frameDelayNs(last_frame_ns: u64, now_ns: u64) u64 {
    return frame_interval_ns -| deltaNs(last_frame_ns, now_ns);
}

test "FrameHelper instantiation" {
    const InstantiationMsg = union(enum) { hello };
    const Helper = FrameHelper(InstantiationMsg);
    const RunFn = @TypeOf(Helper.run);
    try std.testing.expect(RunFn != void);
}

test "deltaNs clamps non-monotonic timestamps" {
    try std.testing.expectEqual(@as(u64, 5), deltaNs(10, 15));
    try std.testing.expectEqual(@as(u64, 0), deltaNs(10, 10));
    try std.testing.expectEqual(@as(u64, 0), deltaNs(10, 9));
}

test "frameDelayNs paces relative to last delivered frame" {
    try std.testing.expectEqual(frame_interval_ns, frameDelayNs(100, 100));
    try std.testing.expectEqual(frame_interval_ns - 5, frameDelayNs(100, 105));
    try std.testing.expectEqual(@as(u64, 0), frameDelayNs(100, 100 + frame_interval_ns));
    try std.testing.expectEqual(@as(u64, 0), frameDelayNs(100, 101 + frame_interval_ns));
    try std.testing.expectEqual(frame_interval_ns, frameDelayNs(100, 99));
}

const TestMsg = enum { noop };

fn nextFrameEvent(loop: *vaxis.Loop(InternalEvent(TestMsg)), io: std.Io) !InternalEvent(TestMsg) {
    for (0..2000) |_| {
        if (try loop.tryEvent()) |event| return event;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.FrameDeliveryTimedOut;
}

test "frame runtime coalesces requests and preserves its timeline across suspension" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var requests = requests_mod.Requests(TestMsg).init(allocator, io);
    defer requests.deinit();
    var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
    var suspended: std.atomic.Value(bool) = .init(true);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var frames = FrameRuntime(TestMsg).init(io);
    defer frames.shutdown();
    // A long idle gap must survive cancellation, rather than being rebased.
    const old_ns = timestampNs(io) -| (10 * std.time.ns_per_s);
    frames.last_frame_ns = old_ns;
    requests.frame().request();
    frames.startRequested(&requests, &loop, &suspended, &shutting_down);
    try std.testing.expect(frames.in_flight);
    requests.frame().request();
    requests.frame().request();
    frames.startRequested(&requests, &loop, &suspended, &shutting_down);
    try std.testing.expect(!requests.takeFrameRequest());
    const canceled = try nextFrameEvent(&loop, io);
    try std.testing.expect(canceled == .frame_canceled);
    frames.receiveCanceled(&requests);
    try std.testing.expect(!frames.in_flight and frames.future == null);
    try std.testing.expectEqual(old_ns, frames.last_frame_ns);
    try std.testing.expectEqual(@as(u64, 0), frames.next_index);
    suspended.store(false, .seq_cst);
    // receiveCanceled itself re-requested, and await released the sole slot.
    frames.startRequested(&requests, &loop, &suspended, &shutting_down);
    try std.testing.expect(frames.in_flight);
    const first = (try nextFrameEvent(&loop, io)).frame;
    // A frame already in the queue still belongs to the delivered timeline.
    suspended.store(true, .seq_cst);
    const delivered = frames.receiveFrame(first);
    try std.testing.expectEqual(first, delivered);
    try std.testing.expectEqual(@as(u64, 0), delivered.index);
    try std.testing.expectEqual(delivered.now_ns - old_ns, delivered.delta_ns);
    try std.testing.expect(delivered.delta_ns >= 10 * std.time.ns_per_s);
    try std.testing.expectEqual(delivered.now_ns, frames.last_frame_ns);
    try std.testing.expectEqual(@as(u64, 1), frames.next_index);
    try std.testing.expect(!frames.in_flight and frames.future == null);
    suspended.store(false, .seq_cst);
    requests.frame().request();
    frames.startRequested(&requests, &loop, &suspended, &shutting_down);
    requests.frame().request();
    frames.startRequested(&requests, &loop, &suspended, &shutting_down);
    const second = frames.receiveFrame((try nextFrameEvent(&loop, io)).frame);
    try std.testing.expectEqual(@as(u64, 1), second.index);
    try std.testing.expectEqual(second.now_ns - delivered.now_ns, second.delta_ns);
    try std.testing.expectEqual(@as(u64, 2), frames.next_index);
    try std.testing.expectEqual(@as(?InternalEvent(TestMsg), null), try loop.tryEvent());
    frames.startRequested(&requests, &loop, &suspended, &shutting_down);
    try std.testing.expect(!frames.in_flight);
}

test "frame runtime start failure consumes only the request and leaves timeline unchanged" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    const io = threaded.io();
    var requests = requests_mod.Requests(TestMsg).init(allocator, io);
    defer requests.deinit();
    var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
    var suspended: std.atomic.Value(bool) = .init(false);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var frames = FrameRuntime(TestMsg).init(io);
    defer frames.shutdown();
    const last_ns = frames.last_frame_ns;
    for (0..2) |_| {
        requests.frame().request();
        frames.startRequested(&requests, &loop, &suspended, &shutting_down);
        try std.testing.expect(!frames.in_flight and frames.future == null);
        try std.testing.expect(!requests.takeFrameRequest());
        try std.testing.expectEqual(last_ns, frames.last_frame_ns);
        try std.testing.expectEqual(@as(u64, 0), frames.next_index);
        try std.testing.expectEqual(@as(?InternalEvent(TestMsg), null), try loop.tryEvent());
    }
}

test "frame runtime shutdown cancels a producer behind a full queue" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var requests = requests_mod.Requests(TestMsg).init(allocator, io);
    defer requests.deinit();
    var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
    var suspended: std.atomic.Value(bool) = .init(false);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var frames = FrameRuntime(TestMsg).init(io);
    defer frames.shutdown();
    while (try loop.tryPostEvent(.continue_effect_drain)) {}
    frames.last_frame_ns = 0;
    requests.frame().request();
    frames.startRequested(&requests, &loop, &suspended, &shutting_down);
    try std.testing.expect(frames.in_flight);
    frames.shutdown();
    try std.testing.expect(!frames.in_flight and frames.future == null);
    try std.testing.expectEqual(@as(u64, 0), frames.last_frame_ns);
    try std.testing.expectEqual(@as(u64, 0), frames.next_index);
    while (try loop.tryEvent()) |event| try std.testing.expect(event == .continue_effect_drain);
    // Reusing the only concurrent slot proves that shutdown joined the worker.
    requests.frame().request();
    frames.startRequested(&requests, &loop, &suspended, &shutting_down);
    const frame = frames.receiveFrame((try nextFrameEvent(&loop, io)).frame);
    try std.testing.expectEqual(@as(u64, 0), frame.index);
}
