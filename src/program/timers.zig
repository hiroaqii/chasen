const std = @import("std");
const vaxis = @import("vaxis");
const requests_mod = @import("../requests.zig");
const types = @import("../program_types.zig");
const InternalEvent = types.InternalEvent;

/// Owns each running timer ID together with its Future. Completed one-shot
/// handles remain until replacement, cancellation, or shutdown as before.
pub fn TimerRuntime(comptime Msg: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        running: std.ArrayList(TimerHandle) = .empty,

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{ .allocator = allocator, .io = io };
        }

        pub fn startTicks(self: *Self, requests: *requests_mod.Requests(Msg), loop: *vaxis.Loop(InternalEvent(Msg)), shutting_down: *const std.atomic.Value(bool)) void {
            const allocator = self.allocator;
            const io = self.io;

            // Take ownership of queued copies before processing. Zeroing the queue
            // first keeps Requests cleanup from freeing ids after they have been
            // handed to this owner.
            var pending_ticks = requests.detachTicks();
            defer pending_ticks.deinit();

            while (pending_ticks.next()) |entry| {
                var owned_id: ?[]const u8 = entry.id;
                defer if (owned_id) |id| allocator.free(id);

                // Cancel existing timer with the same id.
                self.cancel(entry.id);

                var future = io.concurrent(
                    TickHelper(Msg).run,
                    .{ entry.after_ns, entry.msg, io, loop, shutting_down },
                ) catch continue;
                self.running.append(allocator, .{ .id = entry.id, .future = future }) catch {
                    _ = future.cancel(io);
                    continue;
                };
                owned_id = null;
            }
        }

        pub fn startEvery(self: *Self, requests: *requests_mod.Requests(Msg), loop: *vaxis.Loop(InternalEvent(Msg)), suspended: *const std.atomic.Value(bool), shutting_down: *const std.atomic.Value(bool)) void {
            const allocator = self.allocator;
            const io = self.io;

            // Take ownership of queued copies before processing. Zeroing the queue
            // first keeps Requests cleanup from freeing ids after they have been
            // handed to this owner.
            var pending_everys = requests.detachEverys();
            defer pending_everys.deinit();

            while (pending_everys.next()) |entry| {
                var owned_id: ?[]const u8 = entry.id;
                defer if (owned_id) |id| allocator.free(id);

                // Cancel existing timer with the same id.
                self.cancel(entry.id);

                var future = io.concurrent(
                    EveryHelper(Msg).run,
                    .{ entry.interval_ns, entry.msg, io, loop, suspended, shutting_down },
                ) catch continue;
                self.running.append(allocator, .{ .id = entry.id, .future = future }) catch {
                    _ = future.cancel(io);
                    continue;
                };
                owned_id = null;
            }
        }

        fn cancel(self: *Self, id: []const u8) void {
            const allocator = self.allocator;
            const io = self.io;

            var i: usize = 0;
            while (i < self.running.items.len) {
                if (std.mem.eql(u8, self.running.items[i].id, id)) {
                    _ = self.running.items[i].future.cancel(io);
                    allocator.free(self.running.items[i].id);
                    _ = self.running.swapRemove(i);
                } else {
                    i += 1;
                }
            }
        }

        pub fn cancelPending(self: *Self, requests: *requests_mod.Requests(Msg)) void {
            const allocator = self.allocator;

            // Take ownership of queued cancel ids before processing so unwind cleanup
            // only sees entries that have not reached the drain step.
            var pending_cancels = requests.detachCancels();
            defer pending_cancels.deinit();

            while (pending_cancels.next()) |id| {
                defer allocator.free(id);
                self.cancel(id);
            }
        }

        pub fn shutdown(self: *Self) void {
            for (self.running.items) |*timer| {
                _ = timer.future.cancel(self.io);
                self.allocator.free(timer.id);
            }
            self.running.deinit(self.allocator);
            self.running = .empty;
        }
    };
}

/// A running timer tracked by id so it can be cancelled.
const TimerHandle = struct {
    id: []const u8,
    future: std.Io.Future(void),
};

/// Sleeps for `after_ns` then posts `msg` once.
fn TickHelper(comptime Msg: type) type {
    const Event = InternalEvent(Msg);
    return struct {
        fn run(
            after_ns: u64,
            msg: Msg,
            tick_io: std.Io,
            loop_ptr: *vaxis.Loop(Event),
            shutting_down: *const std.atomic.Value(bool),
        ) void {
            tick_io.sleep(.fromNanoseconds(@intCast(after_ns)), .awake) catch return;
            types.postPlainUntilShutdown(Msg, .{ .user_msg = msg }, tick_io, loop_ptr, shutting_down);
        }
    };
}

/// Repeating timer: sleeps for `interval_ns`, posts `msg`, and loops forever.
/// Stops when the future is cancelled (sleep returns error).
fn EveryHelper(comptime Msg: type) type {
    const Event = InternalEvent(Msg);
    return struct {
        fn run(
            interval_ns: u64,
            msg: Msg,
            every_io: std.Io,
            loop_ptr: *vaxis.Loop(Event),
            suspended: *const std.atomic.Value(bool),
            shutting_down: *const std.atomic.Value(bool),
        ) void {
            while (!shutting_down.load(.seq_cst)) {
                every_io.sleep(.fromNanoseconds(@intCast(interval_ns)), .awake) catch return;
                if (suspended.load(.seq_cst)) continue;
                types.postPlainUntilShutdown(Msg, .{ .user_msg = msg }, every_io, loop_ptr, shutting_down);
            }
        }
    };
}

const TestMsg = enum {
    old,
    replacement,

    pub const undelivered_policy = .deinit;
    pub fn deinitUndelivered(_: *@This(), _: std.mem.Allocator) void {
        @panic("non-owning timer templates must not invoke the Msg destructor");
    }
};

fn expectReplacement(loop: *vaxis.Loop(InternalEvent(TestMsg)), io: std.Io) !void {
    for (0..2000) |_| {
        if (try loop.tryEvent()) |event| {
            try std.testing.expectEqual(TestMsg.replacement, event.user_msg);
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
                var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
                var suspended: std.atomic.Value(bool) = .init(false);
                var shutting_down: std.atomic.Value(bool) = .init(false);
                if (old_every) {
                    try requests.timer().every("same", 60 * std.time.ns_per_s, .old);
                } else {
                    try requests.timer().tick("same", 60 * std.time.ns_per_s, .old);
                }
                timers.startTicks(&requests, &loop, &shutting_down);
                timers.startEvery(&requests, &loop, &suspended, &shutting_down);
                try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
                if (cancel_first) try requests.timer().cancel("same");
                if (new_every) {
                    try requests.timer().every("same", std.time.ns_per_ms, .replacement);
                } else {
                    try requests.timer().tick("same", 0, .replacement);
                }
                timers.cancelPending(&requests);
                if (cancel_first) try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
                timers.startTicks(&requests, &loop, &shutting_down);
                timers.startEvery(&requests, &loop, &suspended, &shutting_down);
                try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
                try expectReplacement(&loop, io);
                // Completed one-shots are still tracked until explicit cancellation.
                try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
                try requests.timer().cancel("same");
                timers.cancelPending(&requests);
                try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
            }
        }
    }
}

test "timer runtime start and tracking failures release IDs and cancel untracked Futures" {
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
            var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
            var suspended: std.atomic.Value(bool) = .init(false);
            var shutting_down: std.atomic.Value(bool) = .init(false);
            for ([_][]const u8{ "first", "second" }) |id| {
                if (every) {
                    try requests.timer().every(id, 60 * std.time.ns_per_s, .old);
                } else {
                    try requests.timer().tick(id, 60 * std.time.ns_per_s, .old);
                }
            }
            if (fail_tracking) failing.fail_index = failing.alloc_index;
            timers.startTicks(&requests, &loop, &shutting_down);
            timers.startEvery(&requests, &loop, &suspended, &shutting_down);
            try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            try std.testing.expectEqual(@as(usize, 2), failing.deallocations);
            if (fail_tracking) {
                try std.testing.expect(failing.has_induced_failure);
                failing.fail_index = std.math.maxInt(usize);
                try requests.timer().tick("after-failure", 0, .replacement);
                timers.startTicks(&requests, &loop, &shutting_down);
                // The only slot is reusable: every untracked Future was canceled.
                try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
                try expectReplacement(&loop, io);
            }
            timers.shutdown();
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        }
    }
}

test "timer runtime shutdown cancels producers behind a full queue without destroying templates" {
    for ([_]bool{ false, true }) |every| {
        const allocator = std.testing.allocator;
        var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(1) });
        defer threaded.deinit();
        const io = threaded.io();
        var requests = requests_mod.Requests(TestMsg).init(allocator, io);
        defer requests.deinit();
        var timers = TimerRuntime(TestMsg).init(allocator, io);
        defer timers.shutdown();
        var loop = vaxis.Loop(InternalEvent(TestMsg)).init(io, undefined, undefined);
        while (try loop.tryPostEvent(.continue_effect_drain)) {}
        var suspended: std.atomic.Value(bool) = .init(false);
        var shutting_down: std.atomic.Value(bool) = .init(false);
        if (every) {
            try requests.timer().every("full", 0, .old);
        } else {
            try requests.timer().tick("full", 0, .old);
        }
        timers.startTicks(&requests, &loop, &shutting_down);
        timers.startEvery(&requests, &loop, &suspended, &shutting_down);
        try std.testing.expectEqual(@as(usize, 1), timers.running.items.len);
        shutting_down.store(true, .seq_cst);
        timers.shutdown();
        try std.testing.expectEqual(@as(usize, 0), timers.running.items.len);
        while (try loop.tryEvent()) |event| try std.testing.expect(event == .continue_effect_drain);
    }
}
