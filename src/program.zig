const std = @import("std");
const vaxis = @import("vaxis");
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const ctx_mod = @import("ctx.zig");
const root = @import("root.zig");

fn InternalEvent(comptime Msg: type) type {
    return union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
        mouse: vaxis.Mouse,
        focus_in,
        focus_out,

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

/// A running timer tracked by id so it can be cancelled.
const TimerHandle = struct {
    id: []const u8,
    future: std.Io.Future(void),
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

    var vx = try vaxis.Vaxis.init(io, allocator, opts.env_map, .{});
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
    }

    // Initial render
    try render(App, &vx, &frame_arena, &app, tty.writer());

    // --- Main loop ---
    while (!app_ctx.should_quit) {
        const event = try loop.nextEvent();
        var needs_render = false;

        switch (event) {
            .key_press => |key| {
                if (app.handleEvent(.{ .key_press = key })) |msg| {
                    try app.update(msg, &app_ctx);
                    needs_render = true;
                }
            },
            .winsize => |ws| {
                // Keep the vaxis screen in sync first, then let the app react to resize.
                try vx.resize(allocator, tty.writer(), ws);
                if (app.handleEvent(.{ .winsize = ws })) |msg| {
                    try app.update(msg, &app_ctx);
                }
                needs_render = true;
            },
            .user_msg => |msg| {
                try app.update(msg, &app_ctx);
                needs_render = true;
            },
            .mouse => |m| {
                if (app.handleEvent(.{ .mouse = m })) |msg| {
                    try app.update(msg, &app_ctx);
                    needs_render = true;
                }
            },
            .focus_in => {
                if (app.handleEvent(.focus_in)) |msg| {
                    try app.update(msg, &app_ctx);
                    needs_render = true;
                }
            },
            .focus_out => {
                if (app.handleEvent(.focus_out)) |msg| {
                    try app.update(msg, &app_ctx);
                    needs_render = true;
                }
            },
        }

        // Process tasks, ticks, and everys spawned during update
        try spawnPendingTasks(Msg, &app_ctx, &pending_futures, allocator, io, &loop);
        try spawnPendingTicks(Msg, &app_ctx, &running_timers, allocator, io, &loop);
        try spawnPendingEvery(Msg, &app_ctx, &running_timers, allocator, io, &loop);
        processPendingCancels(Msg, &app_ctx, &running_timers, io);

        if (needs_render) {
            try render(App, &vx, &frame_arena, &app, tty.writer());
        }
    }
}

/// Starts tasks queued in Ctx and tracks their futures for shutdown.
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

fn render(
    comptime App: type,
    vx: *vaxis.Vaxis,
    frame_arena: *std.heap.ArenaAllocator,
    app: *const App,
    writer: *std.Io.Writer,
) !void {
    _ = frame_arena.reset(.retain_capacity);
    const win = vx.window();
    win.clear();
    var sfc: Surface = .{
        .window = win,
        .arena = frame_arena.allocator(),
    };
    try app.view(&sfc);
    try vx.render(writer);
}

test "InternalEvent instantiation" {
    const TestMsg = union(enum) { hello, value: u32 };
    const Event = InternalEvent(TestMsg);

    const ev: Event = .{ .user_msg = .hello };
    try std.testing.expect(ev == .user_msg);

    const key_ev: Event = .{ .key_press = .{ .codepoint = 'a' } };
    try std.testing.expect(key_ev == .key_press);
}

test "SpawnHelper instantiation" {
    const TestMsg = union(enum) { hello };
    const Helper = SpawnHelper(TestMsg);
    // Verify the run function has the expected type signature
    const RunFn = @TypeOf(Helper.run);
    try std.testing.expect(RunFn != void);
}
