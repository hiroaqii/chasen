const std = @import("std");
const vaxis = @import("vaxis");
const requests_mod = @import("../requests.zig");
const runtime = @import("../runtime.zig");
const types = @import("../program_types.zig");
const InternalEvent = types.InternalEvent;

/// Owns stable nodes after starting their workers. Completed one-shots remain
/// tracked until cancel/replacement/shutdown.
pub fn TimerRuntime(comptime Msg: type) type {
    return struct {
        const Self = @This();
        const Entry = @import("../timer_entry.zig").TimerEntry(Msg);
        allocator: std.mem.Allocator,
        io: std.Io,
        running: std.ArrayList(*Entry) = .empty,

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
            const future = self.io.concurrent(run, .{ entry, repeating, self.io, loop, suspended, shutting_down }) catch {
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

        fn run(entry: *const Entry, repeating: bool, io: std.Io, loop: *vaxis.Loop(InternalEvent(Msg)), suspended: ?*const std.atomic.Value(bool), shutting_down: *const std.atomic.Value(bool)) void {
            // u64 -> i96 is a widening conversion; even maxInt(u64) is valid.
            while (!shutting_down.load(.seq_cst)) {
                io.sleep(.fromNanoseconds(entry.duration_ns), .awake) catch return;
                if (repeating and suspended.?.load(.seq_cst)) continue;
                types.postPlainUntilShutdown(Msg, .{ .timer_notification = entry.notification }, io, loop, shutting_down);
                if (!repeating) return;
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
                // Completed one-shots are still tracked until explicit cancellation.
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
        while (try loop.tryEvent()) |event| try std.testing.expect(event == .continue_effect_drain);
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
