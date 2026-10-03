const std = @import("std");
const chasen = @import("chasen");

test "timer public Borrowed preserves explicit reference types and identity" {
    inline for (.{ []const u8, [:0]const u8, *const u64, *u64, *const [4:0]u8 }) |Ref| {
        const B = chasen.Borrowed(Ref);
        try std.testing.expect(B == chasen.runtime.Borrowed(Ref));
        try std.testing.expectEqual(@sizeOf(Ref), @sizeOf(B));
        try std.testing.expectEqual(@alignOf(Ref), @alignOf(B));
    }
    const text = chasen.Borrowed([]const u8).init("text");
    const sentinel = chasen.Borrowed([:0]const u8).init("text");
    try std.testing.expectEqualStrings("text", text.value);
    try std.testing.expectEqual(@as(u8, 0), sentinel.value[sentinel.value.len]);
    var count: u64 = 1;
    const borrow = chasen.Borrowed(*u64).init(&count);
    const copied = borrow;
    copied.value.* += 1;
    try std.testing.expectEqual(@as(u64, 2), count);
    try std.testing.expect(borrow.value == copied.value);
}

test "timer public vocabulary coexists with owned root messages" {
    const Msg = union(enum) {
        owned: []u8,
        unavailable: chasen.TimerStartError,

        pub const TimerNotice = struct { generation: u64, label: chasen.Borrowed([]const u8) };
        pub const undelivered_policy = .deinit;

        pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .owned => |bytes| allocator.free(bytes),
                .unavailable => {},
            }
        }
    };
    comptime chasen.runtime.validateUndeliveredPolicy(Msg);
    try std.testing.expect(chasen.TimerOutcome == chasen.runtime.TimerOutcome);
    try std.testing.expect(chasen.TimerStartError == chasen.runtime.TimerStartError);
    const notice: Msg.TimerNotice = .{ .generation = 7, .label = chasen.Borrowed([]const u8).init("tick") };
    try std.testing.expectEqualStrings("tick", notice.label.value);
    const fired: chasen.TimerOutcome = .fired;
    try std.testing.expect(fired == .fired);
    inline for (.{ error.OutOfMemory, error.ConcurrencyUnavailable }) |err| {
        const outcome: chasen.TimerOutcome = .{ .failed = err };
        try std.testing.expectEqual(err, outcome.failed);
    }
    var msg: Msg = .{ .owned = try std.testing.allocator.dupe(u8, "owned result") };
    chasen.runtime.deinitUndeliveredMessage(Msg, &msg, std.testing.allocator);
}

test "timer admission validates before mutation and reuses pending storage" {
    const Msg = enum {
        unused,
        pub const TimerNotice = u64;
        fn notify(_: u64, _: chasen.TimerOutcome, _: std.mem.Allocator) ?@This() {
            return null;
        }
    };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var tc: chasen.testing.TestCtx(Msg) = undefined;
    tc.init(failing.allocator(), std.testing.io);
    defer tc.deinit();
    try tc.ctx.timer().every("same", 10, 1, Msg.notify);
    try tc.ctx.timer().tick("same", 0, 2, Msg.notify);
    const every_id = tc.everyAt(0).?.id.ptr;
    const tick_id = tc.tickAt(0).?.id.ptr;
    const allocations = failing.allocations;
    failing.fail_index = failing.alloc_index;
    for (0..64) |generation| {
        try tc.ctx.timer().every("same", 20, generation, Msg.notify);
        try tc.ctx.timer().tick("same", 0, generation, Msg.notify);
    }
    try std.testing.expectEqual(allocations, failing.allocations);
    try std.testing.expectEqual(every_id, tc.everyAt(0).?.id.ptr);
    try std.testing.expectEqual(tick_id, tc.tickAt(0).?.id.ptr);
    try std.testing.expectError(error.InvalidInterval, tc.ctx.timer().every("same", 0, 999, Msg.notify));
    try std.testing.expectError(error.InvalidInterval, tc.ctx.timer().every("new", 0, 999, Msg.notify));
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 63), tc.everyAt(0).?.notice);
    try std.testing.expectEqual(@as(u64, 20), tc.everyAt(0).?.interval_ns);
    try std.testing.expectError(error.OutOfMemory, tc.ctx.timer().cancel("same"));
    try std.testing.expectEqual(@as(usize, 1), tc.pendingTickCount());
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
    try std.testing.expectEqual(@as(u64, 63), tc.tickAt(0).?.notice);
}

test "timer public driver binds real start failures to notices before any firing" {
    const Msg = union(enum) {
        fired: u64,
        failed: struct { generation: u64, err: chasen.TimerStartError },
        pub const TimerNotice = u64;
        pub const undelivered_policy = .plain;
        fn notify(generation: u64, outcome: chasen.TimerOutcome, _: std.mem.Allocator) ?@This() {
            return switch (outcome) {
                .fired => .{ .fired = generation },
                .failed => |err| .{ .failed = .{ .generation = generation, .err = err } },
            };
        }
    };
    for ([_]bool{ false, true }) |fail_tracking| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(if (fail_tracking) 1 else 0) });
        defer threaded.deinit();
        var tc: chasen.testing.TestCtx(Msg) = undefined;
        tc.init(failing.allocator(), threaded.io());
        defer tc.deinit();
        var driver: chasen.testing.TimerDriver(Msg) = undefined;
        try driver.init(&tc);
        defer driver.deinit();
        // Zero delay would expose a worker-before-tracking race immediately.
        try tc.ctx.timer().tick("tick", 0, 11, Msg.notify);
        try tc.ctx.timer().every("every", 1, 22, Msg.notify);
        if (fail_tracking) failing.fail_index = failing.alloc_index;
        try driver.drain();
        for ([_]u64{ 11, 22 }) |generation| {
            const msg = (try driver.nextMessage()).?;
            try std.testing.expectEqual(generation, msg.failed.generation);
            try std.testing.expectEqual(if (fail_tracking) error.OutOfMemory else error.ConcurrencyUnavailable, msg.failed.err);
        }
        try std.testing.expect((try driver.nextMessage()) == null);
        try std.testing.expectEqual(@as(usize, 0), driver.timers.running.items.len);
        if (fail_tracking) try std.testing.expect(failing.has_induced_failure);
    }
}

test "timer public driver creates owned messages on runtime thread and drops queued notices without callbacks" {
    const Evidence = struct { calls: usize = 0, drops: usize = 0, thread: std.Thread.Id };
    const Msg = struct {
        bytes: []u8,
        generation: u64,
        evidence: *Evidence,
        pub const TimerNotice = struct { generation: u64, evidence: chasen.Borrowed(*Evidence) };
        pub const undelivered_policy = .deinit;
        pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
            std.debug.assert(self.evidence.thread == std.Thread.getCurrentId());
            self.evidence.drops += 1;
            allocator.free(self.bytes);
        }
        fn notify(notice: TimerNotice, outcome: chasen.TimerOutcome, allocator: std.mem.Allocator) ?@This() {
            const evidence = notice.evidence.value;
            std.debug.assert(evidence.thread == std.Thread.getCurrentId());
            evidence.calls += 1;
            const bytes = allocator.dupe(u8, switch (outcome) {
                .fired => "fired",
                .failed => "failed",
            }) catch return null;
            return .{ .bytes = bytes, .generation = notice.generation, .evidence = evidence };
        }
    };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(2) });
    defer threaded.deinit();
    const io = threaded.io();
    var tc: chasen.testing.TestCtx(Msg) = undefined;
    tc.init(std.testing.allocator, io);
    defer tc.deinit();
    var driver: chasen.testing.TimerDriver(Msg) = undefined;
    try driver.init(&tc);
    var driver_live = true;
    defer if (driver_live) driver.deinit();
    var evidence: Evidence = .{ .thread = std.Thread.getCurrentId() };
    for (0..2) |generation| {
        try tc.ctx.timer().tick("same", 0, .{ .generation = generation, .evidence = .init(&evidence) }, Msg.notify);
        try driver.drain();
        // Observe actual worker delivery before invoking any callback. Requeue
        // that exact value for the production driver/shutdown consumer.
        for (0..2000) |_| {
            if (try driver.loop.tryEvent()) |event| {
                try std.testing.expect(event == .timer_notification);
                try std.testing.expectEqual(generation, evidence.calls);
                try std.testing.expect(try driver.loop.tryPostEvent(event));
                break;
            }
            try io.sleep(.fromMilliseconds(1), .awake);
        } else return error.TimerDeliveryTimedOut;
        if (generation == 0) {
            var msg = (try driver.nextMessage()).?;
            try std.testing.expectEqual(@as(u64, 0), msg.generation);
            try std.testing.expectEqualStrings("fired", msg.bytes);
            tc.discardMessage(&msg);
        } else {
            driver.deinit();
            driver_live = false;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), evidence.calls);
    try std.testing.expectEqual(@as(usize, 1), evidence.drops);
}

test "timer failure callback can explicitly return null while quit skips new starts" {
    const Msg = enum {
        unused,
        pub const TimerNotice = chasen.Borrowed(*usize);
        pub const undelivered_policy = .plain;
        fn notify(count: TimerNotice, outcome: chasen.TimerOutcome, _: std.mem.Allocator) ?@This() {
            std.debug.assert(outcome == .failed);
            count.value.* += 1;
            return null;
        }
    };
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{ .concurrent_limit = .limited(0) });
    defer threaded.deinit();
    var tc: chasen.testing.TestCtx(Msg) = undefined;
    tc.init(std.testing.allocator, threaded.io());
    defer tc.deinit();
    var driver: chasen.testing.TimerDriver(Msg) = undefined;
    try driver.init(&tc);
    defer driver.deinit();
    var calls: usize = 0;
    try tc.ctx.timer().tick("first", 0, .init(&calls), Msg.notify);
    try driver.drain();
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect((try driver.nextMessage()) == null);
    try tc.ctx.timer().tick("quit-tick", 0, .init(&calls), Msg.notify);
    try tc.ctx.timer().every("quit-every", 1, .init(&calls), Msg.notify);
    tc.ctx.quit();
    try driver.drain();
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTickCount() + tc.pendingEveryCount());
}
