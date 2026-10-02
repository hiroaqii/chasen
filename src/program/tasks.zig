const std = @import("std");
const vaxis = @import("vaxis");
const ctx_mod = @import("../ctx.zig");
const requests_mod = @import("../requests.zig");
const runtime = @import("../runtime.zig");
const types = @import("../program_types.zig");
const InternalEvent = types.InternalEvent;
const RuntimeCompletionBuffer = types.RuntimeCompletionBuffer;
const delivery_retry_ns: u64 = 100 * std.time.ns_per_us;

/// Owns stable live-task nodes and their supervisor Futures. Keep this owner
/// at its final address from bind until join; workers only retain node pointers.
pub fn TaskRuntime(comptime Msg: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        pending: std.ArrayList(*PendingTask(Msg)) = .empty,

        pub fn init(allocator: std.mem.Allocator, io: std.Io) Self {
            return .{ .allocator = allocator, .io = io };
        }

        pub fn bind(self: *Self, requests: *requests_mod.Requests(Msg)) void {
            std.debug.assert(requests._task_runtime == null);
            requests._task_runtime = .{ .context = self, .request = requestCancel };
        }

        fn requestCancel(context: *anyopaque, id: requests_mod.TaskId, io: std.Io) void {
            const self: *Self = @ptrCast(@alignCast(context));
            for (self.pending.items) |task| {
                if (task.id == id) {
                    task.requestCancel(io);
                    return;
                }
            }
        }

        /// Reap completed supervisors even when no new request is queued.
        /// Each detached entry is consumed by start, failure, or discard.
        pub fn startPending(
            self: *Self,
            requests: *requests_mod.Requests(Msg),
            runtime_completions: *RuntimeCompletionBuffer(Msg),
            loop: *vaxis.Loop(InternalEvent(Msg)),
            shutting_down: *const std.atomic.Value(bool),
        ) !void {
            const allocator = self.allocator;
            const io = self.io;
            self.reap();
            var tasks = requests.detachTasks();
            defer tasks.deinit();
            while (tasks.next()) |task| {
                if (task.canceled or requests.shouldQuit() or shutting_down.load(.acquire)) {
                    task.discard(allocator);
                    continue;
                }
                const pending = PendingTask(Msg).create(allocator, &self.pending) catch |err| {
                    try appendTaskStartFailure(Msg, task, err, runtime_completions, allocator);
                    continue;
                };
                pending.id = task.id;
                pending.future = io.concurrent(PendingTask(Msg).supervise, .{ pending, io }) catch |err| {
                    allocator.destroy(pending);
                    try appendTaskStartFailure(Msg, task, err, runtime_completions, allocator);
                    continue;
                };
                self.pending.appendAssumeCapacity(pending);
                pending.worker = io.concurrent(SpawnHelper(Msg).run, .{ task, allocator, io, loop, shutting_down, pending }) catch |err| {
                    // Publish the no-worker terminal before any fallible processing.
                    // Do not join the supervisor in the ordinary start-failure path.
                    pending.published.set(io);
                    try appendTaskStartFailure(Msg, task, err, runtime_completions, allocator);
                    continue;
                };
                pending.published.set(io);
            }
        }

        fn reap(self: *Self) void {
            var index: usize = 0;
            while (index < self.pending.items.len) {
                if (!self.pending.items[index].completed.load(.acquire)) {
                    index += 1;
                    continue;
                }
                // The helper has finished its work, but the backend may still be
                // storing its return value. Join before reading the result or freeing
                // the stable node that carries the completion flag.
                const task = self.pending.swapRemove(index);
                task.awaitAndDestroy(self.allocator, self.io);
            }
        }

        /// Notify every worker before the coordinator joins any producer.
        pub fn requestShutdown(self: *Self) void {
            for (self.pending.items) |task| task.requestCancel(self.io);
        }

        /// Called after requestShutdown. Only supervisors own worker Futures;
        /// joining them returns undelivered messages to this runtime thread.
        pub fn join(self: *Self, requests: *requests_mod.Requests(Msg)) void {
            for (self.pending.items) |task| task.awaitAndDestroy(self.allocator, self.io);
            self.pending.deinit(self.allocator);
            self.pending = .empty;
            requests._task_runtime = null;
        }
    };
}

fn TaskDelivery(comptime Msg: type) type {
    return union(enum) {
        none,
        posted,
        undelivered: Msg,
    };
}

fn PendingTask(comptime Msg: type) type {
    return struct {
        const Self = @This();

        id: requests_mod.TaskId = undefined,
        future: std.Io.Future(TaskDelivery(Msg)) = undefined,
        worker: ?std.Io.Future(TaskDelivery(Msg)) = null,
        published: std.Io.Event = .unset,
        wake: std.Io.Event = .unset,
        cancel_requested: std.atomic.Value(bool) = .init(false),
        completed: std.atomic.Value(bool) = .init(false),

        fn create(allocator: std.mem.Allocator, pending: *std.ArrayList(*Self)) !*Self {
            try pending.ensureUnusedCapacity(allocator, 1);
            const task = try allocator.create(Self);
            task.* = .{};
            return task;
        }

        fn requestCancel(self: *Self, io: std.Io) void {
            self.cancel_requested.store(true, .release);
            self.wake.set(io);
        }

        fn supervise(self: *Self, io: std.Io) TaskDelivery(Msg) {
            defer self.completed.store(true, .release);
            // Runtime never cancels this supervisor. Publication must happen
            // even after worker admission failure, before runtime can unwind.
            self.published.waitUncancelable(io);
            const worker = if (self.worker) |*worker| worker else return .none;
            self.wake.waitUncancelable(io);
            return if (self.cancel_requested.load(.acquire)) worker.cancel(io) else worker.await(io);
        }

        fn awaitAndDestroy(self: *Self, allocator: std.mem.Allocator, io: std.Io) void {
            var outcome = self.future.await(io);
            switch (outcome) {
                .none, .posted => {},
                .undelivered => |*msg| runtime.deinitUndeliveredMessage(Msg, msg, allocator),
            }
            allocator.destroy(self);
        }
    };
}

/// Transfer one worker-produced message without entering vaxis' blocking push.
///
/// The worker keeps the only owner until `tryPostEvent` succeeds. Shutdown or a
/// queue error returns that owner through the future so the runtime thread can
/// dispose it. This makes `.posted` and `.undelivered` mutually exclusive.
fn transferTaskMessage(
    comptime Msg: type,
    msg: Msg,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    shutting_down: *const std.atomic.Value(bool),
) TaskDelivery(Msg) {
    while (!shutting_down.load(.seq_cst)) {
        const posted = loop.tryPostEvent(.{ .user_msg = msg }) catch {
            return .{ .undelivered = msg };
        };
        if (posted) return .posted;
        io.sleep(.fromNanoseconds(delivery_retry_ns), .awake) catch {
            return .{ .undelivered = msg };
        };
    }
    return .{ .undelivered = msg };
}

/// The consuming entry cleans context before delivery; the supervisor alone
/// owns this worker's Future. Wake only after every worker-side operation.
fn SpawnHelper(comptime Msg: type) type {
    return struct {
        fn run(
            task: requests_mod.Requests(Msg).TaskEntry,
            alloc: std.mem.Allocator,
            spawn_io: std.Io,
            loop_ptr: *vaxis.Loop(InternalEvent(Msg)),
            shutting_down: *const std.atomic.Value(bool),
            pending: *PendingTask(Msg),
        ) TaskDelivery(Msg) {
            defer pending.wake.set(spawn_io);
            const msg = task.run(alloc, spawn_io) catch return .none;
            return transferTaskMessage(Msg, msg, spawn_io, loop_ptr, shutting_down);
        }
    };
}

fn appendTaskStartFailure(
    comptime Msg: type,
    task: requests_mod.Requests(Msg).TaskEntry,
    failure: requests_mod.TaskStartError,
    completions: *RuntimeCompletionBuffer(Msg),
    allocator: std.mem.Allocator,
) !void {
    var msg = task.failed(failure, allocator);
    completions.append(msg) catch |err| {
        runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
        return err;
    };
}

const OwnershipTestPayload = struct {
    bytes: []u8,
    deinit_count: *usize,
    owner_thread: ?std.Thread.Id = null,
};

const OwnershipTestMsg = union(enum) {
    owned: OwnershipTestPayload,

    pub const undelivered_policy = .deinit;

    pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .owned => |owned| {
                if (owned.owner_thread) |thread| std.debug.assert(thread == std.Thread.getCurrentId());
                allocator.free(owned.bytes);
                owned.deinit_count.* += 1;
            },
        }
        self.* = undefined;
    }
};

const ReapingTestTask = struct {
    const Counts = struct {
        runs: std.atomic.Value(usize) = .init(0),
        contexts: std.atomic.Value(usize) = .init(0),
        failures: usize = 0,
        payloads: usize = 0,
    };
    const App = struct {
        pub const Msg = OwnershipTestMsg;
        updates: usize = 0,
        pub fn update(self: *@This(), msg: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            var owned = msg;
            owned.deinitUndelivered(std.testing.allocator);
            self.updates += 1;
        }
    };

    counts: *Counts,
    payload: ?OwnershipTestPayload,
    gate: ?*std.Io.Event = null,
    var plain: *ReapingTestTask = undefined;

    fn create(counts: *Counts) !*ReapingTestTask {
        const self = try std.testing.allocator.create(ReapingTestTask);
        errdefer std.testing.allocator.destroy(self);
        self.* = .{ .counts = counts, .payload = .{
            .bytes = try std.testing.allocator.dupe(u8, "task result"),
            .deinit_count = &counts.payloads,
            .owner_thread = std.Thread.getCurrentId(),
        } };
        return self;
    }

    fn consume(self: *ReapingTestTask) OwnershipTestMsg {
        const msg: OwnershipTestMsg = .{ .owned = self.payload.? };
        self.payload = null;
        return msg;
    }

    fn cleanup(self: *ReapingTestTask, allocator: std.mem.Allocator) void {
        if (self.payload) |payload| allocator.free(payload.bytes);
        _ = self.counts.contexts.fetchAdd(1, .monotonic);
        allocator.destroy(self);
    }

    fn run(self: *ReapingTestTask, _: std.mem.Allocator, io: std.Io) std.Io.Cancelable!OwnershipTestMsg {
        _ = self.counts.runs.fetchAdd(1, .monotonic);
        if (self.gate) |gate| gate.waitUncancelable(io);
        return self.consume();
    }

    fn failed(self: *ReapingTestTask, _: ctx_mod.TaskStartError, _: std.mem.Allocator) OwnershipTestMsg {
        self.counts.failures += 1;
        return self.consume();
    }

    fn plainRun(allocator: std.mem.Allocator, io: std.Io) std.Io.Cancelable!OwnershipTestMsg {
        defer plain.cleanup(allocator);
        return plain.run(allocator, io);
    }

    fn plainFailed(reason: ctx_mod.TaskStartError) OwnershipTestMsg {
        defer plain.cleanup(std.testing.allocator);
        return plain.failed(reason, std.testing.allocator);
    }
};

test "task reclamation bounds repeated plain and owned tasks results including early completion" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Msg = OwnershipTestMsg;
    var ctx_requests = requests_mod.Requests(Msg).init(allocator, io);
    var ctx = ctx_mod.Ctx(Msg).init(&ctx_requests);
    var tasks = TaskRuntime(Msg).init(allocator, io);
    defer tasks.join(ctx.requests);
    try tasks.pending.ensureTotalCapacityPrecise(allocator, 1);
    var completions: RuntimeCompletionBuffer(Msg) = .{};
    try completions.init(allocator);
    defer completions.deinitUndelivered(allocator);
    var loop = vaxis.Loop(InternalEvent(Msg)).init(io, undefined, undefined);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var counts: ReapingTestTask.Counts = .{};
    var app: ReapingTestTask.App = .{};

    // Complete the worker before publishing its Future to the supervisor.
    const early = try PendingTask(Msg).create(allocator, &tasks.pending);
    const task = try ReapingTestTask.create(&counts);
    early.id = try ctx.task().spawnOwned(task, .{ .run = ReapingTestTask.run, .failed = ReapingTestTask.failed, .cleanup = ReapingTestTask.cleanup });
    var batch = ctx.requests.detachTasks();
    defer batch.deinit();
    const entry = batch.next().?;
    early.future = try io.concurrent(PendingTask(Msg).supervise, .{ early, io });
    const future = try io.concurrent(SpawnHelper(Msg).run, .{ entry, allocator, io, &loop, &shutting_down, early });
    early.wake.waitUncancelable(io);
    early.worker = future;
    early.published.set(io);
    tasks.pending.appendAssumeCapacity(early);
    while (!early.completed.load(.acquire)) try std.Thread.yield();

    // The ordinary test stays short; the optional finite soak uses this same
    // production spawn/reap path in one process, without a second test harness.
    const soak = std.testing.environ.getAlloc(allocator, "CHASEN_TASK_SOAK_SECONDS") catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => return err,
    };
    defer if (soak) |value| allocator.free(value);
    const seconds = if (soak) |value| try std.fmt.parseInt(u8, value, 10) else 0;
    if (seconds > 60) return error.InvalidSoakDuration;
    const start = std.Io.Clock.awake.now(io);
    var batches: usize = 0;
    while (batches < 128 or start.durationTo(std.Io.Clock.awake.now(io)).toSeconds() < seconds) : (batches += 1) {
        // Exactly one plain task per batch: its context remains fixed until
        // every worker in the batch has been joined.
        ReapingTestTask.plain = try ReapingTestTask.create(&counts);
        _ = try ctx.task().spawn(.{ .run = ReapingTestTask.plainRun, .failed = ReapingTestTask.plainFailed });
        for (0..3) |_| _ = try ctx.task().spawnOwned(try ReapingTestTask.create(&counts), .{ .run = ReapingTestTask.run, .failed = ReapingTestTask.failed, .cleanup = ReapingTestTask.cleanup });
        try tasks.startPending(ctx.requests, &completions, &loop, &shutting_down);
        try std.testing.expectEqual(@as(usize, 4), tasks.pending.items.len);
        for (tasks.pending.items) |active| while (!active.completed.load(.acquire)) {
            try std.Thread.yield();
        };
        while (try loop.tryEvent()) |event| try app.update(event.user_msg, &ctx);
        // No newly queued tasks: the production effect-drain entry still reaps.
        try tasks.startPending(ctx.requests, &completions, &loop, &shutting_down);
        try std.testing.expectEqual(@as(usize, 0), tasks.pending.items.len);
    }
    try std.testing.expectEqual(@as(usize, 0), counts.failures);
    try std.testing.expectEqual(batches * 4 + 1, counts.runs.load(.monotonic));
    try std.testing.expectEqual(batches * 4 + 1, counts.contexts.load(.monotonic));
    try std.testing.expectEqual(batches * 4 + 1, counts.payloads);
    try std.testing.expectEqual(counts.payloads, app.updates);
    if (seconds > 0) std.debug.print("task soak: tasks={d}, peak_retained=4, final_retained={d}\n", .{ counts.payloads, tasks.pending.items.len });
}

test "task reclamation skips running work and shutdown owns only remaining full-queue results" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Msg = OwnershipTestMsg;
    var ctx_requests = requests_mod.Requests(Msg).init(allocator, io);
    var ctx = ctx_mod.Ctx(Msg).init(&ctx_requests);
    var tasks = TaskRuntime(Msg).init(allocator, io);
    var completions: RuntimeCompletionBuffer(Msg) = .{};
    try completions.init(allocator);
    var loop = vaxis.Loop(InternalEvent(Msg)).init(io, undefined, undefined);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var counts: ReapingTestTask.Counts = .{};
    var gate: std.Io.Event = .unset;
    const slow = try ReapingTestTask.create(&counts);
    slow.gate = &gate;
    _ = try ctx.task().spawnOwned(slow, .{ .run = ReapingTestTask.run, .failed = ReapingTestTask.failed, .cleanup = ReapingTestTask.cleanup });
    for (0..2) |_| _ = try ctx.task().spawnOwned(try ReapingTestTask.create(&counts), .{ .run = ReapingTestTask.run, .failed = ReapingTestTask.failed, .cleanup = ReapingTestTask.cleanup });
    try tasks.startPending(ctx.requests, &completions, &loop, &shutting_down);
    for (tasks.pending.items[1..]) |task| while (!task.completed.load(.acquire)) {
        try std.Thread.yield();
    };
    tasks.reap();
    try std.testing.expectEqual(@as(usize, 1), tasks.pending.items.len);
    try std.testing.expectEqual(@as(usize, 0), counts.payloads);
    var app: ReapingTestTask.App = .{};
    while (try loop.tryEvent()) |event| try app.update(event.user_msg, &ctx);
    try std.testing.expectEqual(@as(usize, 2), app.updates);
    while (try loop.tryPostEvent(.continue_effect_drain)) {}
    shutting_down.store(true, .seq_cst);
    gate.set(io);
    tasks.requestShutdown();
    tasks.join(ctx.requests);
    drainTestQueue(Msg, &loop, allocator);
    completions.deinitUndelivered(allocator);
    try std.testing.expectEqual(@as(usize, 0), tasks.pending.items.len);
    try std.testing.expectEqual(@as(usize, 3), counts.payloads);
    try std.testing.expectEqual(@as(usize, 3), counts.contexts.load(.monotonic));
}

test "task reclamation start failures consume context and payload once" {
    const Failure = enum { list_allocation, node_allocation, supervisor_start, worker_start };
    for (std.enums.values(Failure)) |failure| {
        for ([_]bool{ false, true }) |with_context| {
            const allocator = std.testing.allocator;
            var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = switch (failure) {
                .list_allocation => 0,
                .node_allocation => 1,
                .supervisor_start, .worker_start => std.math.maxInt(usize),
            } });
            const task_allocator = failing.allocator();
            var threaded: std.Io.Threaded = .init(allocator, .{ .concurrent_limit = .limited(if (failure == .worker_start) 1 else 0) });
            defer threaded.deinit();
            const io = threaded.io();
            const Msg = OwnershipTestMsg;
            var ctx_requests = requests_mod.Requests(Msg).init(allocator, io);
            var ctx = ctx_mod.Ctx(Msg).init(&ctx_requests);
            var tasks = TaskRuntime(Msg).init(task_allocator, io);
            defer tasks.join(ctx.requests);
            var completions: RuntimeCompletionBuffer(Msg) = .{};
            try completions.init(allocator);
            defer completions.deinitUndelivered(allocator);
            var loop = vaxis.Loop(InternalEvent(Msg)).init(io, undefined, undefined);
            var shutting_down: std.atomic.Value(bool) = .init(false);
            var counts: ReapingTestTask.Counts = .{};
            const task = try ReapingTestTask.create(&counts);
            if (with_context) {
                _ = try ctx.task().spawnOwned(task, .{ .run = ReapingTestTask.run, .failed = ReapingTestTask.failed, .cleanup = ReapingTestTask.cleanup });
            } else {
                ReapingTestTask.plain = task;
                _ = try ctx.task().spawn(.{ .run = ReapingTestTask.plainRun, .failed = ReapingTestTask.plainFailed });
            }
            try tasks.startPending(ctx.requests, &completions, &loop, &shutting_down);
            for (tasks.pending.items) |active| while (!active.completed.load(.acquire)) {
                try std.Thread.yield();
            };
            tasks.reap();
            try std.testing.expectEqual(@as(usize, 0), tasks.pending.items.len);
            try std.testing.expectEqual(@as(usize, 0), counts.runs.load(.monotonic));
            try std.testing.expectEqual(@as(usize, 1), counts.contexts.load(.monotonic));
            try std.testing.expectEqual(@as(usize, 1), counts.failures);
            try std.testing.expectEqual(@as(usize, 1), completions.items.items.len);
            completions.deinitUndelivered(allocator);
            try std.testing.expectEqual(@as(usize, 1), counts.payloads);
        }
    }
}

test "task cancel and completion races preserve moved results on runtime including full queue" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Msg = OwnershipTestMsg;
    var ctx_requests = requests_mod.Requests(Msg).init(allocator, io);
    var ctx = ctx_mod.Ctx(Msg).init(&ctx_requests);
    var tasks = TaskRuntime(Msg).init(allocator, io);
    defer tasks.join(ctx.requests);
    tasks.bind(ctx.requests);
    var completions: RuntimeCompletionBuffer(Msg) = .{};
    try completions.init(allocator);
    defer completions.deinitUndelivered(allocator);
    var loop = vaxis.Loop(InternalEvent(Msg)).init(io, undefined, undefined);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var counts: ReapingTestTask.Counts = .{};
    for (0..128) |i| {
        const full = i % 3 == 0;
        if (full) while (try loop.tryPostEvent(.continue_effect_drain)) {};
        const task = try ReapingTestTask.create(&counts);
        const id = try ctx.task().spawnOwned(task, .{ .run = ReapingTestTask.run, .failed = ReapingTestTask.failed, .cleanup = ReapingTestTask.cleanup });
        try tasks.startPending(ctx.requests, &completions, &loop, &shutting_down);
        if (i % 3 == 1) while (!tasks.pending.items[0].completed.load(.acquire)) {
            try std.Thread.yield();
        };
        ctx.task().requestCancel(id);
        while (!tasks.pending.items[0].completed.load(.acquire)) try std.Thread.yield();
        tasks.reap();
        if (full) try std.testing.expectEqual(i + 1, counts.payloads);
        drainTestQueue(Msg, &loop, allocator);
        try std.testing.expectEqual(i + 1, counts.payloads);
        try std.testing.expectEqual(i + 1, counts.contexts.load(.acquire));
        ctx.task().requestCancel(id); // absent after reaping
    }
}

test "task failure completion overflow discards all remaining taken contexts" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const Msg = OwnershipTestMsg;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var ctx_requests = requests_mod.Requests(Msg).init(allocator, io);
    var ctx = ctx_mod.Ctx(Msg).init(&ctx_requests);
    var tasks = TaskRuntime(Msg).init(failing.allocator(), io);
    defer tasks.join(ctx.requests);
    var completions: RuntimeCompletionBuffer(Msg) = .{};
    try completions.init(allocator);
    defer completions.deinitUndelivered(allocator);
    var buffer_payloads: usize = 0;
    for (0..RuntimeCompletionBuffer(Msg).capacity) |_| try completions.append(.{ .owned = .{
        .bytes = try allocator.dupe(u8, "already buffered"),
        .deinit_count = &buffer_payloads,
    } });
    var counts: ReapingTestTask.Counts = .{};
    for (0..3) |_| _ = try ctx.task().spawnOwned(try ReapingTestTask.create(&counts), .{
        .run = ReapingTestTask.run,
        .failed = ReapingTestTask.failed,
        .cleanup = ReapingTestTask.cleanup,
    });
    var loop = vaxis.Loop(InternalEvent(Msg)).init(io, undefined, undefined);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    try std.testing.expectError(error.RuntimeCompletionLimitExceeded, tasks.startPending(ctx.requests, &completions, &loop, &shutting_down));
    try std.testing.expectEqual(@as(usize, 3), counts.contexts.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), counts.failures);
    try std.testing.expectEqual(@as(usize, 1), counts.payloads);
    try std.testing.expectEqual(@as(usize, 0), counts.runs.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), ctx.requests.detachTasks().len);
}

test "task delivery returns undelivered message after shutdown barrier" {
    var deinit_count: usize = 0;
    const bytes = try std.testing.allocator.dupe(u8, "task-result");
    var shutting_down: std.atomic.Value(bool) = .init(true);

    // With the barrier already raised, transfer does not touch the event loop
    // or Io and must return the sole message owner to the runtime thread.
    const outcome = transferTaskMessage(
        OwnershipTestMsg,
        .{ .owned = .{ .bytes = bytes, .deinit_count = &deinit_count } },
        undefined,
        undefined,
        &shutting_down,
    );
    switch (outcome) {
        .none, .posted => return error.TestUnexpectedResult,
        .undelivered => |value| {
            var msg = value;
            runtime.deinitUndeliveredMessage(OwnershipTestMsg, &msg, std.testing.allocator);
        },
    }
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "task delivery transfers posted message to queue exactly once" {
    const Event = InternalEvent(OwnershipTestMsg);
    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    var deinit_count: usize = 0;
    var shutting_down: std.atomic.Value(bool) = .init(false);

    const outcome = transferTaskMessage(
        OwnershipTestMsg,
        .{ .owned = .{
            .bytes = try std.testing.allocator.dupe(u8, "posted-result"),
            .deinit_count = &deinit_count,
        } },
        std.testing.io,
        &loop,
        &shutting_down,
    );
    try std.testing.expect(outcome == .posted);

    shutting_down.store(true, .seq_cst);
    drainTestQueue(OwnershipTestMsg, &loop, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "task delivery escapes full queue when shutdown begins" {
    const Event = InternalEvent(OwnershipTestMsg);
    const Transfer = struct {
        fn run(
            msg: OwnershipTestMsg,
            io: std.Io,
            loop: *vaxis.Loop(Event),
            shutting_down: *const std.atomic.Value(bool),
        ) TaskDelivery(OwnershipTestMsg) {
            return transferTaskMessage(OwnershipTestMsg, msg, io, loop, shutting_down);
        }
    };

    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    var queued: usize = 0;
    while (try loop.tryPostEvent(.continue_effect_drain)) queued += 1;
    try std.testing.expect(queued > 0);

    var deinit_count: usize = 0;
    const bytes = try std.testing.allocator.dupe(u8, "blocked-result");
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var future = try std.testing.io.concurrent(Transfer.run, .{
        OwnershipTestMsg{ .owned = .{ .bytes = bytes, .deinit_count = &deinit_count } },
        std.testing.io,
        &loop,
        &shutting_down,
    });

    // The producer may already be retrying or may start after this store. In
    // either case it must return the message instead of blocking on queue push.
    shutting_down.store(true, .seq_cst);
    var outcome = future.await(std.testing.io);
    switch (outcome) {
        .none, .posted => return error.TestUnexpectedResult,
        .undelivered => |*msg| runtime.deinitUndeliveredMessage(OwnershipTestMsg, msg, std.testing.allocator),
    }
    try std.testing.expectEqual(@as(usize, 1), deinit_count);

    drainTestQueue(OwnershipTestMsg, &loop, std.testing.allocator);
}

test "task pending cancel quit and unwind discard contexts without failure messages" {
    const Capture = struct {
        bytes: []u8,
        cleanups: *usize,
        fn run(_: *@This(), _: std.mem.Allocator, _: std.Io) std.Io.Cancelable!OwnershipTestMsg {
            unreachable;
        }
        fn failed(_: *@This(), _: ctx_mod.TaskStartError, _: std.mem.Allocator) OwnershipTestMsg {
            unreachable;
        }
        fn cleanup(self: *@This(), allocator: std.mem.Allocator) void {
            self.cleanups.* += 1;
            allocator.free(self.bytes);
            allocator.destroy(self);
        }
    };
    const Terminal = enum { cancel, quit, unwind };
    for (std.enums.values(Terminal)) |terminal| {
        var cleanups: usize = 0;
        const capture = try std.testing.allocator.create(Capture);
        capture.* = .{ .bytes = try std.testing.allocator.dupe(u8, "pending context"), .cleanups = &cleanups };
        var ctx_requests = requests_mod.Requests(OwnershipTestMsg).init(std.testing.allocator, std.testing.io);
        var ctx = ctx_mod.Ctx(OwnershipTestMsg).init(&ctx_requests);
        const id = try ctx.task().spawnOwned(capture, .{ .run = Capture.run, .failed = Capture.failed, .cleanup = Capture.cleanup });
        if (terminal == .unwind) {
            ctx.requests.discardPendingTasks();
        } else {
            if (terminal == .quit) ctx.quit() else ctx.task().requestCancel(id);
            var tasks = TaskRuntime(OwnershipTestMsg).init(std.testing.allocator, std.testing.io);
            defer tasks.join(ctx.requests);
            var completions: RuntimeCompletionBuffer(OwnershipTestMsg) = .{};
            try completions.init(std.testing.allocator);
            defer completions.deinitUndelivered(std.testing.allocator);
            var loop = vaxis.Loop(InternalEvent(OwnershipTestMsg)).init(std.testing.io, undefined, undefined);
            var shutting_down: std.atomic.Value(bool) = .init(false);
            try tasks.startPending(ctx.requests, &completions, &loop, &shutting_down);
            try std.testing.expectEqual(@as(usize, 0), tasks.pending.items.len);
            try std.testing.expectEqual(@as(usize, 0), completions.items.items.len);
        }
        try std.testing.expectEqual(@as(usize, 1), cleanups);
        try std.testing.expectEqual(@as(usize, 0), ctx.requests.detachTasks().len);
    }
}

test "SpawnHelper instantiation" {
    const TestMsg = union(enum) { hello };
    const Helper = SpawnHelper(TestMsg);
    // Verify the run function has the expected type signature
    const RunFn = @TypeOf(Helper.run);
    try std.testing.expect(RunFn != void);
}

fn drainTestQueue(
    comptime Msg: type,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    allocator: std.mem.Allocator,
) void {
    while (loop.tryEvent() catch null) |event| {
        switch (event) {
            .user_msg => |value| {
                var msg = value;
                runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
            },
            else => {},
        }
    }
}
