const std = @import("std");
const vaxis = @import("vaxis");
const ctx_mod = @import("../ctx.zig");
const requests_mod = @import("../requests.zig");
const runtime = @import("../runtime.zig");
const types = @import("../program_types.zig");
const InternalEvent = types.InternalEvent;
const RuntimeCompletionBuffer = types.RuntimeCompletionBuffer;
const TaskRuntime = @import("tasks.zig").TaskRuntime;
const TimerRuntime = @import("timers.zig").TimerRuntime;
const FrameRuntime = @import("frame.zig").FrameRuntime;
const TerminalSession = @import("terminal_session.zig").TerminalSession;
const TerminalEffects = @import("terminal_effects.zig").TerminalEffects;
const terminal_image = @import("../terminal_image.zig");
const foreground_command = @import("../foreground_command.zig");
const applyMsg = @import("events.zig").applyMsg;
const drainInternalEventsForShutdown = @import("terminal_session.zig").drainInternalEventsForShutdown;

const max_effect_drain_rounds: usize = 8;
const EffectDrainResult = struct { needs_render: bool = false };

/// Owns runtime-thread completions and the coalesced continuation wake.
/// Borrows each live owner only for the synchronous drain operation.
pub fn Effects(comptime Msg: type) type {
    return struct {
        const Self = @This();
        completions: RuntimeCompletionBuffer(Msg) = .{},
        continuation_pending: bool = false,

        pub fn init(allocator: std.mem.Allocator) !Self {
            var self: Self = .{};
            try self.completions.init(allocator);
            return self;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            self.completions.deinitUndelivered(allocator);
        }

        pub fn receiveContinuation(self: *Self) void {
            self.continuation_pending = false;
        }

        /// Deliver callbacks created on the runtime thread without routing them back
        /// through the vaxis queue consumed by that same thread.
        ///
        /// The buffer is drained before effect backing arrays are taken for this pass,
        /// so updates may safely queue new effects. Increment `consumed` before calling
        /// update: once dispatch begins, the app owns that message even on error.
        fn applyCompletions(
            self: *Self,
            comptime App: type,
            app: *App,
            app_ctx: *ctx_mod.Ctx(App.Msg),
            stats: *?runtime.RuntimeStats,
            opts: types.RunOptions,
        ) !EffectDrainResult {
            const allocator = app_ctx.allocator();
            const io = app_ctx.io();
            const completions = &self.completions;
            var result: EffectDrainResult = .{};
            var consumed: usize = 0;
            defer {
                for (completions.items.items[consumed..]) |*msg| {
                    runtime.deinitUndeliveredMessage(App.Msg, msg, allocator);
                }
                completions.items.clearRetainingCapacity();
            }

            while (consumed < completions.items.items.len) {
                const msg = completions.items.items[consumed];
                consumed += 1;
                result.needs_render = try applyMsg(App, app, msg, app_ctx, io, stats, opts) or result.needs_render;
            }
            return result;
        }

        fn scheduleContinuation(
            self: *Self,
            loop: *vaxis.Loop(InternalEvent(Msg)),
        ) !void {
            if (self.continuation_pending) return;
            if (try loop.tryPostEvent(.continue_effect_drain)) self.continuation_pending = true;
            // A full queue already guarantees another event-loop iteration. Leave the
            // flag clear so a later bounded pass can enqueue a wake if the queue drains.
        }

        /// Drains effects queued in Ctx using the documented per-pass runtime order:
        ///
        /// 1. runtime-thread completions
        /// 2. foreground commands
        /// 3. terminal clipboard copies
        /// 4. async tasks
        /// 5. pending timer cancels
        /// 6. pending ticks
        /// 7. pending everys
        /// 8. terminal images
        /// 9. frame request
        ///
        /// Timer cancels must run after foreground callbacks have had a chance to
        /// queue effects, but before tick/every spawn. That makes `cancel(id)` apply
        /// to timers that were already running before this drain pass, while allowing
        /// a same-update `cancel(id); tick(id, ...)` restart to keep the replacement.
        ///
        /// Foreground command and clipboard completions may queue follow-up synchronous
        /// terminal effects. Drain a bounded number of full passes so those follow-ups
        /// do not wait for unrelated input/timer/frame events, while preserving the
        /// same per-pass order.
        ///
        /// Trace and stats boundaries stay at the call sites because init, initial
        /// winsize, and main-loop updates account for effect drain differently.
        ///
        /// Always call this as a statement and merge `EffectDrainResult` afterwards.
        /// Placing the call on the right side of short-circuit logic can skip the
        /// effect drain itself.
        pub fn drain(
            self: *Self,
            comptime App: type,
            app: *App,
            app_ctx: *ctx_mod.Ctx(App.Msg),
            tasks: *TaskRuntime(App.Msg),
            timers: *TimerRuntime(App.Msg),
            terminal_effects: *TerminalEffects,
            terminal: *TerminalSession(App.Msg),
            shutting_down: *const std.atomic.Value(bool),
            frames: *FrameRuntime(App.Msg),
            stats: *?runtime.RuntimeStats,
            opts: types.RunOptions,
        ) !EffectDrainResult {
            var result: EffectDrainResult = .{};

            for (0..max_effect_drain_rounds) |round| {
                const completion_result = try self.applyCompletions(App, app, app_ctx, stats, opts);
                result.needs_render = result.needs_render or completion_result.needs_render;
                const foreground_needs_render = try terminal_effects.processForeground(App, app, app_ctx, terminal, stats, opts);
                result.needs_render = result.needs_render or foreground_needs_render;
                const clipboard_needs_render = try terminal_effects.processClipboard(App, app, app_ctx, terminal, stats, opts);
                result.needs_render = result.needs_render or clipboard_needs_render;
                try tasks.startPending(app_ctx.requests, &self.completions, &terminal.loop, shutting_down);
                timers.cancelPending(app_ctx.requests);
                timers.startTicks(app_ctx.requests, &terminal.loop, shutting_down);
                timers.startEvery(app_ctx.requests, &terminal.loop, &terminal.suspended, shutting_down);
                try terminal_effects.processImages(Msg, app_ctx, &self.completions, terminal, opts);
                frames.startRequested(app_ctx.requests, &terminal.loop, &terminal.suspended, shutting_down);

                const has_follow_up = self.completions.items.items.len > 0 or
                    app_ctx.requests.hasPendingForegroundCommands() or
                    app_ctx.requests.hasPendingClipboardCopies();
                if (!has_follow_up) break;
                if (round + 1 == max_effect_drain_rounds) {
                    try self.scheduleContinuation(&terminal.loop);
                }
            }

            return result;
        }
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

test "runtime completion buffer deinitializes unapplied messages" {
    var effects = try Effects(OwnershipTestMsg).init(std.testing.allocator);

    var deinit_count: usize = 0;
    try effects.completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "local-completion"),
        .deinit_count = &deinit_count,
    } });

    effects.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
}

test "task start failure uses runtime completion buffer with full event queue" {
    const TestMsg = union(enum) {
        failed,

        pub const undelivered_policy = .plain;
    };
    const TestApp = struct {
        update_count: usize = 0,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), msg: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            try std.testing.expect(msg == .failed);
            self.update_count += 1;
        }
    };
    const Task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!TestMsg {
            unreachable;
        }

        fn failed(_: ctx_mod.TaskStartError) TestMsg {
            return .failed;
        }
    };
    const Event = InternalEvent(TestMsg);

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    _ = try app_ctx.task().spawn(.{ .run = Task.run, .failed = Task.failed });
    var tasks = TaskRuntime(TestMsg).init(std.testing.failing_allocator, std.testing.io);
    defer tasks.join(app_ctx.requests);
    var effects = try Effects(TestMsg).init(std.testing.allocator);
    defer effects.deinit(std.testing.allocator);
    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    while (try loop.tryPostEvent(.continue_effect_drain)) {}
    var shutting_down: std.atomic.Value(bool) = .init(false);

    try tasks.startPending(app_ctx.requests, &effects.completions, &loop, &shutting_down);
    try std.testing.expectEqual(@as(usize, 0), tasks.pending.items.len);
    try std.testing.expectEqual(@as(usize, 1), effects.completions.items.items.len);

    var app: TestApp = .{};
    var stats: ?runtime.RuntimeStats = null;
    _ = try effects.applyCompletions(
        TestApp,
        &app,
        &app_ctx,
        &stats,
        .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        }, .terminal = undefined },
    );
    try std.testing.expectEqual(@as(usize, 1), app.update_count);

    drainInternalEventsForShutdown(TestMsg, &loop, std.testing.allocator);
}

test "runtime completion follow-up effect runs in next bounded drain round" {
    const TestMsg = union(enum) {
        first,
        second,

        pub const undelivered_policy = .plain;
    };
    const Task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!TestMsg {
            unreachable;
        }

        fn failed(_: ctx_mod.TaskStartError) TestMsg {
            return .second;
        }
    };
    const TestApp = struct {
        update_count: usize = 0,
        skip: bool,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), msg: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            self.update_count += 1;
            switch (msg) {
                .first => {
                    if (self.skip) ctx.redraw().skip();
                    _ = try ctx.task().spawn(.{ .run = Task.run, .failed = Task.failed });
                },
                .second => ctx.redraw().skip(),
            }
        }
    };

    for ([_]bool{ false, true }) |skip| {
        var app: TestApp = .{ .skip = skip };
        var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
        var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
        var tasks = TaskRuntime(TestMsg).init(std.testing.failing_allocator, std.testing.io);
        defer tasks.join(app_ctx.requests);
        var timers = TimerRuntime(TestMsg).init(std.testing.failing_allocator, std.testing.io);
        defer timers.shutdown();
        var effects = try Effects(TestMsg).init(std.testing.allocator);
        defer effects.deinit(std.testing.allocator);
        try effects.completions.append(.first);
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        var terminal: TerminalSession(TestMsg) = undefined;
        try terminal.init(std.testing.allocator, std.testing.io, .{ .env_map = &env });
        defer terminal.deinit();
        var terminal_effects: TerminalEffects = .{};
        defer terminal_effects.deinit(&terminal);
        while (try terminal.loop.tryPostEvent(.continue_effect_drain)) {}
        var shutting_down: std.atomic.Value(bool) = .init(false);
        var frames = FrameRuntime(TestMsg).init(std.testing.io);
        defer frames.shutdown();
        var stats: ?runtime.RuntimeStats = null;

        const result = try effects.drain(
            TestApp,
            &app,
            &app_ctx,
            &tasks,
            &timers,
            &terminal_effects,
            &terminal,
            &shutting_down,
            &frames,
            &stats,
            .{ .runtime = .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
            }, .terminal = .{ .env_map = undefined } },
        );

        try std.testing.expectEqual(!skip, result.needs_render);
        try std.testing.expectEqual(@as(usize, 2), app.update_count);
        try std.testing.expectEqual(@as(usize, 0), effects.completions.items.items.len);
        try std.testing.expectEqual(@as(usize, 0), app_ctx.requests.detachTasks().len);
        drainInternalEventsForShutdown(TestMsg, &terminal.loop, std.testing.allocator);
    }
}

test "terminal image failure callback uses runtime completion buffer" {
    const TestMsg = union(enum) {
        image_loaded: terminal_image.TerminalImageHandle,
        image_failed: terminal_image.LoadError,

        pub const undelivered_policy = .plain;
    };
    const TestApp = struct {
        update_count: usize = 0,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), msg: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            switch (msg) {
                .image_failed => |reason| try std.testing.expect(reason == .unsupported),
                .image_loaded => return error.TestUnexpectedResult,
            }
            self.update_count += 1;
        }
    };
    const Callback = struct {
        fn loaded(_: terminal_image.TerminalImageRequestId, handle: terminal_image.TerminalImageHandle) TestMsg {
            return .{ .image_loaded = handle };
        }

        fn failed(_: terminal_image.TerminalImageRequestId, reason: terminal_image.LoadError) TestMsg {
            return .{ .image_failed = reason };
        }
    };

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    _ = try app_ctx.image().loadPath("missing.png", Callback.loaded, Callback.failed);
    var effects = try Effects(TestMsg).init(std.testing.allocator);
    defer effects.deinit(std.testing.allocator);
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var terminal: TerminalSession(TestMsg) = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, .{ .env_map = &env });
    defer terminal.deinit();
    var terminal_effects: TerminalEffects = .{};
    defer terminal_effects.deinit(&terminal);

    try terminal_effects.processImages(
        TestMsg,
        &app_ctx,
        &effects.completions,
        &terminal,
        .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        }, .terminal = .{ .env_map = undefined } },
    );
    try std.testing.expectEqual(@as(usize, 1), effects.completions.items.items.len);

    var app: TestApp = .{};
    var stats: ?runtime.RuntimeStats = null;
    _ = try effects.applyCompletions(
        TestApp,
        &app,
        &app_ctx,
        &stats,
        .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        }, .terminal = undefined },
    );
    try std.testing.expectEqual(@as(usize, 1), app.update_count);
}

test "runtime completion delivery transfers ownership to update" {
    const TestApp = struct {
        update_count: *usize,

        pub const Msg = OwnershipTestMsg;

        pub fn update(self: *@This(), msg: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            switch (msg) {
                .owned => |owned| {
                    ctx.allocator().free(owned.bytes);
                    self.update_count.* += 1;
                },
            }
        }
    };

    var update_count: usize = 0;
    var deinit_count: usize = 0;
    var app: TestApp = .{ .update_count = &update_count };
    var app_ctx_requests = requests_mod.Requests(OwnershipTestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(OwnershipTestMsg).init(&app_ctx_requests);
    var effects = try Effects(OwnershipTestMsg).init(std.testing.allocator);
    defer effects.deinit(std.testing.allocator);
    try effects.completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "delivered-completion"),
        .deinit_count = &deinit_count,
    } });
    var stats: ?runtime.RuntimeStats = null;

    _ = try effects.applyCompletions(
        TestApp,
        &app,
        &app_ctx,
        &stats,
        .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        }, .terminal = undefined },
    );

    try std.testing.expectEqual(@as(usize, 1), update_count);
    try std.testing.expectEqual(@as(usize, 0), deinit_count);
    try std.testing.expectEqual(@as(usize, 0), effects.completions.items.items.len);
}

test "runtime completion update error remains app-owned" {
    const TestApp = struct {
        retained: ?OwnershipTestPayload = null,

        pub const Msg = OwnershipTestMsg;

        pub fn update(self: *@This(), msg: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            switch (msg) {
                .owned => |owned| self.retained = owned,
            }
            return error.ExpectedUpdateFailure;
        }
    };

    var deinit_count: usize = 0;
    var suffix_deinit_count: usize = 0;
    var app: TestApp = .{};
    defer if (app.retained) |owned| std.testing.allocator.free(owned.bytes);
    var app_ctx_requests = requests_mod.Requests(OwnershipTestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(OwnershipTestMsg).init(&app_ctx_requests);
    var effects = try Effects(OwnershipTestMsg).init(std.testing.allocator);
    defer effects.deinit(std.testing.allocator);
    try effects.completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "update-error-completion"),
        .deinit_count = &deinit_count,
    } });
    try effects.completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "unapplied-suffix"),
        .deinit_count = &suffix_deinit_count,
    } });
    var stats: ?runtime.RuntimeStats = null;

    try std.testing.expectError(
        error.ExpectedUpdateFailure,
        effects.applyCompletions(
            TestApp,
            &app,
            &app_ctx,
            &stats,
            .{ .runtime = .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
            }, .terminal = undefined },
        ),
    );

    try std.testing.expect(app.retained != null);
    try std.testing.expectEqual(@as(usize, 0), deinit_count);
    try std.testing.expectEqual(@as(usize, 1), suffix_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), effects.completions.items.items.len);
}

test "effect coordination preserves stage order and callback admission" {
    const Harness = struct {
        const Stage = enum { completion, foreground, clipboard, task, cancel, tick, every, image, frame };
        const Message = enum {
            completion,
            foreground,
            clipboard,
            noop,
            pub const undelivered_policy = .plain;
        };
        const State = struct {
            requests: *requests_mod.Requests(Message),
            log: [9]Stage = undefined,
            len: usize = 0,
            fn record(self: *@This(), stage: Stage) void {
                std.debug.assert(self.len < self.log.len);
                self.log[self.len] = stage;
                self.len += 1;
            }
        };
        const App = struct {
            pub const Msg = Message;
            state: *State,
            pub fn update(self: *@This(), msg: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
                switch (msg) {
                    .completion => {
                        self.state.record(.completion);
                        _ = try ctx.terminal().runForegroundCommand(.{ .argv = &.{"unused-in-test"}, .finished = foreground });
                    },
                    .foreground => {
                        self.state.record(.foreground);
                        _ = try ctx.terminal().copyToClipboard(.{ .text = "stage", .finished = clipboard });
                    },
                    .clipboard => {
                        self.state.record(.clipboard);
                        _ = try ctx.task().spawnOwned(self.state, .{ .run = taskRun, .failed = taskFailed, .cleanup = taskCleanup });
                        try ctx.timer().cancel("old");
                        try ctx.timer().tick("tick", 100, .noop);
                        try ctx.timer().every("every", 200, .noop);
                        _ = try ctx.image().loadPath("stage.png", imageLoaded, imageFailed);
                        ctx.frame().request();
                    },
                    .noop => {},
                }
            }
            fn foreground(_: foreground_command.ForegroundCommandResult) Msg {
                return .foreground;
            }
            fn clipboard(_: ctx_mod.Ctx(Msg).ClipboardCopyResult) Msg {
                return .clipboard;
            }
            fn taskRun(_: *State, _: std.mem.Allocator, _: std.Io) std.Io.Cancelable!Msg {
                unreachable;
            }
            fn taskFailed(state: *State, _: ctx_mod.TaskStartError, _: std.mem.Allocator) Msg {
                state.record(.task);
                return .noop;
            }
            fn taskCleanup(_: *State, _: std.mem.Allocator) void {}
            fn imageLoaded(_: terminal_image.TerminalImageRequestId, _: terminal_image.TerminalImageHandle) Msg {
                unreachable;
            }
            fn imageFailed(_: terminal_image.TerminalImageRequestId, _: terminal_image.LoadError) Msg {
                return .noop;
            }
        };
        // Exercise the real owners through std.Io's existing admission/cancel seam.
        // No producers start; the old timer's synthetic Future records its join.
        const Admission = struct {
            state: *State,
            frame: bool = false,
            fn concurrent(userdata: ?*anyopaque, _: usize, _: std.mem.Alignment, _: []const u8, _: std.mem.Alignment, _: *const fn (*const anyopaque, *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
                const self: *@This() = @ptrCast(@alignCast(userdata.?));
                const requests = self.state.requests;
                if (self.frame) {
                    self.state.record(.frame);
                } else {
                    // The active stage must detach only its own batch. This
                    // distinguishes tick/every even though both starts fail.
                    std.debug.assert(requests._pending_ticks_len == 0);
                    self.state.record(if (requests._pending_everys_len == 1) .tick else .every);
                }
                return error.ConcurrencyUnavailable;
            }
            fn cancel(userdata: ?*anyopaque, _: *std.Io.AnyFuture, _: []u8, _: std.mem.Alignment) void {
                const self: *@This() = @ptrCast(@alignCast(userdata.?));
                self.state.record(.cancel);
            }
            fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
                return .zero;
            }
        };
        fn imageLoad(userdata: ?*anyopaque, _: *terminal_image.LoaderVaxis, _: *std.Io.Writer, _: std.mem.Allocator, _: []const u8) terminal_image.PathLoadError!terminal_image.LoaderImage {
            const state: *State = @ptrCast(@alignCast(userdata.?));
            state.record(.image);
            return error.Unsupported;
        }
    };
    const allocator = std.testing.allocator;
    const TestMsg = Harness.Message;
    var requests = requests_mod.Requests(TestMsg).init(allocator, std.testing.io);
    defer requests.deinit();
    var ctx = ctx_mod.Ctx(TestMsg).init(&requests);
    var state: Harness.State = .{ .requests = &requests };
    var app: Harness.App = .{ .state = &state };
    var timer_admission: Harness.Admission = .{ .state = &state };
    var frame_admission: Harness.Admission = .{ .state = &state, .frame = true };
    var vtable = std.testing.io.vtable.*;
    vtable.concurrent = Harness.Admission.concurrent;
    vtable.cancel = Harness.Admission.cancel;
    vtable.now = Harness.Admission.now;
    var timers = TimerRuntime(TestMsg).init(allocator, .{ .vtable = &vtable, .userdata = &timer_admission });
    defer timers.shutdown();
    try timers.running.append(allocator, .{
        .id = try allocator.dupe(u8, "old"),
        .future = .{ .any_future = @ptrCast(&timer_admission), .result = {} },
    });
    var frames = FrameRuntime(TestMsg).init(.{ .vtable = &vtable, .userdata = &frame_admission });
    defer frames.shutdown();
    var tasks = TaskRuntime(TestMsg).init(std.testing.failing_allocator, std.testing.io);
    defer tasks.join(&requests);
    var effects = try Effects(TestMsg).init(allocator);
    defer effects.deinit(allocator);
    try effects.completions.append(.completion);
    var env: std.process.Environ.Map = .init(allocator);
    defer env.deinit();
    var terminal: TerminalSession(TestMsg) = undefined;
    try terminal.init(allocator, std.testing.io, .{ .env_map = &env });
    defer terminal.deinit();
    var terminal_effects: TerminalEffects = .{};
    defer terminal_effects.deinit(&terminal);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var stats: ?runtime.RuntimeStats = null;
    _ = try effects.drain(Harness.App, &app, &ctx, &tasks, &timers, &terminal_effects, &terminal, &shutting_down, &frames, &stats, .{
        .runtime = .{ .allocator = allocator, .io = std.testing.io },
        .terminal = .{ .env_map = &env, .image_path_loader = Harness.imageLoad, .image_loader_context = &state },
    });
    try std.testing.expectEqualSlices(Harness.Stage, &.{ .completion, .foreground, .clipboard, .task, .cancel, .tick, .every, .image, .frame }, state.log[0..state.len]);
    try std.testing.expectEqual(@as(usize, 0), effects.completions.items.items.len);
    try std.testing.expect(!effects.continuation_pending);
}

test "effect coordination yields after eight rounds and coalesces wakes on empty or full queue" {
    const App = struct {
        count: usize = 0,
        pub const Msg = enum {
            copied,
            pub const undelivered_policy = .plain;
        };
        fn finished(_: ctx_mod.Ctx(Msg).ClipboardCopyResult) Msg {
            return .copied;
        }
        pub fn update(self: *@This(), _: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            self.count += 1;
            ctx.redraw().skip();
            if (self.count < 17) _ = try ctx.terminal().copyToClipboard(.{ .text = "follow-up", .finished = finished });
        }
    };
    const allocator = std.testing.allocator;
    for ([_]bool{ false, true }) |full_queue| {
        var requests = requests_mod.Requests(App.Msg).init(allocator, std.testing.io);
        defer requests.deinit();
        var ctx = ctx_mod.Ctx(App.Msg).init(&requests);
        _ = try ctx.terminal().copyToClipboard(.{ .text = "first", .finished = App.finished });
        var effects = try Effects(App.Msg).init(allocator);
        defer effects.deinit(allocator);
        var tasks = TaskRuntime(App.Msg).init(allocator, std.testing.io);
        defer tasks.join(&requests);
        var timers = TimerRuntime(App.Msg).init(allocator, std.testing.io);
        defer timers.shutdown();
        var frames = FrameRuntime(App.Msg).init(std.testing.io);
        defer frames.shutdown();
        var env: std.process.Environ.Map = .init(allocator);
        defer env.deinit();
        var terminal: TerminalSession(App.Msg) = undefined;
        try terminal.init(allocator, std.testing.io, .{ .env_map = &env });
        defer terminal.deinit();
        var terminal_effects: TerminalEffects = .{};
        defer terminal_effects.deinit(&terminal);
        if (full_queue) while (try terminal.loop.tryPostEvent(.focus_in)) {};
        var shutting_down: std.atomic.Value(bool) = .init(false);
        var stats: ?runtime.RuntimeStats = null;
        var app: App = .{};
        const opts: types.RunOptions = .{ .runtime = .{ .allocator = allocator, .io = std.testing.io }, .terminal = .{ .env_map = &env } };
        const first = try effects.drain(App, &app, &ctx, &tasks, &timers, &terminal_effects, &terminal, &shutting_down, &frames, &stats, opts);
        try std.testing.expect(!first.needs_render);
        try std.testing.expectEqual(@as(usize, 8), app.count);
        try std.testing.expect(requests.hasPendingClipboardCopies());
        try std.testing.expectEqual(!full_queue, effects.continuation_pending);
        if (full_queue) {
            // Queued input itself guarantees another turn. A subsequent pass
            // can enqueue a wake after this queue drains.
            try std.testing.expect((try terminal.loop.tryEvent()).? == .focus_in);
            drainInternalEventsForShutdown(App.Msg, &terminal.loop, allocator);
        }
        _ = try effects.drain(App, &app, &ctx, &tasks, &timers, &terminal_effects, &terminal, &shutting_down, &frames, &stats, opts);
        try std.testing.expectEqual(@as(usize, 16), app.count);
        try std.testing.expect(effects.continuation_pending);
        try std.testing.expect((try terminal.loop.tryEvent()).? == .continue_effect_drain);
        try std.testing.expectEqual(@as(?InternalEvent(App.Msg), null), try terminal.loop.tryEvent());
        effects.receiveContinuation();
        try std.testing.expect(!effects.continuation_pending);
        _ = try effects.drain(App, &app, &ctx, &tasks, &timers, &terminal_effects, &terminal, &shutting_down, &frames, &stats, opts);
        try std.testing.expectEqual(@as(usize, 17), app.count);
        try std.testing.expect(!requests.hasPendingClipboardCopies());
        try std.testing.expect(!effects.continuation_pending);
        try std.testing.expectEqual(@as(?InternalEvent(App.Msg), null), try terminal.loop.tryEvent());
    }
}
