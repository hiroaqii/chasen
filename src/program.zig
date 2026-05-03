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
    var app_ctx: ctx_mod.Ctx(Msg) = .{};

    // --- Pending futures (for spawned async tasks) ---
    var pending_futures: std.ArrayList(std.Io.Future(void)) = .empty;
    defer {
        for (pending_futures.items) |*f| {
            _ = f.cancel(io);
        }
        pending_futures.deinit(allocator);
    }

    if (@hasDecl(App, "init")) {
        app.init(&app_ctx);
        // Process tasks and ticks spawned during init
        try spawnPendingTasks(Msg, &app_ctx, &pending_futures, allocator, io, &loop);
        try spawnPendingTicks(Msg, &app_ctx, &pending_futures, allocator, io, &loop);
    }

    // Initial render
    try render(App, &vx, &frame_arena, &app, tty.writer());

    // --- Main loop ---
    while (!app_ctx.should_quit) {
        const event = try loop.nextEvent();
        var needs_render = false;

        switch (event) {
            .key_press => |key| {
                if (App.handleKey(key)) |msg| {
                    app.update(msg, &app_ctx);
                    needs_render = true;
                }
            },
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
                needs_render = true;
            },
            .user_msg => |msg| {
                app.update(msg, &app_ctx);
                needs_render = true;
            },
            .mouse => {},
            .focus_in => {},
            .focus_out => {},
        }

        // Process tasks and ticks spawned during update
        try spawnPendingTasks(Msg, &app_ctx, &pending_futures, allocator, io, &loop);
        try spawnPendingTicks(Msg, &app_ctx, &pending_futures, allocator, io, &loop);

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
fn spawnPendingTicks(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    pending_futures: *std.ArrayList(std.Io.Future(void)),
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
) !void {
    for (app_ctx.pendingTickSlice()) |entry| {
        var future = io.concurrent(
            TickHelper(Msg).run,
            .{ entry.after_ns, entry.msg, io, loop },
        ) catch continue;
        pending_futures.append(allocator, future) catch {
            _ = future.cancel(io);
            continue;
        };
    }
    app_ctx.pending_ticks_len = 0;
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
    app.view(&sfc);
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
