const std = @import("std");
const vaxis = @import("vaxis");
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const ctx_mod = @import("ctx.zig");
const requests_mod = @import("requests.zig");
const runtime = @import("runtime.zig");
const types = @import("program_types.zig");
const InternalEvent = types.InternalEvent;
const RuntimeCompletionBuffer = types.RuntimeCompletionBuffer;
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

const max_effect_drain_rounds: usize = 8;

const EffectDrainResult = struct {
    needs_render: bool = false,
};

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
    var runtime_completions: RuntimeCompletionBuffer(Msg) = .{};
    try runtime_completions.init(allocator);
    tasks.bind(app_ctx.requests);
    var effect_drain_continuation_pending = false;

    // This defer runs before App.deinit and before the remaining terminal
    // resource defers. It is the single owner of started task outcomes,
    // queued-but-unstarted task contexts, and undelivered queue messages.
    defer shutdownRuntime(
        App,
        &app_ctx,
        &tasks,
        &timers,
        &runtime_completions,
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
        _ = try drainPendingEffects(App, &app, &app_ctx, &tasks, &timers, &runtime_completions, &terminal_effects, &terminal, allocator, io, &runtime_shutting_down, &frames, &effect_drain_continuation_pending, &init_stats, opts);
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
        _ = try drainPendingEffects(App, &app, &app_ctx, &tasks, &timers, &runtime_completions, &terminal_effects, &terminal, allocator, io, &runtime_shutting_down, &frames, &effect_drain_continuation_pending, &initial_stats, opts);
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
                effect_drain_continuation_pending = false;
                if (stats) |*s| s.event_kind = .user_msg;
            },
            .resize_pending => {},
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
        const effect_result = try drainPendingEffects(App, &app, &app_ctx, &tasks, &timers, &runtime_completions, &terminal_effects, &terminal, allocator, io, &runtime_shutting_down, &frames, &effect_drain_continuation_pending, &stats, opts);
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
    runtime_completions: *RuntimeCompletionBuffer(App.Msg),
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
    runtime_completions.deinitUndelivered(allocator);
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

/// Deliver callbacks created on the runtime thread without routing them back
/// through the vaxis queue consumed by that same thread.
///
/// The buffer is drained before effect backing arrays are taken for this pass,
/// so updates may safely queue new effects. Increment `consumed` before calling
/// update: once dispatch begins, the app owns that message even on error.
fn applyRuntimeCompletions(
    comptime App: type,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    completions: *RuntimeCompletionBuffer(App.Msg),
    allocator: std.mem.Allocator,
    io: std.Io,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
) !EffectDrainResult {
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

fn scheduleEffectDrainContinuation(
    comptime Msg: type,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    pending: *bool,
) !void {
    if (pending.*) return;
    if (try loop.tryPostEvent(.continue_effect_drain)) pending.* = true;
    // A full queue already guarantees another event-loop iteration. Leave the
    // flag clear so a later bounded pass can enqueue a wake if the queue drains.
}

/// Drains effects queued in Ctx using the documented per-pass runtime order:
///
/// 1. foreground commands
/// 2. terminal clipboard copies
/// 3. async tasks
/// 4. pending timer cancels
/// 5. pending ticks
/// 6. pending everys
/// 7. terminal images
/// 8. frame request
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
fn drainPendingEffects(
    comptime App: type,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    tasks: *TaskRuntime(App.Msg),
    timers: *TimerRuntime(App.Msg),
    runtime_completions: *RuntimeCompletionBuffer(App.Msg),
    terminal_effects: *TerminalEffects,
    terminal: *TerminalSession(App.Msg),
    allocator: std.mem.Allocator,
    io: std.Io,
    shutting_down: *const std.atomic.Value(bool),
    frames: *FrameRuntime(App.Msg),
    effect_drain_continuation_pending: *bool,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
) !EffectDrainResult {
    var result: EffectDrainResult = .{};
    const Msg = App.Msg;

    for (0..max_effect_drain_rounds) |round| {
        const completion_result = try applyRuntimeCompletions(App, app, app_ctx, runtime_completions, allocator, io, stats, opts);
        result.needs_render = result.needs_render or completion_result.needs_render;
        const foreground_needs_render = try terminal_effects.processForeground(App, app, app_ctx, terminal, stats, opts);
        result.needs_render = result.needs_render or foreground_needs_render;
        const clipboard_needs_render = try terminal_effects.processClipboard(App, app, app_ctx, terminal, stats, opts);
        result.needs_render = result.needs_render or clipboard_needs_render;
        try tasks.startPending(app_ctx.requests, runtime_completions, &terminal.loop, shutting_down);
        timers.cancelPending(app_ctx.requests);
        timers.startTicks(app_ctx.requests, &terminal.loop, shutting_down);
        timers.startEvery(app_ctx.requests, &terminal.loop, &terminal.suspended, shutting_down);
        try terminal_effects.processImages(Msg, app_ctx, runtime_completions, terminal, opts);
        frames.startRequested(app_ctx.requests, &terminal.loop, &terminal.suspended, shutting_down);

        const has_follow_up = runtime_completions.items.items.len > 0 or
            app_ctx.requests.hasPendingForegroundCommands() or
            app_ctx.requests.hasPendingClipboardCopies();
        if (!has_follow_up) break;
        if (round + 1 == max_effect_drain_rounds) {
            try scheduleEffectDrainContinuation(Msg, &terminal.loop, effect_drain_continuation_pending);
        }
    }

    return result;
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
        var completions: RuntimeCompletionBuffer(Msg) = .{};
        try completions.init(allocator);
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
        try tasks.startPending(ctx.requests, &completions, &terminal.loop, &shutting_down);
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
        shutdownRuntime(Task.App, &ctx, &tasks, &timers, &completions, &frame, &terminal, allocator, &shutting_down);
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

test "runtime completion buffer deinitializes unapplied messages" {
    var completions: RuntimeCompletionBuffer(OwnershipTestMsg) = .{};
    try completions.init(std.testing.allocator);

    var deinit_count: usize = 0;
    try completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "local-completion"),
        .deinit_count = &deinit_count,
    } });

    completions.deinitUndelivered(std.testing.allocator);
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
    var completions: RuntimeCompletionBuffer(TestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    while (try loop.tryPostEvent(.continue_effect_drain)) {}
    var shutting_down: std.atomic.Value(bool) = .init(false);

    try tasks.startPending(app_ctx.requests, &completions, &loop, &shutting_down);
    try std.testing.expectEqual(@as(usize, 0), tasks.pending.items.len);
    try std.testing.expectEqual(@as(usize, 1), completions.items.items.len);

    var app: TestApp = .{};
    var stats: ?runtime.RuntimeStats = null;
    _ = try applyRuntimeCompletions(
        TestApp,
        &app,
        &app_ctx,
        &completions,
        std.testing.allocator,
        std.testing.io,
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
        var completions: RuntimeCompletionBuffer(TestMsg) = .{};
        try completions.init(std.testing.allocator);
        defer completions.deinitUndelivered(std.testing.allocator);
        try completions.append(.first);
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
        var continuation_pending = false;
        var stats: ?runtime.RuntimeStats = null;

        const result = try drainPendingEffects(
            TestApp,
            &app,
            &app_ctx,
            &tasks,
            &timers,
            &completions,
            &terminal_effects,
            &terminal,
            std.testing.failing_allocator,
            std.testing.io,
            &shutting_down,
            &frames,
            &continuation_pending,
            &stats,
            .{ .runtime = .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
            }, .terminal = .{ .env_map = undefined } },
        );

        try std.testing.expectEqual(!skip, result.needs_render);
        try std.testing.expectEqual(@as(usize, 2), app.update_count);
        try std.testing.expectEqual(@as(usize, 0), completions.items.items.len);
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
    var completions: RuntimeCompletionBuffer(TestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var terminal: TerminalSession(TestMsg) = undefined;
    try terminal.init(std.testing.allocator, std.testing.io, .{ .env_map = &env });
    defer terminal.deinit();
    var effects: TerminalEffects = .{};
    defer effects.deinit(&terminal);

    try effects.processImages(
        TestMsg,
        &app_ctx,
        &completions,
        &terminal,
        .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        }, .terminal = .{ .env_map = undefined } },
    );
    try std.testing.expectEqual(@as(usize, 1), completions.items.items.len);

    var app: TestApp = .{};
    var stats: ?runtime.RuntimeStats = null;
    _ = try applyRuntimeCompletions(
        TestApp,
        &app,
        &app_ctx,
        &completions,
        std.testing.allocator,
        std.testing.io,
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
    var completions: RuntimeCompletionBuffer(OwnershipTestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    try completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "delivered-completion"),
        .deinit_count = &deinit_count,
    } });
    var stats: ?runtime.RuntimeStats = null;

    _ = try applyRuntimeCompletions(
        TestApp,
        &app,
        &app_ctx,
        &completions,
        std.testing.allocator,
        std.testing.io,
        &stats,
        .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        }, .terminal = undefined },
    );

    try std.testing.expectEqual(@as(usize, 1), update_count);
    try std.testing.expectEqual(@as(usize, 0), deinit_count);
    try std.testing.expectEqual(@as(usize, 0), completions.items.items.len);
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
    var app: TestApp = .{};
    defer if (app.retained) |owned| std.testing.allocator.free(owned.bytes);
    var app_ctx_requests = requests_mod.Requests(OwnershipTestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(OwnershipTestMsg).init(&app_ctx_requests);
    var completions: RuntimeCompletionBuffer(OwnershipTestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    try completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "update-error-completion"),
        .deinit_count = &deinit_count,
    } });
    var stats: ?runtime.RuntimeStats = null;

    try std.testing.expectError(
        error.ExpectedUpdateFailure,
        applyRuntimeCompletions(
            TestApp,
            &app,
            &app_ctx,
            &completions,
            std.testing.allocator,
            std.testing.io,
            &stats,
            .{ .runtime = .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
            }, .terminal = undefined },
        ),
    );

    try std.testing.expect(app.retained != null);
    try std.testing.expectEqual(@as(usize, 0), deinit_count);
    try std.testing.expectEqual(@as(usize, 0), completions.items.items.len);
}

test {
    _ = @import("program/timers.zig");
    _ = frame_mod;
    _ = events_mod;
    _ = terminal_session;
    _ = terminal_effects_mod;
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
