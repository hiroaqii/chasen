const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const requests_mod = @import("../requests.zig");
const runtime = @import("../runtime.zig");
const types = @import("../program_types.zig");
const InternalEvent = types.InternalEvent;

// Private test barriers surround the real worker's terminal publication. They
// are absent from production storage and do not substitute a fake worker/Io.
const TestBarrier = struct {
    reached: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    fn pause(self: *TestBarrier, io: std.Io) void {
        self.reached.set(io);
        self.release.waitUncancelable(io);
    }
};
const TestHooks = struct {
    before_completed: ?*TestBarrier = null,
    after_completed: ?*TestBarrier = null,
    after_wake: ?*std.Io.Event = null,
};
const WorkerHooks = if (builtin.is_test) ?*TestHooks else void;

/// Owns stable nodes until their workers are canceled/joined or reaped.
pub fn TimerRuntime(comptime Msg: type) type {
    return struct {
        const Self = @This();
        const Entry = @import("../timer_entry.zig").TimerEntry(Msg);
        allocator: std.mem.Allocator,
        io: std.Io,
        running: std.ArrayList(*Entry) = .empty,
        test_hooks: WorkerHooks = if (builtin.is_test) null else {},

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{ .allocator = allocator, .io = io };
        }

        pub fn startTicks(self: *Self, requests: *requests_mod.Requests(Msg), completions: *types.RuntimeCompletionBuffer(Msg), loop: *vaxis.Loop(InternalEvent(Msg)), shutting_down: *const std.atomic.Value(bool)) !void {
            var pending = requests.detachTicks();
            defer pending.deinit();
            while (pending.next()) |entry| {
                try self.startEntry(false, entry, requests, completions, loop, null, shutting_down);
            }
        }

        pub fn startEvery(self: *Self, requests: *requests_mod.Requests(Msg), completions: *types.RuntimeCompletionBuffer(Msg), loop: *vaxis.Loop(InternalEvent(Msg)), suspended: *const std.atomic.Value(bool), shutting_down: *const std.atomic.Value(bool)) !void {
            var pending = requests.detachEverys();
            defer pending.deinit();
            while (pending.next()) |entry| {
                try self.startEntry(true, entry, requests, completions, loop, suspended, shutting_down);
            }
        }

        fn startEntry(self: *Self, comptime repeating: bool, entry: *Entry, requests: *requests_mod.Requests(Msg), completions: *types.RuntimeCompletionBuffer(Msg), loop: *vaxis.Loop(InternalEvent(Msg)), suspended: ?*const std.atomic.Value(bool), shutting_down: *const std.atomic.Value(bool)) !void {
            var transferred = false;
            defer if (!transferred) entry.destroy(self.allocator);
            if (requests.shouldQuit() or shutting_down.load(.seq_cst)) return;
            self.cancel(entry.id);
            // Reserve before concurrent: a started worker can never race a
            // tracking failure, including a tick with zero delay.
            self.running.ensureUnusedCapacity(self.allocator, 1) catch {
                return self.startFailed(entry, error.OutOfMemory, completions);
            };
            const future = self.io.concurrent(run, .{ entry, repeating, self.io, loop, suspended, shutting_down, self.test_hooks }) catch {
                return self.startFailed(entry, error.ConcurrencyUnavailable, completions);
            };
            entry.future = future;
            self.running.appendAssumeCapacity(entry);
            transferred = true;
        }

        fn startFailed(self: *Self, entry: *const Entry, failure: runtime.TimerStartError, completions: *types.RuntimeCompletionBuffer(Msg)) !void {
            if (entry.notification.message(.{ .failed = failure }, self.allocator)) |value| {
                var msg = value;
                completions.append(msg) catch |err| {
                    runtime.deinitUndeliveredMessage(Msg, &msg, self.allocator);
                    return err;
                };
            }
        }

        fn run(entry: *Entry, repeating: bool, io: std.Io, loop: *vaxis.Loop(InternalEvent(Msg)), suspended: ?*const std.atomic.Value(bool), shutting_down: *const std.atomic.Value(bool), hooks: WorkerHooks) void {
            defer {
                if (builtin.is_test) if (hooks) |h| {
                    if (h.before_completed) |barrier| barrier.pause(io);
                };
                entry.completed.store(true, .release);
                if (builtin.is_test) if (hooks) |h| {
                    if (h.after_completed) |barrier| barrier.pause(io);
                };
                // Never wait for queue capacity after publishing completion.
                // A full queue already guarantees another effect-drain turn.
                _ = loop.tryPostEvent(.timers_completed) catch false;
                if (builtin.is_test) if (hooks) |h| {
                    if (h.after_wake) |event| event.set(io);
                };
            }
            // u64 -> i96 is a widening conversion; even maxInt(u64) is valid.
            while (!shutting_down.load(.seq_cst)) {
                io.sleep(.fromNanoseconds(entry.duration_ns), .awake) catch return;
                if (repeating and suspended.?.load(.seq_cst)) continue;
                types.postPlainUntilShutdown(Msg, .{ .timer_notification = entry.notification }, io, loop, shutting_down);
                if (!repeating) return;
            }
        }

        /// Called without the event-queue lock. A published completion means
        /// no sleep/post retry remains, but the backend may still own the node.
        /// Join before freeing, and never wait for an active timer here.
        pub fn reapCompleted(self: *Self) void {
            var i: usize = 0;
            while (i < self.running.items.len) {
                const entry = self.running.items[i];
                if (!entry.completed.load(.acquire)) {
                    i += 1;
                    continue;
                }
                entry.future.await(self.io);
                entry.destroy(self.allocator);
                _ = self.running.swapRemove(i);
            }
        }

        fn cancel(self: *Self, id: []const u8) void {
            var i: usize = 0;
            while (i < self.running.items.len) {
                const entry = self.running.items[i];
                if (std.mem.eql(u8, entry.id, id)) {
                    _ = entry.future.cancel(self.io);
                    entry.destroy(self.allocator);
                    _ = self.running.swapRemove(i);
                } else i += 1;
            }
        }

        pub fn cancelPending(self: *Self, requests: *requests_mod.Requests(Msg)) void {
            var pending = requests.detachCancels();
            defer pending.deinit();
            while (pending.next()) |id| {
                defer self.allocator.free(id);
                self.cancel(id);
            }
        }

        pub fn shutdown(self: *Self) void {
            for (self.running.items) |entry| {
                _ = entry.future.cancel(self.io);
                entry.destroy(self.allocator);
            }
            self.running.deinit(self.allocator);
            self.running = .empty;
        }
    };
}

const TestMsg = union(enum) {
    fired: TimerNotice,
    failed: struct { notice: TimerNotice, err: runtime.TimerStartError },
    pub const TimerNotice = enum { old, replacement };
    pub const undelivered_policy = .plain;
    fn notify(notice: TimerNotice, outcome: runtime.TimerOutcome, _: std.mem.Allocator) ?TestMsg {
        return switch (outcome) {
            .fired => .{ .fired = notice },
            .failed => |err| .{ .failed = .{ .notice = notice, .err = err } },
        };
    }
};

fn expectReplacement(loop: *vaxis.Loop(InternalEvent(TestMsg)), io: std.Io) !void {
    for (0..2000) |_| {
        if (try loop.tryEvent()) |event| {
            if (event == .timers_completed) continue;
            const msg = event.timer_notification.message(.fired, std.testing.allocator).?;
            try std.testing.expectEqual(TestMsg.TimerNotice.replacement, msg.fired);
            return;
        }
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TimerDeliveryTimedOut;
}

test "timer runtime replaces the running ID before admitting a same-ID tick or every" {
    for ([_]bool{ false, true }) |old_every| {
        for ([_]bool{ false, true }) |new_every| {
            for ([_]bool{ false, true }) |cancel_first| {
                const allocator = std.testing.allocator;
                // A replacement can start only after the previous Future releases
                // the sole concurrent slot. Long delays keep the old Msg unposted.
                var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
                defer threaded.deinit();
                const io = threaded.io();
                var requests = requests_mod.Requests(TestMsg).init(allocator, io);
                defer requests.deinit();
                var timers = TimerRuntime(TestMsg).init(allocator, io);
                defer timers.shutdown();
                var completions: types.RuntimeCompletionBuffer(TestMsg) = .{};
                try completions.init(allocator);
                defer completions.deinitUndelivered(allocator);
                var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
                var suspended: std.atomic.Value(bool) = .init(false);
                var shutting_down: std.atomic.Value(bool) = .init(false);
                if (old_every) {
                    try requests.timer().every("same", 60 * std.time.ns_per_s, .old, TestMsg.notify);
                } else {
                    try requests.timer().tick("same", 60 * std.time.ns_per_s, .old, TestMsg.notify);
                }
                try timers.startTicks(&requests, &completions, &loop, &shutting_down);
                try timers.startEvery(&requests, &completions, &loop, &suspended, &shutting_down);
                try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
                if (cancel_first) try requests.timer().cancel("same");
                if (new_every) {
                    try requests.timer().every("same", std.time.ns_per_ms, .replacement, TestMsg.notify);
                } else {
                    try requests.timer().tick("same", 0, .replacement, TestMsg.notify);
                }
                timers.cancelPending(&requests);
                if (cancel_first) try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
                try timers.startTicks(&requests, &completions, &loop, &shutting_down);
                try timers.startEvery(&requests, &completions, &loop, &suspended, &shutting_down);
                try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
                try expectReplacement(&loop, io);
                // No runtime reap has run yet; explicit cancellation can join it.
                try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
                try requests.timer().cancel("same");
                timers.cancelPending(&requests);
                try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
            }
        }
    }
}

test "timer invalid interval leaves a running timer intact after drain" {
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var requests = requests_mod.Requests(TestMsg).init(allocator, io);
    defer requests.deinit();
    var timers = TimerRuntime(TestMsg).init(allocator, io);
    defer timers.shutdown();
    var completions: types.RuntimeCompletionBuffer(TestMsg) = .{};
    try completions.init(allocator);
    defer completions.deinitUndelivered(allocator);
    var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
    var shutdown: std.atomic.Value(bool) = .init(false);
    var suspended: std.atomic.Value(bool) = .init(false);
    try requests.timer().tick("same", std.math.maxInt(u64), .old, TestMsg.notify);
    try timers.startTicks(&requests, &completions, &loop, &shutdown);
    const entry = timers.running.items[0];
    try std.testing.expectError(error.InvalidInterval, requests.timer().every("same", 0, .replacement, TestMsg.notify));
    try timers.startEvery(&requests, &completions, &loop, &suspended, &shutdown);
    try std.testing.expectEqual(entry, timers.running.items[0]);
    try std.testing.expectEqual(TestMsg.TimerNotice.old, entry.notification.notice);
    try std.testing.expectEqual(@as(usize, 0), completions.items.items.len);
}

test "timer runtime start and tracking failures notify without firing or leaving workers" {
    for ([_]bool{ false, true }) |every| {
        for ([_]bool{ false, true }) |fail_tracking| {
            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
            const allocator = failing.allocator();
            var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(if (fail_tracking) 1 else 0) });
            defer threaded.deinit();
            const io = threaded.io();
            var requests = requests_mod.Requests(TestMsg).init(allocator, io);
            defer requests.deinit();
            var timers = TimerRuntime(TestMsg).init(allocator, io);
            defer timers.shutdown();
            var completions: types.RuntimeCompletionBuffer(TestMsg) = .{};
            try completions.init(allocator);
            defer completions.deinitUndelivered(allocator);
            var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
            var suspended: std.atomic.Value(bool) = .init(false);
            var shutting_down: std.atomic.Value(bool) = .init(false);
            for ([_][]const u8{ "first", "second" }) |id| {
                if (every) {
                    try requests.timer().every(id, 60 * std.time.ns_per_s, .old, TestMsg.notify);
                } else {
                    try requests.timer().tick(id, 60 * std.time.ns_per_s, .old, TestMsg.notify);
                }
            }
            if (fail_tracking) failing.fail_index = failing.alloc_index;
            try timers.startTicks(&requests, &completions, &loop, &shutting_down);
            try timers.startEvery(&requests, &completions, &loop, &suspended, &shutting_down);
            try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
            try std.testing.expectEqual(@as(usize, 2), completions.items.items.len);
            for (completions.items.items) |msg| {
                try std.testing.expectEqual(TestMsg.TimerNotice.old, msg.failed.notice);
                try std.testing.expectEqual(if (fail_tracking) error.OutOfMemory else error.ConcurrencyUnavailable, msg.failed.err);
            }
            completions.items.clearRetainingCapacity();
            try std.testing.expect((try loop.tryEvent()) == null);
            if (fail_tracking) {
                try std.testing.expect(failing.has_induced_failure);
                failing.fail_index = std.math.maxInt(usize);
                try requests.timer().tick("after-failure", 0, .replacement, TestMsg.notify);
                try timers.startTicks(&requests, &completions, &loop, &shutting_down);
                // Tracking failure never started a worker, leaving the slot free.
                try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
                try expectReplacement(&loop, io);
            }
            timers.shutdown();
            completions.deinitUndelivered(allocator);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "timer runtime shutdown cancels notice producers behind a full queue" {
    for ([_]bool{ false, true }) |every| {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
        defer threaded.deinit();
        const io = threaded.io();
        var requests = requests_mod.Requests(TestMsg).init(allocator, io);
        defer requests.deinit();
        var timers = TimerRuntime(TestMsg).init(allocator, io);
        defer timers.shutdown();
        var completions: types.RuntimeCompletionBuffer(TestMsg) = .{};
        try completions.init(allocator);
        defer completions.deinitUndelivered(allocator);
        var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
        while (try loop.tryPostEvent(.continue_effect_drain)) {}
        var suspended: std.atomic.Value(bool) = .init(false);
        var shutting_down: std.atomic.Value(bool) = .init(false);
        if (every) {
            try requests.timer().every("full", 1, .old, TestMsg.notify);
        } else {
            try requests.timer().tick("full", 0, .old, TestMsg.notify);
        }
        try timers.startTicks(&requests, &completions, &loop, &shutting_down);
        try timers.startEvery(&requests, &completions, &loop, &suspended, &shutting_down);
        try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
        shutting_down.store(true, .seq_cst);
        timers.shutdown();
        try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
        while (try loop.tryEvent()) |event| try std.testing.expect(event == .continue_effect_drain or event == .timers_completed);
    }
}

test "timer completion overflow destroys generated Msg and unconsumed node suffix" {
    const Evidence = struct { calls: usize = 0, drops: usize = 0 };
    const Msg = struct {
        bytes: ?[]u8 = null,
        evidence: ?*Evidence = null,
        pub const TimerNotice = runtime.Borrowed(*Evidence);
        pub const undelivered_policy = .deinit;
        pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
            if (self.bytes) |bytes| {
                allocator.free(bytes);
                self.evidence.?.drops += 1;
            }
        }
        fn notify(notice: TimerNotice, outcome: runtime.TimerOutcome, allocator: std.mem.Allocator) ?@This() {
            std.debug.assert(outcome == .failed);
            notice.value.calls += 1;
            return .{ .bytes = allocator.dupe(u8, "failure") catch unreachable, .evidence = notice.value };
        }
    };
    const allocator = std.testing.allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    const io = threaded.io();
    var requests = requests_mod.Requests(Msg).init(allocator, io);
    defer requests.deinit();
    var timers = TimerRuntime(Msg).init(allocator, io);
    defer timers.shutdown();
    var completions: types.RuntimeCompletionBuffer(Msg) = .{};
    try completions.init(allocator);
    defer completions.deinitUndelivered(allocator);
    for (0..types.RuntimeCompletionBuffer(Msg).capacity) |_| try completions.append(.{});
    var loop = vaxis.Loop(InternalEvent(Msg)).init(io, undefined, undefined);
    var shutdown: std.atomic.Value(bool) = .init(false);
    var evidence: Evidence = .{};
    try requests.timer().tick("first", 0, .init(&evidence), Msg.notify);
    try requests.timer().tick("unconsumed", 0, .init(&evidence), Msg.notify);
    try std.testing.expectError(error.RuntimeCompletionLimitExceeded, timers.startTicks(&requests, &completions, &loop, &shutdown));
    try std.testing.expectEqual(@as(usize, 1), evidence.calls);
    try std.testing.expectEqual(@as(usize, 1), evidence.drops);
    try std.testing.expectEqual(@as(u8, 0), requests._pending_ticks_len);
    try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
}

fn waitForTestEvent(event: *std.Io.Event, io: std.Io) !void {
    for (0..5000) |_| {
        if (event.isSet()) return;
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    return error.TimerBarrierTimedOut;
}

test "timer late completion wakes idle runtime or falls back to an already full queue" {
    for ([_]bool{ false, true }) |full| {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(2) });
        defer threaded.deinit();
        const io = threaded.io();
        var requests = requests_mod.Requests(TestMsg).init(allocator, io);
        defer requests.deinit();
        var timers = TimerRuntime(TestMsg).init(allocator, io);
        defer timers.shutdown();
        var completions: types.RuntimeCompletionBuffer(TestMsg) = .{};
        try completions.init(allocator);
        defer completions.deinitUndelivered(allocator);
        var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
        var shutdown: std.atomic.Value(bool) = .init(false);
        try requests.timer().tick("sleeping", std.math.maxInt(u64), .old, TestMsg.notify);
        try timers.startTicks(&requests, &completions, &loop, &shutdown);
        const sleeping = timers.running.items[0];

        var barrier: TestBarrier = .{};
        defer barrier.release.set(io);
        var terminal: std.Io.Event = .unset;
        var hooks: TestHooks = .{ .before_completed = &barrier, .after_wake = &terminal };
        timers.test_hooks = &hooks;
        try requests.timer().tick("late", 0, .replacement, TestMsg.notify);
        try timers.startTicks(&requests, &completions, &loop, &shutdown);
        try waitForTestEvent(&barrier.reached, io);
        const notification = (try loop.tryEvent()).?.timer_notification;
        try std.testing.expectEqual(TestMsg.TimerNotice.replacement, notification.message(.fired, allocator).?.fired);
        try std.testing.expect((try loop.tryEvent()) == null);
        // The only app Msg is already consumed, but helper completion is later.
        timers.reapCompleted();
        try std.testing.expectEqual(@as(usize, 2), timers.running.items.len);
        if (full) while (try loop.tryPostEvent(.continue_effect_drain)) {};
        barrier.release.set(io);
        try waitForTestEvent(&terminal, io);
        const wake = (try loop.tryEvent()).?;
        const expected_wake: std.meta.Tag(InternalEvent(TestMsg)) = if (full) .continue_effect_drain else .timers_completed;
        try std.testing.expect(wake == expected_wake);
        timers.reapCompleted();
        try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
        try std.testing.expectEqual(sleeping, timers.running.items[0]);
        try std.testing.expect(!sleeping.completed.load(.acquire));
        // No extra input, replacement or explicit cancel was needed to reap.
        // A rejected wake did not wait for capacity; all existing events remain.
        while (try loop.tryEvent()) |event| try std.testing.expect(full and event == .continue_effect_drain);
    }
}

test "timer completion publication does not free a node before the real backend join" {
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = counter.allocator();
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(1) });
    defer threaded.deinit();
    const io = threaded.io();
    var requests = requests_mod.Requests(TestMsg).init(allocator, io);
    defer requests.deinit();
    var timers = TimerRuntime(TestMsg).init(allocator, io);
    defer timers.shutdown();
    var completions: types.RuntimeCompletionBuffer(TestMsg) = .{};
    try completions.init(allocator);
    defer completions.deinitUndelivered(allocator);
    var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
    var shutdown: std.atomic.Value(bool) = .init(false);
    var barrier: TestBarrier = .{};
    defer barrier.release.set(io);
    var hooks: TestHooks = .{ .after_completed = &barrier };
    timers.test_hooks = &hooks;
    try requests.timer().tick("join-before-free", 0, .replacement, TestMsg.notify);
    try timers.startTicks(&requests, &completions, &loop, &shutdown);
    try waitForTestEvent(&barrier.reached, io);
    const entry = timers.running.items[0];
    try std.testing.expect(entry.completed.load(.acquire));
    try std.testing.expect(entry.future.any_future != null);
    const node_bytes = @sizeOf(@import("../timer_entry.zig").TimerEntry(TestMsg)) + entry.id.len;
    const freed_before = counter.freed_bytes;
    const JoinProbe = struct {
        io: std.Io,
        barrier: *TestBarrier,
        counter: *std.testing.FailingAllocator,
        freed_before: usize,
        called: bool = false,
        live_at_join: bool = false,
        fn await(userdata: ?*anyopaque, future: *std.Io.AnyFuture, result: []u8, alignment: std.mem.Alignment) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.called = true;
            self.live_at_join = self.counter.freed_bytes == self.freed_before;
            // Only the actual Future.await entry releases the real paused worker.
            // Delegate to the original backend before allowing reap to free.
            self.barrier.release.set(self.io);
            self.io.vtable.await(self.io.userdata, future, result, alignment);
        }
    };
    var probe: JoinProbe = .{ .io = io, .barrier = &barrier, .counter = &counter, .freed_before = freed_before };
    var vtable = io.vtable.*;
    vtable.await = JoinProbe.await;
    timers.io = .{ .userdata = &probe, .vtable = &vtable };
    timers.reapCompleted();
    timers.io = io;
    try std.testing.expect(probe.called and probe.live_at_join);
    try std.testing.expectEqual(freed_before + node_bytes, counter.freed_bytes);
    try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
    // Queue payload remains usable after both node and copied ID were freed.
    const notification = (try loop.tryEvent()).?.timer_notification;
    try std.testing.expectEqual(TestMsg.TimerNotice.replacement, notification.message(.fired, allocator).?.fired);
    try std.testing.expect((try loop.tryEvent()).? == .timers_completed);
}
