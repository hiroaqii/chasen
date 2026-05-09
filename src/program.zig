const std = @import("std");
const vaxis = @import("vaxis");
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const ctx_mod = @import("ctx.zig");
const root = @import("root.zig");

const frame_interval_ns: u64 = std.time.ns_per_s / 60;

fn InternalEvent(comptime Msg: type) type {
    return union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
        mouse: vaxis.Mouse,
        focus_in,
        focus_out,
        paste: []const u8,
        frame: root.Frame,

        /// Async task result injected via postEvent.
        user_msg: Msg,
    };
}

/// Runs a user task and posts its result back into the vaxis event loop.
fn SpawnHelper(comptime Msg: type) type {
    const Event = InternalEvent(Msg);
    return struct {
        fn run(
            task_fn: *const fn (std.mem.Allocator, std.Io) Msg,
            alloc: std.mem.Allocator,
            spawn_io: std.Io,
            loop_ptr: *vaxis.Loop(Event),
        ) void {
            const msg = task_fn(alloc, spawn_io);
            loop_ptr.postEvent(.{ .user_msg = msg }) catch {};
        }
    };
}

/// Runs a user task with captured context and posts its result back.
fn SpawnWithHelper(comptime Msg: type) type {
    const Event = InternalEvent(Msg);
    return struct {
        fn run(
            ctx_ptr: *anyopaque,
            run_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io) Msg,
            alloc: std.mem.Allocator,
            spawn_io: std.Io,
            loop_ptr: *vaxis.Loop(Event),
        ) void {
            const msg = run_fn(ctx_ptr, alloc, spawn_io);
            loop_ptr.postEvent(.{ .user_msg = msg }) catch {};
        }
    };
}

/// Sleeps for `after_ns` then posts `msg` once.
fn TickHelper(comptime Msg: type) type {
    const Event = InternalEvent(Msg);
    return struct {
        fn run(
            after_ns: u64,
            msg: Msg,
            tick_io: std.Io,
            loop_ptr: *vaxis.Loop(Event),
        ) void {
            tick_io.sleep(.fromNanoseconds(@intCast(after_ns)), .awake) catch return;
            loop_ptr.postEvent(.{ .user_msg = msg }) catch {};
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
        ) void {
            while (true) {
                every_io.sleep(.fromNanoseconds(@intCast(interval_ns)), .awake) catch return;
                loop_ptr.postEvent(.{ .user_msg = msg }) catch {};
            }
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
        ) void {
            frame_io.sleep(.fromNanoseconds(@intCast(after_ns)), .awake) catch return;
            const now_ns = timestampNs(frame_io);
            loop_ptr.postEvent(.{ .frame = .{
                .now_ns = now_ns,
                .delta_ns = deltaNs(last_frame_ns, now_ns),
                .index = index,
            } }) catch {};
        }
    };
}

/// A running timer tracked by id so it can be cancelled.
const TimerHandle = struct {
    id: []const u8,
    future: std.Io.Future(void),
};

const RenderTimings = struct {
    view_ns: u64 = 0,
    render_ns: u64 = 0,
};

pub fn run(comptime App: type, opts: root.RunOptions, initial_app: App) !void {
    const Msg = App.Msg;
    const Event = InternalEvent(Msg);
    const allocator = opts.allocator;
    const io = opts.io;

    // --- Terminal setup ---
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.Vaxis.init(io, allocator, opts.env_map, .{
        .system_clipboard_allocator = allocator,
    });
    useUnicodeWidth(&vx);
    defer vx.deinit(allocator, tty.writer());

    // --- Event loop setup ---
    // Start the loop before querying the terminal. queryTerminal waits for
    // terminal capability responses, which are read and processed by the loop.
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    if (!vx.state.in_band_resize) try loop.installResizeHandler();

    // --- Frame arena ---
    var frame_arena: std.heap.ArenaAllocator = .init(allocator);
    defer frame_arena.deinit();

    // --- App state ---
    var app = initial_app;
    // Ctx keeps Io privately so user code can call ctx.now() without receiving
    // direct access to the runtime Io handle.
    var app_ctx: ctx_mod.Ctx(Msg) = .{ ._io = io, ._allocator = allocator };
    var frame_in_flight = false;
    var frame_future: ?std.Io.Future(void) = null;
    defer {
        if (frame_future) |*f| {
            _ = f.cancel(io);
        }
    }
    var last_frame_ns = timestampNs(io);
    var next_frame_index: u64 = 0;
    var event_count: u64 = 0;
    var frame_count: u64 = 0;
    const stats_enabled = opts.stats_fn != null;

    // --- Pending futures (for spawned async tasks) ---
    // Completed one-shot futures (spawn/tick) remain in this list until
    // shutdown because std.Io.Future has no non-blocking completion check.
    // Memory impact is expected to be small for typical TUI usage.
    // All futures are cancelled in the defer block below.
    var pending_futures: std.ArrayList(std.Io.Future(void)) = .empty;
    defer {
        for (pending_futures.items) |*f| {
            _ = f.cancel(io);
        }
        pending_futures.deinit(allocator);
    }

    // --- Running timers (id-tracked for cancel support) ---
    var running_timers: std.ArrayList(TimerHandle) = .empty;
    defer {
        for (running_timers.items) |*h| {
            _ = h.future.cancel(io);
        }
        running_timers.deinit(allocator);
    }

    if (@hasDecl(App, "init")) {
        try app.init(&app_ctx);
        // Process tasks, ticks, and everys spawned during init
        try spawnPendingTasks(Msg, &app_ctx, &pending_futures, allocator, io, &loop);
        try spawnPendingTicks(Msg, &app_ctx, &running_timers, allocator, io, &loop);
        try spawnPendingEvery(Msg, &app_ctx, &running_timers, allocator, io, &loop);
        processPendingCancels(Msg, &app_ctx, &running_timers, io);
        startPendingFrame(Msg, &app_ctx, io, &loop, &frame_in_flight, &frame_future, last_frame_ns, next_frame_index);
    }

    // Initial render
    _ = try render(App, &vx, &frame_arena, &app, tty.writer(), io, false);

    // --- Main loop ---
    while (!app_ctx.should_quit) {
        const event = try loop.nextEvent();
        event_count += 1;
        var needs_render = false;
        var stats: ?root.RuntimeStats = if (stats_enabled) .{
            .event_kind = eventKind(event),
            .event_count = event_count,
            .frame_count = frame_count,
        } else null;

        switch (event) {
            .key_press => |key| {
                const handle_start = timingStart(stats_enabled, io);
                if (app.handleEvent(.{ .key_press = key })) |msg| {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                    app_ctx.redraw_suppressed = false;
                    const update_start = timingStart(stats_enabled, io);
                    try app.update(msg, &app_ctx);
                    if (stats) |*s| {
                        s.update_ns = timingElapsed(update_start, io);
                        s.did_update = true;
                    }
                    if (!app_ctx.redraw_suppressed) needs_render = true;
                } else {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                }
            },
            .winsize => |ws| {
                // Resize always redraws so the screen buffer matches the new
                // terminal size; suppressRedraw only applies to app-driven messages.
                try vx.resize(allocator, tty.writer(), ws);
                useUnicodeWidth(&vx);
                const handle_start = timingStart(stats_enabled, io);
                if (app.handleEvent(.{ .winsize = ws })) |msg| {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                    const update_start = timingStart(stats_enabled, io);
                    try app.update(msg, &app_ctx);
                    if (stats) |*s| {
                        s.update_ns = timingElapsed(update_start, io);
                        s.did_update = true;
                    }
                } else {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                }
                needs_render = true;
            },
            .user_msg => |msg| {
                app_ctx.redraw_suppressed = false;
                const update_start = timingStart(stats_enabled, io);
                try app.update(msg, &app_ctx);
                if (stats) |*s| {
                    s.update_ns = timingElapsed(update_start, io);
                    s.did_update = true;
                }
                if (!app_ctx.redraw_suppressed) needs_render = true;
            },
            .mouse => |m| {
                const handle_start = timingStart(stats_enabled, io);
                if (app.handleEvent(.{ .mouse = m })) |msg| {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                    app_ctx.redraw_suppressed = false;
                    const update_start = timingStart(stats_enabled, io);
                    try app.update(msg, &app_ctx);
                    if (stats) |*s| {
                        s.update_ns = timingElapsed(update_start, io);
                        s.did_update = true;
                    }
                    if (!app_ctx.redraw_suppressed) needs_render = true;
                } else {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                }
            },
            .focus_in => {
                const handle_start = timingStart(stats_enabled, io);
                if (app.handleEvent(.focus_in)) |msg| {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                    app_ctx.redraw_suppressed = false;
                    const update_start = timingStart(stats_enabled, io);
                    try app.update(msg, &app_ctx);
                    if (stats) |*s| {
                        s.update_ns = timingElapsed(update_start, io);
                        s.did_update = true;
                    }
                    if (!app_ctx.redraw_suppressed) needs_render = true;
                } else {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                }
            },
            .focus_out => {
                const handle_start = timingStart(stats_enabled, io);
                if (app.handleEvent(.focus_out)) |msg| {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                    app_ctx.redraw_suppressed = false;
                    const update_start = timingStart(stats_enabled, io);
                    try app.update(msg, &app_ctx);
                    if (stats) |*s| {
                        s.update_ns = timingElapsed(update_start, io);
                        s.did_update = true;
                    }
                    if (!app_ctx.redraw_suppressed) needs_render = true;
                } else {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                }
            },
            .paste => |text| {
                defer allocator.free(text);
                const handle_start = timingStart(stats_enabled, io);
                if (app.handleEvent(.{ .paste = text })) |msg| {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                    app_ctx.redraw_suppressed = false;
                    const update_start = timingStart(stats_enabled, io);
                    try app.update(msg, &app_ctx);
                    if (stats) |*s| {
                        s.update_ns = timingElapsed(update_start, io);
                        s.did_update = true;
                    }
                    if (!app_ctx.redraw_suppressed) needs_render = true;
                } else {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                }
            },
            .frame => |frame| {
                frame_count += 1;
                if (stats) |*s| s.frame_count = frame_count;
                if (frame_future) |*f| {
                    _ = f.await(io);
                    frame_future = null;
                }
                frame_in_flight = false;
                last_frame_ns = frame.now_ns;
                next_frame_index = frame.index + 1;
                const handle_start = timingStart(stats_enabled, io);
                if (app.handleEvent(.{ .frame = frame })) |msg| {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                    app_ctx.redraw_suppressed = false;
                    const update_start = timingStart(stats_enabled, io);
                    try app.update(msg, &app_ctx);
                    if (stats) |*s| {
                        s.update_ns = timingElapsed(update_start, io);
                        s.did_update = true;
                    }
                    if (!app_ctx.redraw_suppressed) needs_render = true;
                } else {
                    if (stats) |*s| s.handle_event_ns = timingElapsed(handle_start, io);
                }
            },
        }

        // Process tasks, ticks, and everys spawned during update
        const effect_drain_start = timingStart(stats_enabled, io);
        try spawnPendingTasks(Msg, &app_ctx, &pending_futures, allocator, io, &loop);
        try spawnPendingTicks(Msg, &app_ctx, &running_timers, allocator, io, &loop);
        try spawnPendingEvery(Msg, &app_ctx, &running_timers, allocator, io, &loop);
        processPendingCancels(Msg, &app_ctx, &running_timers, io);
        startPendingFrame(Msg, &app_ctx, io, &loop, &frame_in_flight, &frame_future, last_frame_ns, next_frame_index);
        if (stats) |*s| s.effect_drain_ns = timingElapsed(effect_drain_start, io);

        if (needs_render) {
            const timings = try render(App, &vx, &frame_arena, &app, tty.writer(), io, stats_enabled);
            if (stats) |*s| {
                s.view_ns = timings.view_ns;
                s.render_ns = timings.render_ns;
                s.did_render = true;
            }
        }

        if (opts.stats_fn) |stats_fn| {
            stats_fn(opts.stats_context, stats.?);
        }
    }
}

/// Starts tasks queued in Ctx and tracks their futures for shutdown.
/// Ctx.spawn/spawnWith only guarantee queueing; runtime start failures
/// are currently dropped and may become observable via a future error hook.
fn spawnPendingTasks(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    pending_futures: *std.ArrayList(std.Io.Future(void)),
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
) !void {
    for (app_ctx.pendingSlice()) |task_fn| {
        var future = io.concurrent(
            SpawnHelper(Msg).run,
            .{ task_fn, allocator, io, loop },
        ) catch continue;
        pending_futures.append(allocator, future) catch {
            _ = future.cancel(io);
            continue;
        };
    }
    app_ctx.pending_tasks_len = 0;

    for (app_ctx.pendingTaskWithSlice()) |entry| {
        var future = io.concurrent(
            SpawnWithHelper(Msg).run,
            .{ entry.ctx, entry.run, allocator, io, loop },
        ) catch continue;
        pending_futures.append(allocator, future) catch {
            _ = future.cancel(io);
            continue;
        };
    }
    app_ctx.pending_tasks_with_len = 0;
}

fn startPendingFrame(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    frame_in_flight: *bool,
    frame_future: *?std.Io.Future(void),
    last_frame_ns: u64,
    next_frame_index: u64,
) void {
    if (!app_ctx.frame_requested) return;
    app_ctx.frame_requested = false;

    if (frame_in_flight.*) return;

    frame_future.* = io.concurrent(
        FrameHelper(Msg).run,
        .{ frame_interval_ns, last_frame_ns, next_frame_index, io, loop },
    ) catch return;
    frame_in_flight.* = true;
}

/// Starts tick timers queued in Ctx and tracks their futures for shutdown.
/// If a running timer with the same id exists, it is cancelled first.
fn spawnPendingTicks(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    running_timers: *std.ArrayList(TimerHandle),
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
) !void {
    for (app_ctx.pendingTickSlice()) |entry| {
        // Cancel existing timer with the same id.
        cancelRunningTimer(running_timers, entry.id, io);

        var future = io.concurrent(
            TickHelper(Msg).run,
            .{ entry.after_ns, entry.msg, io, loop },
        ) catch continue;
        running_timers.append(allocator, .{ .id = entry.id, .future = future }) catch {
            _ = future.cancel(io);
            continue;
        };
    }
    app_ctx.pending_ticks_len = 0;
}

/// Starts repeating timers queued in Ctx and tracks their futures for shutdown.
/// If a running timer with the same id exists, it is cancelled first.
fn spawnPendingEvery(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    running_timers: *std.ArrayList(TimerHandle),
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
) !void {
    for (app_ctx.pendingEverySlice()) |entry| {
        // Cancel existing timer with the same id.
        cancelRunningTimer(running_timers, entry.id, io);

        var future = io.concurrent(
            EveryHelper(Msg).run,
            .{ entry.interval_ns, entry.msg, io, loop },
        ) catch continue;
        running_timers.append(allocator, .{ .id = entry.id, .future = future }) catch {
            _ = future.cancel(io);
            continue;
        };
    }
    app_ctx.pending_everys_len = 0;
}

/// Cancel a running timer by id (swap-remove).
fn cancelRunningTimer(running_timers: *std.ArrayList(TimerHandle), id: []const u8, io: std.Io) void {
    var i: usize = 0;
    while (i < running_timers.items.len) {
        if (std.mem.eql(u8, running_timers.items[i].id, id)) {
            _ = running_timers.items[i].future.cancel(io);
            _ = running_timers.swapRemove(i);
        } else {
            i += 1;
        }
    }
}

/// Process pending cancel requests from Ctx.
fn processPendingCancels(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    running_timers: *std.ArrayList(TimerHandle),
    io: std.Io,
) void {
    for (app_ctx.pendingCancelSlice()) |id| {
        cancelRunningTimer(running_timers, id, io);
    }
    app_ctx.pending_cancels_len = 0;
}

fn timestampNs(io: std.Io) u64 {
    const ns = std.Io.Clock.now(.awake, io).nanoseconds;
    if (ns <= 0) return 0;
    return std.math.lossyCast(u64, ns);
}

fn deltaNs(previous_ns: u64, now_ns: u64) u64 {
    if (now_ns <= previous_ns) return 0;
    return now_ns - previous_ns;
}

fn eventKind(event: anytype) root.RuntimeEventKind {
    return switch (event) {
        .key_press => .key_press,
        .winsize => .winsize,
        .user_msg => .user_msg,
        .mouse => .mouse,
        .focus_in => .focus_in,
        .focus_out => .focus_out,
        .paste => .paste,
        .frame => .frame,
    };
}

fn timingStart(enabled: bool, io: std.Io) u64 {
    return if (enabled) timestampNs(io) else 0;
}

fn timingElapsed(start_ns: u64, io: std.Io) u64 {
    return elapsedNs(start_ns, timestampNs(io));
}

fn elapsedNs(start_ns: u64, end_ns: u64) u64 {
    return deltaNs(start_ns, end_ns);
}

fn useUnicodeWidth(vx: *vaxis.Vaxis) void {
    vx.caps.unicode = .unicode;
    vx.screen.width_method = .unicode;
}

fn render(
    comptime App: type,
    vx: *vaxis.Vaxis,
    frame_arena: *std.heap.ArenaAllocator,
    app: *const App,
    writer: *std.Io.Writer,
    io: std.Io,
    measure: bool,
) !RenderTimings {
    _ = frame_arena.reset(.retain_capacity);
    const win = vx.window();
    win.clear();
    var sfc: Surface = .{
        .window = win,
        .arena = frame_arena.allocator(),
    };
    const view_start = timingStart(measure, io);
    try app.view(&sfc);
    const view_ns = if (measure) timingElapsed(view_start, io) else 0;
    const render_start = timingStart(measure, io);
    try vx.render(writer);
    const render_ns = if (measure) timingElapsed(render_start, io) else 0;

    return .{
        .view_ns = view_ns,
        .render_ns = render_ns,
    };
}

test "InternalEvent instantiation" {
    const TestMsg = union(enum) { hello, value: u32 };
    const Event = InternalEvent(TestMsg);

    const ev: Event = .{ .user_msg = .hello };
    try std.testing.expect(ev == .user_msg);

    const key_ev: Event = .{ .key_press = .{ .codepoint = 'a' } };
    try std.testing.expect(key_ev == .key_press);

    const paste_ev: Event = .{ .paste = "hello" };
    try std.testing.expect(paste_ev == .paste);

    const frame_ev: Event = .{ .frame = .{ .now_ns = 100, .delta_ns = 16, .index = 2 } };
    try std.testing.expect(frame_ev == .frame);
}

test "SpawnHelper instantiation" {
    const TestMsg = union(enum) { hello };
    const Helper = SpawnHelper(TestMsg);
    // Verify the run function has the expected type signature
    const RunFn = @TypeOf(Helper.run);
    try std.testing.expect(RunFn != void);
}

test "FrameHelper instantiation" {
    const TestMsg = union(enum) { hello };
    const Helper = FrameHelper(TestMsg);
    const RunFn = @TypeOf(Helper.run);
    try std.testing.expect(RunFn != void);
}

test "deltaNs clamps non-monotonic timestamps" {
    try std.testing.expectEqual(@as(u64, 5), deltaNs(10, 15));
    try std.testing.expectEqual(@as(u64, 0), deltaNs(10, 10));
    try std.testing.expectEqual(@as(u64, 0), deltaNs(10, 9));
}

test "elapsedNs uses deltaNs clamping" {
    try std.testing.expectEqual(@as(u64, 5), elapsedNs(10, 15));
    try std.testing.expectEqual(@as(u64, 0), elapsedNs(10, 9));
}

test "timingStart returns zero when timing is disabled" {
    const io: std.Io = undefined;
    try std.testing.expectEqual(@as(u64, 0), timingStart(false, io));
}
