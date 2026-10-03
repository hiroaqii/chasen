const std = @import("std");
const vaxis = @import("vaxis");
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const ctx_mod = @import("ctx.zig");
const requests_mod = @import("requests.zig");
const runtime = @import("runtime.zig");
const types = @import("program_types.zig");
const InternalEvent = types.InternalEvent;
const effects_mod = @import("program/effects.zig");
const Effects = effects_mod.Effects;
const TaskRuntime = @import("program/tasks.zig").TaskRuntime;
const TimerRuntime = @import("program/timers.zig").TimerRuntime;
const frame_mod = @import("program/frame.zig");
const FrameRuntime = frame_mod.FrameRuntime;
const events_mod = @import("program/events.zig");
const Events = events_mod.Events;
const dispatchAppEvent = events_mod.dispatchAppEvent;
const applyMsg = events_mod.applyMsg;
const timingStart = types.timingStart;
const timingElapsed = types.timingElapsed;
const trace = types.trace;
const terminal_image = @import("terminal_image.zig");
const terminal_session = @import("program/terminal_session.zig");
const TerminalSession = terminal_session.TerminalSession;
const terminal_effects_mod = @import("program/terminal_effects.zig");
const TerminalEffects = terminal_effects_mod.TerminalEffects;
const drainInternalEventsForShutdown = terminal_session.drainInternalEventsForShutdown;
const discardQueuedForegroundCommands = terminal_effects_mod.discardQueuedForegroundCommands;

const RenderTimings = struct {
    view_ns: u64 = 0,
    render_ns: u64 = 0,
};

const Renderer = struct {
    arena: std.heap.ArenaAllocator,

    fn init(allocator: std.mem.Allocator) Renderer {
        return .{ .arena = .init(allocator) };
    }

    fn deinit(self: *Renderer) void {
        self.arena.deinit();
    }

    fn render(
        self: *Renderer,
        comptime App: type,
        vx: *vaxis.Vaxis,
        terminal_images: *terminal_image.Registry,
        app: *const App,
        writer: *std.Io.Writer,
        io: std.Io,
        measure: bool,
        opts: types.RunOptions,
    ) !RenderTimings {
        // Reuse frame scratch capacity across renders to avoid per-frame allocator churn.
        _ = self.arena.reset(.retain_capacity);

        const win = vx.window();
        win.clear();

        var sfc: Surface = .initVaxis(win, self.arena.allocator(), terminal_images);

        trace(opts, .view_start);
        const view_start = timingStart(measure, io);
        try app.view(&sfc);
        const view_ns = if (measure) timingElapsed(view_start, io) else 0;
        trace(opts, .view_end);

        trace(opts, .render_start);
        const render_start = timingStart(measure, io);
        try vx.render(writer);
        const render_ns = if (measure) timingElapsed(render_start, io) else 0;
        trace(opts, .render_end);

        return .{
            .view_ns = view_ns,
            .render_ns = render_ns,
        };
    }
};

pub fn run(comptime App: type, opts: types.RunOptions, initial_app: App) !void {
    const Msg = App.Msg;
    const allocator = opts.runtime.allocator;
    const io = opts.runtime.io;

    var terminal: TerminalSession(Msg) = undefined;
    try terminal.init(allocator, io, opts.terminal);
    defer terminal.deinit();
    var terminal_effects: TerminalEffects = .{};
    defer terminal_effects.deinit(&terminal);
    try terminal.start();
    defer terminal.stopInput();

    // --- Frame arena ---
    var renderer = Renderer.init(allocator);
    defer renderer.deinit();

    // --- App state ---
    var app = initial_app;
    defer {
        if (@hasDecl(App, "deinit")) {
            app.deinit(.{
                .allocator = allocator,
                .io = io,
            });
        }
    }
    // Keep the request owner in stable storage for the borrowed app facade.
    var app_ctx_requests = requests_mod.Requests(Msg).init(allocator, io);
    defer app_ctx_requests.deinit();
    var app_ctx = ctx_mod.Ctx(Msg).init(&app_ctx_requests);
    var frames = FrameRuntime(Msg).init(io);
    var runtime_shutting_down: std.atomic.Value(bool) = .init(false);
    var events = Events.init(allocator);
    defer events.deinit();
    var event_count: u64 = 0;
    var frame_count: u64 = 0;
    const stats_enabled = opts.runtime.stats_fn != null;

    // Bind the live-task owner only after its final stack placement.
    var tasks = TaskRuntime(Msg).init(allocator, io);

    var timers = TimerRuntime(Msg).init(allocator, io);
    var effects = try Effects(Msg).init(allocator);
    tasks.bind(app_ctx.requests);

    // This defer runs before App.deinit and before the remaining terminal
    // resource defers. It is the single owner of started task outcomes,
    // queued-but-unstarted task contexts, and undelivered queue messages.
    defer shutdownRuntime(
        App,
        &app_ctx,
        &tasks,
        &timers,
        &effects,
        &frames,
        &terminal,
        allocator,
        &runtime_shutting_down,
    );

    // Preserve the shutdown order: mask, polling join, producer barrier.
    defer terminal.stopResizePolling();
    defer terminal.beginTeardown();

    trace(opts, .startup);

    if (@hasDecl(App, "init")) {
        try app.init(&app_ctx);
        // Process tasks, ticks, and everys spawned during init
        trace(opts, .effect_drain_start);
        var init_stats: ?runtime.RuntimeStats = null;
        _ = try effects.drain(App, &app, &app_ctx, &tasks, &timers, &terminal_effects, &terminal, &runtime_shutting_down, &frames, &init_stats, opts);
        trace(opts, .effect_drain_end);
    }

    // Deliver the initial terminal size before the first render. Resize events
    // only arrive after the terminal changes, but apps often need the current
    // size for first-frame layout and scroll bounds.
    if (terminal.getWinsize()) |ws| {
        terminal.seedResize(ws);
        var initial_stats: ?runtime.RuntimeStats = null;
        // Keep the vaxis screen size in sync before the first render. The app
        // also receives the winsize event below to initialize layout state.
        try terminal.resize(ws);
        trace(opts, .event_received);
        _ = try dispatchAppEvent(App, &app, .{ .winsize = ws }, &app_ctx, io, &initial_stats, opts);
        trace(opts, .effect_drain_start);
        _ = try effects.drain(App, &app, &app_ctx, &tasks, &timers, &terminal_effects, &terminal, &runtime_shutting_down, &frames, &initial_stats, opts);
        trace(opts, .effect_drain_end);
    } else |_| {}

    // Initial render
    _ = try renderer.render(App, &terminal.vx, &terminal_effects.images, &app, terminal.writer(), io, false, opts);

    try terminal.startResizePolling();

    // --- Main loop ---
    while (!app_ctx.shouldQuit()) {
        const event = try terminal.loop.nextEvent();
        trace(opts, .event_received);
        event_count += 1;
        var needs_render = false;
        var stats: ?runtime.RuntimeStats = if (stats_enabled) .{
            .event_kind = events_mod.eventKind(event),
            .event_count = event_count,
            .frame_count = frame_count,
        } else null;

        switch (event) {
            .key_press => |key| {
                needs_render = try events.keyPress(App, &app, key, &app_ctx, io, &stats, opts);
            },
            .winsize => |ws| {
                // Resize always redraws so the screen buffer matches the new
                // terminal size; redraw().skip() only applies to app-driven messages.
                needs_render = try applyTerminalResize(App, &terminal, &app, &app_ctx, io, &stats, opts, ws);
            },
            .user_msg => |msg| {
                needs_render = try applyMsg(App, &app, msg, &app_ctx, io, &stats, opts);
            },
            .timer_notification => |notification| {
                needs_render = try events_mod.applyTimerNotification(App, &app, notification, &app_ctx, io, &stats, opts);
            },
            .mouse => |m| {
                needs_render = try dispatchAppEvent(App, &app, .{ .mouse = m }, &app_ctx, io, &stats, opts);
            },
            .focus_in => {
                needs_render = try dispatchAppEvent(App, &app, .focus_in, &app_ctx, io, &stats, opts);
            },
            .focus_out => {
                needs_render = try dispatchAppEvent(App, &app, .focus_out, &app_ctx, io, &stats, opts);
            },
            .paste_start => {
                events.startPaste();
                if (stats) |*s| s.event_kind = .paste;
            },
            .paste_end => {
                if (stats) |*s| s.event_kind = .paste;
                needs_render = try events.endPaste(App, &app, &app_ctx, io, &stats, opts);
            },
            .frame => |frame| {
                frame_count += 1;
                if (stats) |*s| s.frame_count = frame_count;
                needs_render = try dispatchAppEvent(App, &app, .{ .frame = frames.receiveFrame(frame) }, &app_ctx, io, &stats, opts);
            },
            .frame_canceled => {
                frames.receiveCanceled(app_ctx.requests);
                if (stats) |*s| s.event_kind = .frame;
            },
            .continue_effect_drain => {
                effects.receiveContinuation();
                if (stats) |*s| s.event_kind = .user_msg;
            },
            .resize_pending, .timers_completed => {},
        }

        // Polled updates are coalesced outside the bounded event queue. A
        // full queue can drop the wake but not the latest dimensions: popping
        // any existing event creates this opportunity to apply them.
        if (terminal.takeResize()) |ws| {
            needs_render = try applyTerminalResize(App, &terminal, &app, &app_ctx, io, &stats, opts, ws);
        }

        // Process tasks, ticks, and everys spawned during update
        trace(opts, .effect_drain_start);
        const effect_drain_start = timingStart(stats_enabled, io);
        if (app_ctx.requests.hasPendingForegroundCommands()) {
            events.cancelPaste();
        }
        // Drain effects even when the app already requested a redraw; using
        // short-circuit `or` here would delay queued effects until the next event.
        const effect_result = try effects.drain(App, &app, &app_ctx, &tasks, &timers, &terminal_effects, &terminal, &runtime_shutting_down, &frames, &stats, opts);
        needs_render = needs_render or effect_result.needs_render;
        if (stats) |*s| s.effect_drain_ns = timingElapsed(effect_drain_start, io);
        trace(opts, .effect_drain_end);

        if (needs_render) {
            const timings = try renderer.render(App, &terminal.vx, &terminal_effects.images, &app, terminal.writer(), io, stats_enabled, opts);
            if (stats) |*s| {
                s.view_ns = timings.view_ns;
                s.render_ns = timings.render_ns;
                s.did_render = true;
            }
        }

        if (opts.runtime.stats_fn) |stats_fn| {
            stats_fn(opts.runtime.stats_context, stats.?);
        }
    }

    trace(opts, .shutdown);
}

/// Terminal teardown ownership barrier.
///
/// The ordinary app loop has stopped consuming events, but the tty and task
/// producers may still be running. Cancel the existing tty reader future,
/// dispose its remaining queue, then collect every task outcome before
/// App.deinit releases app state.
fn shutdownRuntime(
    comptime App: type,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    tasks: *TaskRuntime(App.Msg),
    timers: *TimerRuntime(App.Msg),
    effects: *Effects(App.Msg),
    frames: *FrameRuntime(App.Msg),
    terminal: *TerminalSession(App.Msg),
    allocator: std.mem.Allocator,
    shutting_down: *std.atomic.Value(bool),
) void {
    shutting_down.store(true, .seq_cst);
    app_ctx.quit();
    // Broadcast before any join: a non-cooperative task cannot withhold the
    // cancellation notification from a later task. No shutdown allocation.
    tasks.requestShutdown();
    app_ctx.requests.discardPendingTasks();

    // Do not call Loop.stop here: its DSR wake + await can block behind a full
    // queue or a terminal that does not answer the query. Canceling the
    // existing reader future interrupts both tty reads and queue waits.
    terminal.stopReader();
    drainInternalEventsForShutdown(App.Msg, &terminal.loop, allocator);

    frames.shutdown();

    timers.shutdown();

    // A worker outcome is exclusive: `.posted` means the queue owns the Msg;
    // `.undelivered` means the future still owns it. Drain once more after all
    // futures settle so every `.posted` outcome reaches typed cleanup too.
    tasks.join(app_ctx.requests);

    drainInternalEventsForShutdown(App.Msg, &terminal.loop, allocator);
    effects.deinit(allocator);
    discardQueuedForegroundCommands(App.Msg, app_ctx, allocator);
}

/// Apply one terminal-size snapshot and notify the application.
///
/// Both in-band resize events and coalesced polling state enter through this
/// runtime-thread boundary. The polling thread never resizes Vaxis or calls app
/// code itself.
fn applyTerminalResize(
    comptime App: type,
    terminal: *TerminalSession(App.Msg),
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    io: std.Io,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
    winsize: vaxis.Winsize,
) !bool {
    try terminal.resize(winsize);
    _ = try dispatchAppEvent(App, app, .{ .winsize = winsize }, app_ctx, io, stats, opts);
    // Screen geometry changed even if update suppresses its own redraw.
    return true;
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

const CancellationTestTask = struct {
    const Msg = enum {
        done,
        pub const undelivered_policy = .plain;
    };
    const App = struct {
        pub const Msg = CancellationTestTask.Msg;
    };
    const State = struct {
        started: std.Io.Event = .unset,
        cleanup_entered: std.Io.Event = .unset,
        cleaned: std.Io.Event = .unset,
        count: std.atomic.Value(usize) = .init(0),
    };
    state: *State,
    io: std.Io,
    release: ?*std.Io.Event,

    fn submit(ctx: *ctx_mod.Ctx(Msg), state: *State, io: std.Io, release: ?*std.Io.Event) !ctx_mod.TaskId {
        const task = try std.testing.allocator.create(CancellationTestTask);
        errdefer std.testing.allocator.destroy(task);
        task.* = .{ .state = state, .io = io, .release = release };
        return ctx.task().spawnOwned(task, .{ .run = CancellationTestTask.run, .failed = failed, .cleanup = cleanup });
    }
    fn run(self: *@This(), _: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
        self.state.started.set(io);
        try io.sleep(.fromSeconds(3600), .awake);
        return .done;
    }
    fn failed(_: *@This(), _: ctx_mod.TaskStartError, _: std.mem.Allocator) Msg {
        unreachable;
    }
    fn cleanup(self: *@This(), allocator: std.mem.Allocator) void {
        const state = self.state;
        const io = self.io;
        state.cleanup_entered.set(io);
        // Deliberately non-cooperative cleanup, controlled by the test. Real
        // cleanup is documented as bounded and must not wait for other work.
        if (self.release) |release| release.waitUncancelable(io);
        allocator.destroy(self);
        _ = state.count.fetchAdd(1, .monotonic);
        state.cleaned.set(io);
    }
};

test "task cancel request returns during slow cleanup and shutdown broadcasts before joining" {
    const Task = CancellationTestTask;
    const Msg = Task.Msg;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    for ([_]bool{ false, true }) |via_shutdown| {
        var ctx_requests = requests_mod.Requests(Msg).init(allocator, io);
        var ctx = ctx_mod.Ctx(Msg).init(&ctx_requests);
        var tasks = TaskRuntime(Msg).init(allocator, io);
        tasks.bind(ctx.requests);
        var effects = try Effects(Msg).init(allocator);
        var env: std.process.Environ.Map = .init(allocator);
        defer env.deinit();
        var terminal: TerminalSession(Msg) = undefined;
        try terminal.init(allocator, io, .{ .env_map = &env });
        defer terminal.deinit();
        var shutting_down: std.atomic.Value(bool) = .init(false);
        var slow: Task.State = .{};
        var fast: Task.State = .{};
        var release: std.Io.Event = .unset;
        const slow_id = try Task.submit(&ctx, &slow, io, if (via_shutdown) &fast.cleaned else &release);
        const fast_id = try Task.submit(&ctx, &fast, io, null);
        try tasks.startPending(ctx.requests, &effects.completions, &terminal.loop, &shutting_down);
        slow.started.waitUncancelable(io);
        fast.started.waitUncancelable(io);
        if (!via_shutdown) {
            ctx.task().requestCancel(slow_id);
            slow.cleanup_entered.waitUncancelable(io);
            // If requestCancel joined slow, execution could not reach here.
            ctx.task().requestCancel(fast_id);
            ctx.task().requestCancel(fast_id);
            fast.cleaned.waitUncancelable(io);
            try std.testing.expectEqual(@as(usize, 0), slow.count.load(.acquire));
            release.set(io);
        }
        var timers = TimerRuntime(Msg).init(allocator, io);
        var frame = FrameRuntime(Msg).init(io);
        shutdownRuntime(Task.App, &ctx, &tasks, &timers, &effects, &frame, &terminal, allocator, &shutting_down);
        try std.testing.expect(ctx.requests._task_runtime == null);
        try std.testing.expectEqual(@as(usize, 1), slow.count.load(.acquire));
        try std.testing.expectEqual(@as(usize, 1), fast.count.load(.acquire));
        try std.testing.expectEqual(@as(usize, 0), tasks.pending.items.len);
        try std.testing.expectEqual(@as(?InternalEvent(Msg), null), try terminal.loop.tryEvent());
    }
}

test "shutdown queue drain deinitializes owned messages" {
    const Event = InternalEvent(OwnershipTestMsg);

    // Loop queue operations do not dereference tty/vaxis; undefined pointers
    // keep this an ownership test rather than a terminal integration test.
    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    var deinit_count: usize = 0;
    const result_bytes = try std.testing.allocator.dupe(u8, "queued-result");
    try std.testing.expect(try loop.tryPostEvent(.{ .user_msg = .{ .owned = .{
        .bytes = result_bytes,
        .deinit_count = &deinit_count,
    } } }));

    drainInternalEventsForShutdown(OwnershipTestMsg, &loop, std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), deinit_count);
    try std.testing.expectEqual(@as(?Event, null), try loop.tryEvent());
}

test {
    _ = @import("program/timers.zig");
    _ = frame_mod;
    _ = events_mod;
    _ = terminal_session;
    _ = terminal_effects_mod;
    _ = effects_mod;
}

test "event resize forces render and Renderer keeps view paint trace order" {
    const Evidence = struct {
        entries: std.ArrayList(runtime.TraceEvent) = .empty,
        views: usize = 0,
        fn record(context: ?*anyopaque, event: runtime.TraceEvent) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.entries.append(std.testing.allocator, event) catch unreachable;
        }
    };
    const App = struct {
        evidence: *Evidence,
        size: vaxis.Winsize = .{ .rows = 0, .cols = 0, .x_pixel = 0, .y_pixel = 0 },
        pub const Msg = struct {
            size: vaxis.Winsize,
            pub const undelivered_policy = .plain;
        };
        pub fn handleEvent(_: *@This(), event: types.Event) ?Msg {
            return .{ .size = event.winsize };
        }
        pub fn update(self: *@This(), msg: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            self.size = msg.size;
            ctx.redraw().skip();
        }
        pub fn view(self: *const @This(), sfc: *Surface) !void {
            try std.testing.expectEqual(self.size.cols, sfc.size().width);
            try std.testing.expectEqual(self.size.rows, sfc.size().height);
            try std.testing.expectEqual(runtime.TraceEvent.view_start, self.evidence.entries.getLast());
            self.evidence.views += 1;
            // Exercise the renderer-owned scratch allocator on both renders.
            const text = try sfc.arena.dupe(u8, "redraw");
            _ = sfc.borrowTextAt(0, 0, text, .{});
        }
    };
    var evidence: Evidence = .{};
    defer evidence.entries.deinit(std.testing.allocator);
    var app: App = .{ .evidence = &evidence };
    var requests = requests_mod.Requests(App.Msg).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var ctx = ctx_mod.Ctx(App.Msg).init(&requests);
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var terminal: TerminalSession(App.Msg) = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, .{ .env_map = &env });
    defer terminal.deinit();
    var images: terminal_image.Registry = .{};
    defer images.deinit(std.testing.allocator);
    var renderer = Renderer.init(std.testing.allocator);
    defer renderer.deinit();
    const opts: types.RunOptions = .{
        .runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io, .trace_fn = Evidence.record, .trace_context = &evidence },
        .terminal = .{ .env_map = &env },
    };
    for ([_]bool{ false, true }) |measure| {
        evidence.entries.clearRetainingCapacity();
        var stats: ?runtime.RuntimeStats = if (measure) .{ .event_kind = .winsize, .event_count = 2, .frame_count = 1 } else null;
        const ws: vaxis.Winsize = .{ .rows = 3, .cols = if (measure) 12 else 8, .x_pixel = 0, .y_pixel = 0 };
        try std.testing.expect(try applyTerminalResize(App, &terminal, &app, &ctx, std.testing.io, &stats, opts, ws));
        try std.testing.expect(requests.redrawWasSuppressed());
        const timings = try renderer.render(App, &terminal.vx, &images, &app, terminal.writer(), std.testing.io, measure, opts);
        if (!measure) {
            try std.testing.expectEqual(@as(u64, 0), timings.view_ns);
            try std.testing.expectEqual(@as(u64, 0), timings.render_ns);
        }
        try std.testing.expectEqualSlices(runtime.TraceEvent, &.{ .handle_event_start, .handle_event_end, .update_start, .update_end, .view_start, .view_end, .render_start, .render_end }, evidence.entries.items);
    }
    try std.testing.expectEqual(@as(usize, 2), evidence.views);
}

test "Program init and effect errors clean pending owners before App deinit" {
    const State = struct {
        task_cleaned: usize = 0,
        app_cleaned: usize = 0,
        updates: usize = 0,
    };
    const App = struct {
        state: *State,
        fail_init: bool,
        pub const Msg = enum {
            copied,
            pub const undelivered_policy = .plain;
        };
        pub fn init(self: *@This(), ctx: *ctx_mod.Ctx(Msg)) !void {
            _ = try ctx.task().spawnOwned(self.state, .{ .run = taskRun, .failed = taskFailed, .cleanup = taskCleanup });
            _ = try ctx.terminal().copyToClipboard(.{ .text = "old first", .finished = copied });
            _ = try ctx.terminal().copyToClipboard(.{ .text = "old suffix", .finished = copied });
            try ctx.timer().tick("pending", std.time.ns_per_s, {}, timerNotice);
            _ = try ctx.image().loadPath("pending.png", imageLoaded, imageFailed);
            if (self.fail_init) return error.ExpectedInitFailure;
        }
        fn timerNotice(_: void, outcome: runtime.TimerOutcome, _: std.mem.Allocator) ?Msg {
            return switch (outcome) {
                .fired => .copied,
                .failed => null,
            };
        }
        pub fn update(self: *@This(), _: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            self.state.updates += 1;
            // Reentry uses fresh pending storage. The interrupted clipboard
            // stage still owns its old suffix; shutdown owns this new request.
            _ = try ctx.terminal().copyToClipboard(.{ .text = "new pending", .finished = copied });
            return error.ExpectedEffectFailure;
        }
        pub fn view(_: *const @This(), _: *Surface) !void {
            unreachable;
        }
        pub fn deinit(self: *@This(), _: runtime.AppDeinitContext) void {
            std.debug.assert(self.state.task_cleaned == 1);
            self.state.app_cleaned += 1;
        }
        fn copied(_: ctx_mod.Ctx(Msg).ClipboardCopyResult) Msg {
            return .copied;
        }
        fn taskRun(_: *State, _: std.mem.Allocator, _: std.Io) std.Io.Cancelable!Msg {
            unreachable;
        }
        fn taskFailed(_: *State, _: ctx_mod.TaskStartError, _: std.mem.Allocator) Msg {
            unreachable;
        }
        fn taskCleanup(state: *State, _: std.mem.Allocator) void {
            state.task_cleaned += 1;
        }
        fn imageLoaded(_: terminal_image.TerminalImageRequestId, _: terminal_image.TerminalImageHandle) Msg {
            unreachable;
        }
        fn imageFailed(_: terminal_image.TerminalImageRequestId, _: terminal_image.LoadError) Msg {
            unreachable;
        }
    };
    for ([_]bool{ false, true }) |fail_init| {
        var state: State = .{};
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        try std.testing.expectError(if (fail_init) error.ExpectedInitFailure else error.ExpectedEffectFailure, run(App, .{
            .runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .terminal = .{ .env_map = &env },
        }, .{ .state = &state, .fail_init = fail_init }));
        try std.testing.expectEqual(@as(usize, 1), state.task_cleaned);
        try std.testing.expectEqual(@as(usize, 1), state.app_cleaned);
        try std.testing.expectEqual(@as(usize, if (fail_init) 0 else 1), state.updates);
    }
}
