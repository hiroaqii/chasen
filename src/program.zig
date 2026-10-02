const std = @import("std");
const builtin = @import("builtin");
const foreground_job = @import("foreground_job.zig");
const foreground_command = @import("foreground_command.zig");
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
const drainInternalEventsForShutdown = terminal_session.drainInternalEventsForShutdown;

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

pub const TerminalEffects = struct {
    images: terminal_image.Registry = .{},

    pub fn deinit(self: *TerminalEffects, session: anytype) void {
        self.images.freeAll(session.vx, session.writer());
        self.images.deinit(session.allocator);
    }

    pub fn processForeground(self: *TerminalEffects, comptime App: type, app: *App, ctx: *ctx_mod.Ctx(App.Msg), session: *TerminalSession(App.Msg), stats: *?runtime.RuntimeStats, opts: types.RunOptions) !bool {
        _ = self;
        const Runner = struct {
            session: *TerminalSession(App.Msg),
            fn run(runner: @This(), entry: *const requests_mod.Requests(App.Msg).ForegroundCommandEntry) !foreground_command.ForegroundCommandOutcome {
                return runner.session.runForeground(entry);
            }
        };
        return processPendingForegroundCommandsWithRunner(App, app, ctx, session.allocator, session.io, stats, opts, Runner{ .session = session });
    }

    pub fn processClipboard(self: *TerminalEffects, comptime App: type, app: *App, ctx: *ctx_mod.Ctx(App.Msg), session: *TerminalSession(App.Msg), stats: *?runtime.RuntimeStats, opts: types.RunOptions) !bool {
        _ = self;
        return processPendingClipboardCopies(App, app, ctx, &session.vx, &session.tty, session.allocator, session.io, stats, opts);
    }

    pub fn processImages(self: *TerminalEffects, comptime Msg: type, ctx: *ctx_mod.Ctx(Msg), completions: *RuntimeCompletionBuffer(Msg), session: *TerminalSession(Msg), opts: types.RunOptions) !void {
        try processPendingTerminalImages(Msg, ctx, completions, &self.images, &session.vx, session.writer(), session.allocator, opts);
    }
};

fn processPendingForegroundCommandsWithRunner(
    comptime App: type,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    io: std.Io,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
    runner: anytype,
) !bool {
    var pending_commands = app_ctx.requests.detachForegroundCommands();
    // Abandon every unprocessed entry on an early error, before freeing inputs.
    defer {
        while (pending_commands.next()) |queued| {
            var entry = queued;
            var msg = entry.message(.runtime_abandoned);
            runtime.deinitUndeliveredMessage(App.Msg, &msg, allocator);
            entry.deinit(allocator);
        }
    }
    var needs_render = false;

    while (pending_commands.next()) |queued_entry| {
        var entry = queued_entry;
        defer entry.deinit(allocator);

        const outcome = if (app_ctx.shouldQuit()) foreground_command.ForegroundCommandOutcome.runtime_abandoned else runner.run(&entry) catch |err| foreground_job.failure(.restore_tui, @errorName(err));
        var msg = entry.message(outcome);
        if (outcome.isFatal() or outcome == .runtime_abandoned) {
            runtime.deinitUndeliveredMessage(App.Msg, &msg, allocator);
            if (outcome.isFatal()) return error.ForegroundRecoveryFailed;
        } else {
            needs_render = try applyMsg(App, app, msg, app_ctx, io, stats, opts) or needs_render;
        }
    }

    return needs_render;
}

fn processPendingClipboardCopies(
    comptime App: type,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    allocator: std.mem.Allocator,
    io: std.Io,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
) !bool {
    var pending_copies = app_ctx.requests.detachClipboardCopies();
    defer pending_copies.deinit();
    var needs_render = false;
    while (pending_copies.next()) |queued| {
        var entry = queued;
        defer entry.deinit(allocator);
        const outcome: ctx_mod.Ctx(App.Msg).ClipboardCopyOutcome = if (vx.*.copyToSystemClipboard(tty.writer(), entry.text, allocator)) |_| .sent else |err| .{ .write_failed = @errorName(err) };
        needs_render = try applyMsg(App, app, entry.message(outcome), app_ctx, io, stats, opts) or needs_render;
    }

    return needs_render;
}

fn processPendingTerminalImages(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    runtime_completions: *RuntimeCompletionBuffer(Msg),
    registry: *terminal_image.Registry,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    opts: types.RunOptions,
) !void {
    // Take ownership of queued image effects before processing so unwind
    // cleanup only sees entries that have not reached the drain step.
    var pending_unloads = app_ctx.requests.detachTerminalImageUnloads();
    defer pending_unloads.deinit();

    while (pending_unloads.next()) |handle| {
        _ = registry.unload(vx.*, tty, handle);
    }

    var pending_loads = app_ctx.requests.detachTerminalImageLoads();
    defer pending_loads.deinit();

    while (pending_loads.next()) |entry| {
        defer allocator.free(entry.path);

        switch (loadTerminalImagePath(registry, vx, tty, allocator, entry.path, opts)) {
            .loaded => |handle| {
                var msg = entry.loaded(entry.request_id, handle);
                runtime_completions.append(msg) catch |err| {
                    runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                    _ = registry.unload(vx.*, tty, handle);
                    return err;
                };
            },
            .failed => |reason| {
                var msg = entry.failed(entry.request_id, reason);
                runtime_completions.append(msg) catch |err| {
                    runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                    return err;
                };
            },
        }
    }
}

const TerminalImageLoadResult = union(enum) {
    loaded: terminal_image.TerminalImageHandle,
    failed: terminal_image.LoadError,
};

fn loadTerminalImagePath(
    registry: *terminal_image.Registry,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: types.RunOptions,
) TerminalImageLoadResult {
    const loader = opts.terminal.image_path_loader orelse terminal_image.unsupportedPathLoader;
    const image = loader(opts.terminal.image_loader_context, vx, tty, allocator, path) catch |err| {
        if (err == error.Unsupported) return .{ .failed = .unsupported };
        return .{ .failed = .load_failed };
    };
    const handle = registry.add(allocator, image) catch {
        vx.freeImage(tty, image.id);
        return .{ .failed = .registry_full };
    };
    return .{ .loaded = handle };
}

pub fn discardQueuedForegroundCommands(comptime Msg: type, app_ctx: *ctx_mod.Ctx(Msg), allocator: std.mem.Allocator) void {
    var batch = app_ctx.requests.detachForegroundCommands();
    defer batch.deinit();
    while (batch.next()) |queued| {
        var entry = queued;
        var msg = entry.finished(.{ .request_id = entry.request_id, .outcome = .runtime_abandoned });
        runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
        entry.deinit(allocator);
    }
}

test "clipboard detached suffix survives reentrant update and is freed on update error" {
    const TestApp = struct {
        fail_update: bool,
        received: usize = 0,
        pub const Msg = struct {
            request_id: u64,
            pub const undelivered_policy = .plain;
        };
        fn finished(result: ctx_mod.Ctx(Msg).ClipboardCopyResult) Msg {
            std.debug.assert(result.outcome == .sent);
            return .{ .request_id = result.request_id.id };
        }
        pub fn update(self: *@This(), msg: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            self.received += 1;
            try std.testing.expectEqual(self.received, msg.request_id);
            if (self.received == 1) {
                _ = try ctx.terminal().copyToClipboard(.{ .text = "new", .finished = finished });
                if (self.fail_update) return error.UpdateFailed;
            }
        }
    };
    for ([_]bool{ false, true }) |fail_update| {
        var requests = requests_mod.Requests(TestApp.Msg).init(std.testing.allocator, std.testing.io);
        defer requests.deinit();
        var ctx = ctx_mod.Ctx(TestApp.Msg).init(&requests);
        _ = try ctx.terminal().copyToClipboard(.{ .text = "first", .finished = TestApp.finished });
        _ = try ctx.terminal().copyToClipboard(.{ .text = "second", .finished = TestApp.finished });
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        var buffer: [128]u8 = undefined;
        var tty = try vaxis.Tty.init(std.testing.io, &buffer);
        defer tty.deinit();
        var vx = try vaxis.Vaxis.init(std.testing.io, std.testing.allocator, &env, .{});
        defer vx.deinit(std.testing.allocator, tty.writer());
        var app: TestApp = .{ .fail_update = fail_update };
        var stats: ?runtime.RuntimeStats = null;
        const result = processPendingClipboardCopies(TestApp, &app, &ctx, &vx, &tty, std.testing.allocator, std.testing.io, &stats, .{
            .runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .terminal = .{ .env_map = &env },
        });
        if (fail_update) {
            try std.testing.expectError(error.UpdateFailed, result);
        } else {
            try std.testing.expect(try result);
        }
        try std.testing.expectEqual(@as(usize, if (fail_update) 1 else 2), app.received);
        if (comptime builtin.os.tag == .linux) {
            const wire = tty.tty_writer.written();
            try std.testing.expect(std.mem.indexOf(u8, wire, "Zmlyc3Q=") != null);
            try std.testing.expectEqual(!fail_update, std.mem.indexOf(u8, wire, "c2Vjb25k") != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "bmV3") == null);
        }
        var remaining = requests.detachClipboardCopies();
        defer remaining.deinit();
        var new_entry = remaining.next().?;
        defer new_entry.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("new", new_entry.text);
        try std.testing.expectEqual(@as(u64, 3), new_entry.request_id.id);
        try std.testing.expect(remaining.next() == null);
    }
}

test "image batch overflow frees current and unconsumed paths" {
    const Msg = struct {
        pub const undelivered_policy = .plain;
        fn loaded(_: terminal_image.TerminalImageRequestId, _: terminal_image.TerminalImageHandle) @This() {
            unreachable;
        }
        fn failed(_: terminal_image.TerminalImageRequestId, _: terminal_image.LoadError) @This() {
            return .{};
        }
    };
    var requests = requests_mod.Requests(Msg).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var ctx = ctx_mod.Ctx(Msg).init(&requests);
    for ([_][]const u8{ "one.png", "two.png", "three.png" }) |path| {
        _ = try ctx.image().loadPath(path, Msg.loaded, Msg.failed);
    }
    var completions: RuntimeCompletionBuffer(Msg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    for (0..RuntimeCompletionBuffer(Msg).capacity - 1) |_| try completions.append(.{});
    var registry: terminal_image.Registry = .{};
    defer registry.deinit(std.testing.allocator);
    try std.testing.expectError(error.RuntimeCompletionLimitExceeded, processPendingTerminalImages(
        Msg,
        &ctx,
        &completions,
        &registry,
        undefined,
        undefined,
        std.testing.allocator,
        .{ .runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io }, .terminal = .{ .env_map = undefined } },
    ));
    try std.testing.expectEqual(@as(usize, RuntimeCompletionBuffer(Msg).capacity), completions.items.items.len);
    var empty = requests.detachTerminalImageLoads();
    defer empty.deinit();
    try std.testing.expect(empty.next() == null);
}

fn foregroundCommandProgramTestFdOpen(fd: std.Io.Dir.Handle) bool {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
            break :blk std.os.linux.errno(rc) == .SUCCESS;
        },
        .macos => blk: {
            const rc = std.c.fcntl(fd, std.c.F.GETFD);
            break :blk std.c.errno(rc) == .SUCCESS;
        },
        else => false,
    };
}

fn foregroundCommandTestTouchPath() ![]const u8 {
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/touch", .{})) |_| {
        return "/usr/bin/touch";
    } else |_| {}
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/bin/touch", .{})) |_| {
        return "/bin/touch";
    } else |_| {}
    return error.SkipZigTest;
}

fn foregroundCommandTestTruePath() ![]const u8 {
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/true", .{})) |_| {
        return "/usr/bin/true";
    } else |_| {}
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/bin/true", .{})) |_| {
        return "/bin/true";
    } else |_| {}
    return error.SkipZigTest;
}

fn foregroundCommandTestPrintenvPath() ![]const u8 {
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/printenv", .{})) |_| {
        return "/usr/bin/printenv";
    } else |_| {}
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/bin/printenv", .{})) |_| {
        return "/bin/printenv";
    } else |_| {}
    return error.SkipZigTest;
}

fn foregroundCommandTestShellPath() ![]const u8 {
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/bin/sh", .{})) |_| {
        return "/bin/sh";
    } else |_| {}
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/sh", .{})) |_| {
        return "/usr/bin/sh";
    } else |_| {}
    return error.SkipZigTest;
}

fn foregroundCommandParentCanary(map: *const std.process.Environ.Map) ![]const u8 {
    const non_secret_keys = [_][]const u8{
        "HOME",
        "USER",
        "LOGNAME",
        "LANG",
        "LC_ALL",
        "TERM",
        "SHELL",
        "XDG_RUNTIME_DIR",
    };
    for (non_secret_keys) |key| {
        if (map.contains(key)) return key;
    }
    return error.SkipZigTest;
}

test "foreground command inherit cwd reaches child spawn" {
    const TestMsg = union(enum) { finished };
    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{try foregroundCommandTestTruePath()},
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    switch (entry.input.childCwd()) {
        .inherit => {},
        else => return error.TestUnexpectedResult,
    }
    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        entry.input.childEnvironment(),
    );
    switch (outcome) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

test "foreground environment replacement snapshot reaches child without parent leakage" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);
    var caller_dir = try tmp.dir.openDir(std.testing.io, "original", .{});
    var caller_dir_live = true;
    defer if (caller_dir_live) caller_dir.close(std.testing.io);
    var caller_map: std.process.Environ.Map = .init(std.testing.allocator);
    var caller_map_live = true;
    defer if (caller_map_live) caller_map.deinit();
    try caller_map.put("ISSUE55_VALUE", "queued-value");
    try caller_map.put("ISSUE55_SECOND", "queued-second");
    var parent_map = try std.testing.environ.createMap(std.testing.allocator);
    defer parent_map.deinit();
    const parent_canary = try foregroundCommandParentCanary(&parent_map);

    const printenv_path = try foregroundCommandTestPrintenvPath();
    const shell_path = try foregroundCommandTestShellPath();
    const caller_argv0 = try std.testing.allocator.dupe(u8, shell_path);
    defer std.testing.allocator.free(caller_argv0);
    // Test-only: the production path preserves caller argv and never inserts a
    // shell. This fixture verifies only fixed test values and an allowlisted
    // parent key, discards command output, then creates an empty cwd-relative
    // marker. It never persists ambient environment values.
    const caller_command = try std.fmt.allocPrint(
        std.testing.allocator,
        "test \"$ISSUE55_VALUE\" = queued-value && test \"$ISSUE55_SECOND\" = queued-second && ! {s} {s} >/dev/null 2>&1 && : > environment-marker",
        .{ printenv_path, parent_canary },
    );
    defer std.testing.allocator.free(caller_command);
    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ caller_argv0, "-c", caller_command },
        .cwd = .{ .dir = caller_dir },
        .environment = .{ .replace = &caller_map },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    @memset(caller_argv0, 'x');
    @memset(caller_command, 'x');
    try caller_map.put("ISSUE55_VALUE", "caller-mutated");
    try std.testing.expect(caller_map.orderedRemove("ISSUE55_SECOND"));
    caller_map.deinit();
    caller_map_live = false;
    caller_dir.close(std.testing.io);
    caller_dir_live = false;
    try tmp.dir.rename("original", tmp.dir, "renamed", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    switch (entry.input.childCwd()) {
        .dir => {},
        else => return error.TestUnexpectedResult,
    }
    const queued_environment = entry.input.childEnvironment() orelse return error.TestUnexpectedResult;
    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        queued_environment,
    );
    switch (outcome) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    try tmp.dir.access(std.testing.io, "renamed/environment-marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "original/environment-marker", .{}));
}

test "foreground environment inherit and empty replacement remain distinct in child" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    const finished = &struct {
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }
    }.done;
    var parent_map = try std.testing.environ.createMap(std.testing.allocator);
    defer parent_map.deinit();
    const parent_canary = try foregroundCommandParentCanary(&parent_map);
    const printenv_path = try foregroundCommandTestPrintenvPath();
    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();

    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ printenv_path, parent_canary },
        .environment = .inherit,
        .finished = finished,
    });
    {
        var pending = app_ctx.requests.detachForegroundCommands();
        defer pending.deinit();
        var entry = pending.next().?;
        defer entry.deinit(std.testing.allocator);
        try std.testing.expect(entry.input.childEnvironment() == null);
        const outcome = foreground_job.testRun(
            std.testing.io,
            entry.input.argv,
            entry.input.childCwd(),
            entry.input.childEnvironment(),
        );
        switch (outcome) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.TestUnexpectedResult,
        }
    }

    var empty_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer empty_map.deinit();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ printenv_path, parent_canary },
        .environment = .{ .replace = &empty_map },
        .finished = finished,
    });
    {
        var pending = app_ctx.requests.detachForegroundCommands();
        defer pending.deinit();
        var entry = pending.next().?;
        defer entry.deinit(std.testing.allocator);
        const queued_empty = entry.input.childEnvironment() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), queued_empty.count());
        const outcome = foreground_job.testRun(
            std.testing.io,
            entry.input.argv,
            entry.input.childCwd(),
            queued_empty,
        );
        switch (outcome) {
            .exited => |code| try std.testing.expect(code != 0),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "foreground command directory cwd keeps identity across rename and caller close" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);
    var caller_dir = try tmp.dir.openDir(std.testing.io, "original", .{});
    var caller_open = true;
    defer if (caller_open) caller_dir.close(std.testing.io);

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ try foregroundCommandTestTouchPath(), "marker" },
        .cwd = .{ .dir = caller_dir },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    const duplicate_fd = switch (entry.input.childCwd()) {
        .dir => |dir| dir.handle,
        else => return error.TestUnexpectedResult,
    };

    caller_dir.close(std.testing.io);
    caller_open = false;
    try tmp.dir.rename("original", tmp.dir, "renamed", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);

    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        entry.input.childEnvironment(),
    );
    switch (outcome) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(foregroundCommandProgramTestFdOpen(duplicate_fd));
    try tmp.dir.access(std.testing.io, "renamed/marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "original/marker", .{}));
}

test "foreground command path cwd copies bytes and resolves at spawn time" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);

    const queued_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/original",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(queued_path);
    const expected_path = try std.testing.allocator.dupe(u8, queued_path);
    defer std.testing.allocator.free(expected_path);

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ try foregroundCommandTestTouchPath(), "marker" },
        .cwd = .{ .path = queued_path },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });
    @memset(queued_path, 'x');

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    switch (entry.input.childCwd()) {
        .path => |path| try std.testing.expectEqualStrings(expected_path, path),
        else => return error.TestUnexpectedResult,
    }

    try tmp.dir.rename("original", tmp.dir, "renamed", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);
    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        entry.input.childEnvironment(),
    );
    switch (outcome) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try tmp.dir.access(std.testing.io, "original/marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "renamed/marker", .{}));
}

test "foreground command accepts a duplicable non-directory and reports spawn failure" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "not-a-directory", .{});
    defer file.close(std.testing.io);

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{try foregroundCommandTestTouchPath()},
        .cwd = .{ .dir = .{ .handle = file.handle } },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        entry.input.childEnvironment(),
    );
    switch (outcome) {
        .failed => |f| try std.testing.expectEqual(foreground_command.ForegroundCommandFailure.Stage.spawn, f.stage),
        else => return error.TestUnexpectedResult,
    }
}

test "foreground command processing copies the taken owner before callback requeue" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) {
        first_finished,
        second_finished,

        pub const undelivered_policy = .plain;
    };
    const Callbacks = struct {
        fn first(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .first_finished;
        }

        fn second(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .second_finished;
        }
    };
    const TestApp = struct {
        follow_up_dir: std.Io.Dir,
        follow_up_environment: *const std.process.Environ.Map,
        update_count: usize = 0,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), msg: Msg, app_ctx: *ctx_mod.Ctx(Msg)) !void {
            self.update_count += 1;
            switch (msg) {
                .first_finished => _ = try app_ctx.terminal().runForegroundCommand(.{
                    .argv = &.{"second"},
                    .cwd = .{ .dir = self.follow_up_dir },
                    .environment = .{ .replace = self.follow_up_environment },
                    .finished = Callbacks.second,
                }),
                .second_finished => {},
            }
        }
    };
    const Runner = struct {
        first_duplicate: *?std.Io.Dir.Handle,
        first_environment_observed: *bool,

        fn run(
            self: @This(),
            entry: *const requests_mod.Requests(TestMsg).ForegroundCommandEntry,
        ) !foreground_command.ForegroundCommandOutcome {
            self.first_duplicate.* = switch (entry.input.childCwd()) {
                .dir => |dir| dir.handle,
                else => return error.TestUnexpectedResult,
            };
            const environment = entry.input.childEnvironment() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("first", environment.get("ISSUE55_OWNER").?);
            self.first_environment_observed.* = true;
            return .{ .exited = 0 };
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "first", .default_dir);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);
    const first_dir = try tmp.dir.openDir(std.testing.io, "first", .{});
    defer first_dir.close(std.testing.io);
    const second_dir = try tmp.dir.openDir(std.testing.io, "second", .{});
    defer second_dir.close(std.testing.io);
    var first_environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer first_environment.deinit();
    try first_environment.put("ISSUE55_OWNER", "first");
    var second_environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer second_environment.deinit();
    try second_environment.put("ISSUE55_OWNER", "second");

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{"first"},
        .cwd = .{ .dir = first_dir },
        .environment = .{ .replace = &first_environment },
        .finished = Callbacks.first,
    });

    var app: TestApp = .{
        .follow_up_dir = second_dir,
        .follow_up_environment = &second_environment,
    };
    var first_duplicate: ?std.Io.Dir.Handle = null;
    var first_environment_observed = false;
    var stats: ?runtime.RuntimeStats = null;
    _ = try processPendingForegroundCommandsWithRunner(
        TestApp,
        &app,
        &app_ctx,
        std.testing.allocator,
        std.testing.io,
        &stats,
        .{
            .runtime = .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
            },
            .terminal = undefined,
        },
        Runner{
            .first_duplicate = &first_duplicate,
            .first_environment_observed = &first_environment_observed,
        },
    );

    try std.testing.expectEqual(@as(usize, 1), app.update_count);
    try std.testing.expect(first_environment_observed);
    const first_fd = first_duplicate orelse return error.TestUnexpectedResult;
    try std.testing.expect(!foregroundCommandProgramTestFdOpen(first_fd));
    try std.testing.expectEqual(@as(u8, 1), app_ctx.requests._pending_foreground_commands_len);

    const follow_up = app_ctx.requests._pending_foreground_commands[0].input.childCwd();
    const second_fd = switch (follow_up) {
        .dir => |dir| dir.handle,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(foregroundCommandProgramTestFdOpen(second_fd));
    const follow_up_environment = app_ctx.requests._pending_foreground_commands[0].input.childEnvironment() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("second", follow_up_environment.get("ISSUE55_OWNER").?);
    app_ctx.requests.discardPendingEffects();
    try std.testing.expect(!foregroundCommandProgramTestFdOpen(second_fd));
}

test "foreground cleanup covers runner outcome and delivery terminals with replacement environment" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const Mode = enum {
        terminal_leave_error,
        terminal_restore_error,
        spawn_failure,
        wait_failure,
        exited,
        signaled,
        app_update_error,
        cleanup_failure,
        tty_restore_failure,
        stopped,
    };
    const TestMsg = union(enum) {
        finished,

        pub const undelivered_policy = .plain;
    };
    const TestApp = struct {
        fail_update: bool,
        updates: usize = 0,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), _: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            self.updates += 1;
            if (self.fail_update) return error.InjectedAppUpdate;
        }
    };
    const Runner = struct {
        mode: Mode,
        duplicate_fd: *?std.Io.Dir.Handle,

        fn run(
            self: @This(),
            entry: *const requests_mod.Requests(TestMsg).ForegroundCommandEntry,
        ) !foreground_command.ForegroundCommandOutcome {
            self.duplicate_fd.* = switch (entry.input.childCwd()) {
                .dir => |dir| dir.handle,
                else => return error.TestUnexpectedResult,
            };
            const environment = entry.input.childEnvironment() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("owned", environment.get("ISSUE55_TERMINAL").?);
            return switch (self.mode) {
                .terminal_leave_error => error.InjectedTerminalLeave,
                .terminal_restore_error => error.InjectedTerminalRestore,
                .spawn_failure => foreground_job.failure(.spawn, "InjectedSpawn"),
                .wait_failure => foreground_job.failure(.wait, "InjectedWait"),
                .exited, .app_update_error => .{ .exited = 0 },
                .signaled => .{ .signaled = 15 },
                .stopped => .{ .stopped = 20 },
                .cleanup_failure => foreground_job.failure(.cleanup, "ChildAuthorityLost"),
                .tty_restore_failure => foreground_job.failure(.restore_tty, "InjectedRestore"),
            };
        }
    };
    const Completion = struct {
        var calls: usize = 0;
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            calls += 1;
            return .finished;
        }
    };
    const Harness = struct {
        fn run(mode: Mode, expected_error: ?anyerror) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.createDir(std.testing.io, "caller", .default_dir);
            const caller_dir = try tmp.dir.openDir(std.testing.io, "caller", .{});
            defer caller_dir.close(std.testing.io);
            var caller_environment: std.process.Environ.Map = .init(std.testing.allocator);
            defer caller_environment.deinit();
            try caller_environment.put("ISSUE55_TERMINAL", "owned");

            var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
            var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
            defer app_ctx.requests.discardPendingEffects();
            Completion.calls = 0;
            _ = try app_ctx.terminal().runForegroundCommand(.{
                .argv = &.{"command"},
                .cwd = .{ .dir = caller_dir },
                .environment = .{ .replace = &caller_environment },
                .finished = Completion.done,
            });

            var duplicate_fd: ?std.Io.Dir.Handle = null;
            var app: TestApp = .{ .fail_update = mode == .app_update_error };
            var stats: ?runtime.RuntimeStats = null;
            const result = processPendingForegroundCommandsWithRunner(
                TestApp,
                &app,
                &app_ctx,
                std.testing.allocator,
                std.testing.io,
                &stats,
                .{
                    .runtime = .{
                        .allocator = std.testing.allocator,
                        .io = std.testing.io,
                    },
                    .terminal = undefined,
                },
                Runner{ .mode = mode, .duplicate_fd = &duplicate_fd },
            );
            if (result) |_| {
                try std.testing.expect(expected_error == null);
            } else |err| {
                try std.testing.expectEqual(expected_error orelse return err, err);
            }

            try std.testing.expectEqual(@as(usize, 1), Completion.calls);
            try std.testing.expectEqual(@as(usize, if (expected_error != null and expected_error.? == error.ForegroundRecoveryFailed) 0 else 1), app.updates);
            const owned_fd = duplicate_fd orelse return error.TestUnexpectedResult;
            try std.testing.expect(!foregroundCommandProgramTestFdOpen(owned_fd));
            try std.testing.expect(foregroundCommandProgramTestFdOpen(caller_dir.handle));
            try std.testing.expectEqual(@as(u8, 0), app_ctx.requests._pending_foreground_commands_len);
        }
    };

    const cases = [_]struct { mode: Mode, expected_error: ?anyerror }{
        .{ .mode = .terminal_leave_error, .expected_error = error.ForegroundRecoveryFailed },
        .{ .mode = .terminal_restore_error, .expected_error = error.ForegroundRecoveryFailed },
        .{ .mode = .spawn_failure, .expected_error = null },
        .{ .mode = .wait_failure, .expected_error = null },
        .{ .mode = .exited, .expected_error = null },
        .{ .mode = .signaled, .expected_error = null },
        .{ .mode = .app_update_error, .expected_error = error.InjectedAppUpdate },
        .{ .mode = .cleanup_failure, .expected_error = error.ForegroundRecoveryFailed },
        .{ .mode = .tty_restore_failure, .expected_error = error.ForegroundRecoveryFailed },
        .{ .mode = .stopped, .expected_error = null },
    };
    for (cases) |case| try Harness.run(case.mode, case.expected_error);
}

test "foreground shutdown abandons queued command once and rejects followups" {
    const Harness = struct {
        var calls: usize = 0;
        var frees: usize = 0;
        const Msg = struct {
            pub const undelivered_policy = .deinit;
            bytes: []u8,
            pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
                allocator.free(self.bytes);
                frees += 1;
            }
        };
        fn done(result: foreground_command.ForegroundCommandResult) Msg {
            std.debug.assert(result.outcome == .runtime_abandoned);
            calls += 1;
            return .{ .bytes = std.testing.allocator.dupe(u8, "completion") catch unreachable };
        }
    };
    Harness.calls = 0;
    Harness.frees = 0;
    var app_ctx_requests = requests_mod.Requests(Harness.Msg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(Harness.Msg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{ .argv = &.{"never-spawn"}, .finished = Harness.done });
    app_ctx.quit();
    discardQueuedForegroundCommands(Harness.Msg, &app_ctx, std.testing.allocator);
    discardQueuedForegroundCommands(Harness.Msg, &app_ctx, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), Harness.calls);
    try std.testing.expectEqual(@as(usize, 1), Harness.frees);
    try std.testing.expectError(error.ForegroundCommandRuntimeStopped, app_ctx.terminal().runForegroundCommand(.{ .argv = &.{"never-spawn"}, .finished = Harness.done }));
}
