const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const ctx_mod = @import("ctx.zig");
const root = @import("root.zig");
const terminal_image = @import("terminal_image.zig");
const foreground_command = @import("foreground_command.zig");

const frame_interval_ns: u64 = std.time.ns_per_s / 60;
const max_foreground_drain_rounds: usize = 8;

const EffectDrainResult = struct {
    needs_render: bool = false,
};

fn InternalEvent(comptime Msg: type) type {
    return union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
        mouse: vaxis.Mouse,
        focus_in,
        focus_out,
        paste: []const u8,
        paste_start,
        paste_end,
        frame: root.Frame,
        frame_canceled,

        /// Async task result injected via postEvent.
        user_msg: Msg,
    };
}

fn postInternalEvent(comptime Msg: type, loop_ptr: *vaxis.Loop(InternalEvent(Msg)), event: InternalEvent(Msg)) void {
    // vaxis' event queue survives loop.stop()/loop.start() and blocks on
    // normal backpressure. Remaining errors are teardown/cancel paths where
    // the runtime is no longer able to deliver app messages.
    loop_ptr.postEvent(event) catch {};
}

/// Converts terminal bracketed-paste marker events into one public Event.paste.
///
/// vaxis exposes bracketed paste as `paste_start`, many ordinary `key_press`
/// events, then `paste_end`. Apps should not have to know that transport detail:
/// they should receive one paste payload and should never see the intermediate
/// key events as normal typing.
const BracketedPasteAccumulator = struct {
    active: bool = false,
    failed: bool = false,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn start(self: *BracketedPasteAccumulator, allocator: std.mem.Allocator) void {
        self.cancel(allocator);
        self.active = true;
    }

    fn appendKey(self: *BracketedPasteAccumulator, allocator: std.mem.Allocator, key: vaxis.Key) !void {
        if (!self.active) return;
        if (self.failed) return;

        // Prefer vaxis' decoded text. The slice is event-scoped, so copy it
        // before the next parser event can reuse the backing buffer.
        if (key.text) |text| {
            try self.bytes.appendSlice(allocator, text);
            return;
        }

        if (pasteControlText(key)) |text| {
            try self.bytes.appendSlice(allocator, text);
            return;
        }

        if (key.mods.ctrl) return;
        if (!isPasteTextCodepoint(key.codepoint)) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(key.codepoint, &buf) catch return;
        try self.bytes.appendSlice(allocator, buf[0..len]);
    }

    fn finish(self: *BracketedPasteAccumulator, allocator: std.mem.Allocator) ?[]u8 {
        if (!self.active) return null;
        self.active = false;

        if (self.failed) {
            self.failed = false;
            self.bytes.clearRetainingCapacity();
            return null;
        }
        if (self.bytes.items.len == 0) {
            self.bytes.clearRetainingCapacity();
            return null;
        }
        if (!std.unicode.utf8ValidateSlice(self.bytes.items)) {
            self.bytes.clearRetainingCapacity();
            return null;
        }

        return self.bytes.toOwnedSlice(allocator) catch {
            self.bytes.clearRetainingCapacity();
            return null;
        };
    }

    fn fail(self: *BracketedPasteAccumulator) void {
        // Keep `active` true so the rest of this bracketed paste is swallowed
        // until `paste_end`; otherwise a failed paste tail becomes key input.
        self.active = true;
        self.failed = true;
        self.bytes.clearRetainingCapacity();
    }

    fn cancel(self: *BracketedPasteAccumulator, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.active = false;
        self.failed = false;
        self.bytes.clearRetainingCapacity();
    }

    fn deinit(self: *BracketedPasteAccumulator, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }
};

fn isPasteTextCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        '\n', vaxis.Key.tab, vaxis.Key.enter => true,
        0x20...0xD7FF, 0xE000...0x10FFFF => codepoint < vaxis.Key.insert or codepoint > vaxis.Key.iso_level_5_shift,
        else => false,
    };
}

fn pasteControlText(key: vaxis.Key) ?[]const u8 {
    if (!key.mods.ctrl) return null;
    if (key.mods.alt or key.mods.super or key.mods.hyper or key.mods.meta) return null;
    if (key.codepoint > std.math.maxInt(u8)) return null;

    // Some terminals report pasted LF/TAB/CR through their legacy control-key
    // encodings (Ctrl+J / Ctrl+I / Ctrl+M) without decoded `key.text`.
    // Treat only those textual controls as paste bytes; other Ctrl keys are
    // shortcuts/special input and must not become printable letters.
    return switch (std.ascii.toLower(@as(u8, @intCast(key.codepoint)))) {
        'i' => "\t",
        'j' => "\n",
        'm' => "\r",
        else => null,
    };
}

/// Runs a user task and posts its result back into the vaxis event loop.
fn SpawnHelper(comptime Msg: type) type {
    const Event = InternalEvent(Msg);
    return struct {
        fn run(
            task: ctx_mod.Ctx(Msg).TaskEntry,
            alloc: std.mem.Allocator,
            spawn_io: std.Io,
            loop_ptr: *vaxis.Loop(Event),
        ) void {
            const msg = task.run(alloc, spawn_io);
            postInternalEvent(Msg, loop_ptr, .{ .user_msg = msg });
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
            postInternalEvent(Msg, loop_ptr, .{ .user_msg = msg });
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
            postInternalEvent(Msg, loop_ptr, .{ .user_msg = msg });
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
            suspended: *std.atomic.Value(bool),
        ) void {
            while (true) {
                every_io.sleep(.fromNanoseconds(@intCast(interval_ns)), .awake) catch return;
                if (suspended.load(.seq_cst)) continue;
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
            suspended: *std.atomic.Value(bool),
        ) void {
            frame_io.sleep(.fromNanoseconds(@intCast(after_ns)), .awake) catch return;
            if (suspended.load(.seq_cst)) {
                postInternalEvent(Msg, loop_ptr, .frame_canceled);
                return;
            }
            const now_ns = timestampNs(frame_io);
            postInternalEvent(Msg, loop_ptr, .{ .frame = .{
                .now_ns = now_ns,
                .delta_ns = deltaNs(last_frame_ns, now_ns),
                .index = index,
            } });
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
    const allocator = opts.runtime.allocator;
    const io = opts.runtime.io;

    // --- Terminal setup ---
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.Vaxis.init(io, allocator, opts.terminal.env_map, .{
        .system_clipboard_allocator = allocator,
    });
    useUnicodeWidth(&vx);
    defer vx.deinit(allocator, tty.writer());

    var terminal_images: terminal_image.Registry = .{};
    defer {
        terminal_images.freeAll(vx, tty.writer());
        terminal_images.deinit(allocator);
    }

    // --- Event loop setup ---
    // Start the loop before querying the terminal. queryTerminal waits for
    // terminal capability responses, which are read and processed by the loop.
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try queryTerminal(&vx, tty.writer(), io, .fromSeconds(1), opts.terminal.keyboard_protocol);

    // Bracketed paste belongs to Chasen's terminal ownership. It is enabled
    // by default so apps can receive Event.paste instead of raw paste markers.
    try vx.setBracketedPaste(tty.writer(), true);
    defer {
        _ = vx.setBracketedPaste(tty.writer(), false) catch {};
    }

    if (opts.terminal.mouse) {
        try vx.setMouseMode(tty.writer(), true);
    }
    defer {
        if (opts.terminal.mouse) {
            _ = vx.setMouseMode(tty.writer(), false) catch {};
        }
    }

    if (!vx.state.in_band_resize) try loop.installResizeHandler();

    // --- Frame arena ---
    var frame_arena: std.heap.ArenaAllocator = .init(allocator);
    defer frame_arena.deinit();

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
    // Ctx keeps Io privately so user code can call ctx.now() without receiving
    // direct access to the runtime Io handle.
    var app_ctx: ctx_mod.Ctx(Msg) = .{ ._io = io, ._allocator = allocator };
    defer app_ctx.clearPendingEffectCopies();
    var frame_in_flight = false;
    var frame_future: ?std.Io.Future(void) = null;
    defer {
        if (frame_future) |*f| {
            _ = f.cancel(io);
        }
    }
    var last_frame_ns = timestampNs(io);
    var next_frame_index: u64 = 0;
    var runtime_suspended: std.atomic.Value(bool) = .init(false);
    var bracketed_paste: BracketedPasteAccumulator = .{};
    defer bracketed_paste.deinit(allocator);
    var event_count: u64 = 0;
    var frame_count: u64 = 0;
    const stats_enabled = opts.runtime.stats_fn != null;

    // --- Pending futures (for spawned async tasks) ---
    // Completed one-shot futures remain in this list until shutdown because
    // std.Io.Future has no non-blocking completion check. They are awaited
    // instead of cancelled: app task callbacks return `Msg`, not a cancelable
    // result, so forcing cancelation can make a task turn `error.Canceled` into
    // an ordinary failure message and continue into the next I/O operation.
    var pending_futures: std.ArrayList(std.Io.Future(void)) = .empty;
    defer {
        for (pending_futures.items) |*f| {
            _ = f.await(io);
        }
        pending_futures.deinit(allocator);
    }

    // --- Running timers (id-tracked for cancel support) ---
    // Completed one-shot ticks remain here until shutdown because std.Io.Future
    // has no non-blocking completion check. This is not a leak, but apps should
    // avoid creating unbounded unique timer ids in long-lived sessions.
    var running_timers: std.ArrayList(TimerHandle) = .empty;
    defer {
        for (running_timers.items) |*h| {
            _ = h.future.cancel(io);
            allocator.free(h.id);
        }
        running_timers.deinit(allocator);
    }

    trace(opts, .startup);

    if (@hasDecl(App, "init")) {
        try app.init(&app_ctx);
        // Process tasks, ticks, and everys spawned during init
        trace(opts, .effect_drain_start);
        var init_stats: ?root.RuntimeStats = null;
        _ = try drainPendingEffects(App, &app, &app_ctx, &pending_futures, &running_timers, &terminal_images, &vx, &tty, allocator, io, &loop, &runtime_suspended, &frame_in_flight, &frame_future, last_frame_ns, next_frame_index, &init_stats, opts);
        trace(opts, .effect_drain_end);
    }

    // Deliver the initial terminal size before the first render. Resize events
    // only arrive after the terminal changes, but apps often need the current
    // size for first-frame layout and scroll bounds.
    if (tty.getWinsize()) |ws| {
        var initial_stats: ?root.RuntimeStats = null;
        // Keep the vaxis screen size in sync before the first render. The app
        // also receives the winsize event below to initialize layout state.
        try vx.resize(allocator, tty.writer(), ws);
        useUnicodeWidth(&vx);
        trace(opts, .event_received);
        _ = try dispatchAppEvent(App, &app, .{ .winsize = ws }, &app_ctx, io, &initial_stats, opts);
        trace(opts, .effect_drain_start);
        _ = try drainPendingEffects(App, &app, &app_ctx, &pending_futures, &running_timers, &terminal_images, &vx, &tty, allocator, io, &loop, &runtime_suspended, &frame_in_flight, &frame_future, last_frame_ns, next_frame_index, &initial_stats, opts);
        trace(opts, .effect_drain_end);
    } else |_| {}

    // Initial render
    _ = try render(App, &vx, &terminal_images, &frame_arena, &app, tty.writer(), io, false, opts);

    // --- Main loop ---
    while (!app_ctx.should_quit) {
        const event = try loop.nextEvent();
        trace(opts, .event_received);
        event_count += 1;
        var needs_render = false;
        var stats: ?root.RuntimeStats = if (stats_enabled) .{
            .event_kind = eventKind(event),
            .event_count = event_count,
            .frame_count = frame_count,
        } else null;

        switch (event) {
            .key_press => |key| {
                if (bracketed_paste.active) {
                    // These key events are paste payload bytes, not app input.
                    // Swallow them and dispatch one Event.paste at paste_end.
                    if (stats) |*s| s.event_kind = .paste;
                    bracketed_paste.appendKey(allocator, key) catch {
                        bracketed_paste.fail();
                    };
                } else {
                    needs_render = try dispatchAppEvent(App, &app, .{ .key_press = key }, &app_ctx, io, &stats, opts);
                }
            },
            .winsize => |ws| {
                // Resize always redraws so the screen buffer matches the new
                // terminal size; redraw().skip() only applies to app-driven messages.
                try vx.resize(allocator, tty.writer(), ws);
                useUnicodeWidth(&vx);
                _ = try dispatchAppEvent(App, &app, .{ .winsize = ws }, &app_ctx, io, &stats, opts);
                needs_render = true;
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
            .paste => |text| {
                bracketed_paste.cancel(allocator);
                defer allocator.free(text);
                needs_render = try dispatchAppEvent(App, &app, .{ .paste = text }, &app_ctx, io, &stats, opts);
            },
            .paste_start => {
                bracketed_paste.start(allocator);
                if (stats) |*s| s.event_kind = .paste;
            },
            .paste_end => {
                if (stats) |*s| s.event_kind = .paste;
                if (bracketed_paste.finish(allocator)) |text| {
                    defer allocator.free(text);
                    needs_render = try dispatchAppEvent(App, &app, .{ .paste = text }, &app_ctx, io, &stats, opts);
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
                needs_render = try dispatchAppEvent(App, &app, .{ .frame = frame }, &app_ctx, io, &stats, opts);
            },
            .frame_canceled => {
                if (frame_future) |*f| {
                    _ = f.await(io);
                    frame_future = null;
                }
                frame_in_flight = false;
                app_ctx.frame_requested = true;
                if (stats) |*s| s.event_kind = .frame;
            },
        }

        // Process tasks, ticks, and everys spawned during update
        trace(opts, .effect_drain_start);
        const effect_drain_start = timingStart(stats_enabled, io);
        if (app_ctx.pending_foreground_commands_len > 0) {
            bracketed_paste.cancel(allocator);
        }
        // Drain effects even when the app already requested a redraw; using
        // short-circuit `or` here would delay queued effects until the next event.
        const effect_result = try drainPendingEffects(App, &app, &app_ctx, &pending_futures, &running_timers, &terminal_images, &vx, &tty, allocator, io, &loop, &runtime_suspended, &frame_in_flight, &frame_future, last_frame_ns, next_frame_index, &stats, opts);
        needs_render = needs_render or effect_result.needs_render;
        if (stats) |*s| s.effect_drain_ns = timingElapsed(effect_drain_start, io);
        trace(opts, .effect_drain_end);

        if (needs_render) {
            const timings = try render(App, &vx, &terminal_images, &frame_arena, &app, tty.writer(), io, stats_enabled, opts);
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

fn queryTerminal(
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    io: std.Io,
    timeout: std.Io.Duration,
    keyboard_protocol: root.KeyboardProtocol,
) !void {
    // Split vaxis' query/wait/enable flow so Chasen can keep enhanced
    // keyboard reporting opt-in while still using the other detected features.
    try vx.queryTerminalSend(writer);
    try std.Io.futexWaitTimeout(
        io,
        std.atomic.Value(u32),
        &vx.query_futex,
        .init(0),
        .{
            .duration = .{
                .clock = .real,
                .raw = timeout,
            },
        },
    );

    vx.queries_done.store(true, .unordered);
    if (keyboard_protocol == .legacy) {
        vx.caps.kitty_keyboard = false;
    }
    try vx.enableDetectedFeatures(writer);
}

/// Route an app-facing event through optional `handleEvent`, then apply the
/// returned message if the app handled it.
///
/// This keeps the common handleEvent/update/stat timing path in one place.
/// Event-specific runtime work, such as terminal resize or frame-future
/// cleanup, stays in the switch branch before this helper is called.
fn dispatchAppEvent(
    comptime App: type,
    app: *App,
    event: root.Event,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    io: std.Io,
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
) !bool {
    const measure = stats.* != null;
    trace(opts, .handle_event_start);
    const handle_start = timingStart(measure, io);
    const maybe_msg: ?App.Msg = if (@hasDecl(App, "handleEvent"))
        app.handleEvent(event)
    else
        null;

    if (stats.*) |*s| {
        s.handle_event_ns = timingElapsed(handle_start, io);
    }
    trace(opts, .handle_event_end);

    if (maybe_msg) |msg| {
        return try applyMsg(App, app, msg, app_ctx, io, stats, opts);
    }

    return false;
}

/// Apply one app message and return whether the app requested a redraw.
///
/// `ctx.redraw().skip()` is message-scoped, so the flag is reset immediately
/// before each app update. The helper also owns update timing and the
/// `did_update` stats flag, which avoids duplicating that bookkeeping across
/// every event kind.
fn applyMsg(
    comptime App: type,
    app: *App,
    msg: App.Msg,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    io: std.Io,
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
) !bool {
    const measure = stats.* != null;
    app_ctx.redraw_suppressed = false;

    trace(opts, .update_start);
    const update_start = timingStart(measure, io);
    try app.update(msg, app_ctx);

    if (stats.*) |*s| {
        s.update_ns = timingElapsed(update_start, io);
        s.did_update = true;
    }
    trace(opts, .update_end);

    return !app_ctx.redraw_suppressed;
}

/// Drains effects queued in Ctx using the documented per-pass runtime order:
///
/// 1. foreground commands
/// 2. async tasks
/// 3. pending timer cancels
/// 4. pending ticks
/// 5. pending everys
/// 6. terminal images
/// 7. frame request
///
/// Timer cancels must run after foreground callbacks have had a chance to
/// queue effects, but before tick/every spawn. That makes `cancel(id)` apply
/// to timers that were already running before this drain pass, while allowing
/// a same-update `cancel(id); tick(id, ...)` restart to keep the replacement.
///
/// Foreground command completions may queue follow-up foreground commands.
/// Drain a bounded number of full passes so those follow-ups do not wait for
/// unrelated input/timer/frame events, while preserving the same per-pass order.
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
    pending_futures: *std.ArrayList(std.Io.Future(void)),
    running_timers: *std.ArrayList(TimerHandle),
    terminal_images: *terminal_image.Registry,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(App.Msg)),
    suspended: *std.atomic.Value(bool),
    frame_in_flight: *bool,
    frame_future: *?std.Io.Future(void),
    last_frame_ns: u64,
    next_frame_index: u64,
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
) !EffectDrainResult {
    var result: EffectDrainResult = .{};
    const Msg = App.Msg;

    for (0..max_foreground_drain_rounds) |_| {
        const foreground_needs_render = try processPendingForegroundCommands(App, app, app_ctx, vx, tty, allocator, io, loop, suspended, opts.terminal.mouse, opts.terminal.keyboard_protocol, stats, opts);
        result.needs_render = result.needs_render or foreground_needs_render;
        try spawnPendingTasks(Msg, app_ctx, pending_futures, allocator, io, loop);
        processPendingCancels(Msg, app_ctx, running_timers, allocator, io);
        try spawnPendingTicks(Msg, app_ctx, running_timers, allocator, io, loop);
        try spawnPendingEvery(Msg, app_ctx, running_timers, allocator, io, loop, suspended);
        try processPendingTerminalImages(Msg, app_ctx, terminal_images, vx, tty.writer(), allocator, loop, opts);
        startPendingFrame(Msg, app_ctx, io, loop, suspended, frame_in_flight, frame_future, last_frame_ns, next_frame_index);

        if (app_ctx.pending_foreground_commands_len == 0) break;
    }

    return result;
}

fn processPendingForegroundCommands(
    comptime App: type,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(App.Msg)),
    suspended: *std.atomic.Value(bool),
    mouse_enabled: bool,
    keyboard_protocol: root.KeyboardProtocol,
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
) !bool {
    // This iterates Ctx storage directly. That is safe while the foreground
    // queue capacity is 1; if capacity grows, copy entries out before callbacks
    // can queue new commands into the same backing array.
    const pending_commands = app_ctx.pendingForegroundCommandSlice();
    app_ctx.pending_foreground_commands_len = 0;
    var needs_render = false;

    for (pending_commands) |entry| {
        defer freeForegroundCommandEntry(allocator, entry);

        const outcome = try runForegroundCommand(vx, tty, allocator, io, loop, suspended, mouse_enabled, keyboard_protocol, entry);
        const result: foreground_command.ForegroundCommandResult = .{
            .request_id = entry.request_id,
            .outcome = outcome,
        };
        needs_render = try applyMsg(App, app, entry.finished(result), app_ctx, io, stats, opts) or needs_render;
    }

    return needs_render;
}

fn freeForegroundCommandEntry(
    allocator: std.mem.Allocator,
    entry: anytype,
) void {
    for (entry.argv) |arg| {
        allocator.free(arg);
    }
    allocator.free(entry.argv);
    if (entry.cwd) |cwd| allocator.free(cwd);
}

fn runForegroundCommand(
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: anytype,
    suspended: *std.atomic.Value(bool),
    mouse_enabled: bool,
    keyboard_protocol: root.KeyboardProtocol,
    entry: anytype,
) !foreground_command.ForegroundCommandOutcome {
    if (builtin.os.tag == .windows) {
        return .{ .spawn_failed = "Unsupported" };
    }

    suspended.store(true, .seq_cst);
    defer suspended.store(false, .seq_cst);

    // Mouse reporting is part of Chasen's terminal ownership. Disable it
    // before handing /dev/tty to an interactive child process.
    if (mouse_enabled) {
        _ = vx.setMouseMode(tty.writer(), false) catch {};
    }
    // Do not leak Chasen's paste mode into the foreground child process.
    _ = vx.setBracketedPaste(tty.writer(), false) catch {};
    loop.stop();
    _ = vx.exitAltScreen(tty.writer()) catch {};

    // Keep the parent /dev/tty fd open. Closing and reopening it would leave
    // run()'s deferred cleanup with a deinitialized tty if re-init failed.
    try leaveRawMode(tty);

    const outcome = runChildOnControllingTty(io, entry.argv, entry.cwd);
    try restoreTerminalAfterForeground(vx, tty, allocator, io, loop, mouse_enabled, keyboard_protocol);

    return outcome;
}

fn runChildOnControllingTty(
    io: std.Io,
    argv: []const []const u8,
    cwd: ?[]const u8,
) foreground_command.ForegroundCommandOutcome {
    var child_tty = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch |err| {
        return .{ .spawn_failed = @errorName(err) };
    };
    defer child_tty.close(io);

    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = if (cwd) |path| .{ .path = path } else .inherit,
        .stdin = .{ .file = child_tty },
        .stdout = .{ .file = child_tty },
        .stderr = .{ .file = child_tty },
    }) catch |err| {
        return .{ .spawn_failed = @errorName(err) };
    };

    const term = child.wait(io) catch |err| {
        child.kill(io);
        return .{ .wait_failed = @errorName(err) };
    };

    return switch (term) {
        .exited => |code| .{ .exited = code },
        .signal => |sig| .{ .signaled = @intCast(@intFromEnum(sig)) },
        .stopped => |sig| .{ .signaled = @intCast(@intFromEnum(sig)) },
        .unknown => .{ .wait_failed = "UnknownTermination" },
    };
}

fn restoreTerminalAfterForeground(
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: anytype,
    mouse_enabled: bool,
    keyboard_protocol: root.KeyboardProtocol,
) !void {
    try enterRawMode(tty);
    try loop.start();
    try vx.enterAltScreen(tty.writer());

    // Capability and size refresh are useful after returning from an editor,
    // but failure here should not leave the runtime stopped.
    queryTerminal(vx, tty.writer(), io, .fromSeconds(1), keyboard_protocol) catch {};
    if (mouse_enabled) {
        _ = vx.setMouseMode(tty.writer(), true) catch {};
    }
    _ = vx.setBracketedPaste(tty.writer(), true) catch {};

    if (tty.getWinsize()) |ws| {
        vx.resize(allocator, tty.writer(), ws) catch {};
        useUnicodeWidth(vx);
    } else |_| {}
}

fn leaveRawMode(tty: *vaxis.Tty) !void {
    if (builtin.os.tag == .windows) return error.Unsupported;
    try std.posix.tcsetattr(tty.fd.handle, .FLUSH, tty.termios);
}

fn enterRawMode(tty: *vaxis.Tty) !void {
    if (builtin.os.tag == .windows) return error.Unsupported;
    tty.termios = try vaxis.Tty.makeRaw(tty.fd.handle);
}

/// Starts tasks queued in Ctx and tracks their futures for shutdown.
/// Task start failures are delivered through the app-provided failure callback
/// before ownership is transferred to the concurrent task body.
fn spawnPendingTasks(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    pending_futures: *std.ArrayList(std.Io.Future(void)),
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
) !void {
    for (app_ctx.pendingSlice()) |task| {
        pending_futures.ensureUnusedCapacity(allocator, 1) catch |err| {
            postInternalEvent(Msg, loop, .{ .user_msg = task.failed(.{ .start_failed = @errorName(err) }) });
            continue;
        };
        const future = io.concurrent(
            SpawnHelper(Msg).run,
            .{ task, allocator, io, loop },
        ) catch |err| {
            postInternalEvent(Msg, loop, .{ .user_msg = task.failed(.{ .start_failed = @errorName(err) }) });
            continue;
        };
        pending_futures.appendAssumeCapacity(future);
    }
    app_ctx.pending_tasks_len = 0;

    for (app_ctx.pendingTaskWithSlice()) |entry| {
        pending_futures.ensureUnusedCapacity(allocator, 1) catch |err| {
            postInternalEvent(Msg, loop, .{ .user_msg = entry.failed(entry.ctx, .{ .start_failed = @errorName(err) }, allocator) });
            continue;
        };
        const future = io.concurrent(
            SpawnWithHelper(Msg).run,
            .{ entry.ctx, entry.run, allocator, io, loop },
        ) catch |err| {
            postInternalEvent(Msg, loop, .{ .user_msg = entry.failed(entry.ctx, .{ .start_failed = @errorName(err) }, allocator) });
            continue;
        };
        pending_futures.appendAssumeCapacity(future);
    }
    app_ctx.pending_tasks_with_len = 0;
}

fn startPendingFrame(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    suspended: *std.atomic.Value(bool),
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
        .{ frame_interval_ns, last_frame_ns, next_frame_index, io, loop, suspended },
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
    // Take ownership of queued copies before processing. Zeroing the queue
    // first keeps run()'s unwind cleanup from freeing ids after they have been
    // handed to running_timers.
    const pending_ticks = app_ctx.pendingTickSlice();
    app_ctx.pending_ticks_len = 0;

    for (pending_ticks) |entry| {
        var owned_id: ?[]const u8 = entry.id;
        defer if (owned_id) |id| allocator.free(id);

        // Cancel existing timer with the same id.
        cancelRunningTimer(running_timers, allocator, entry.id, io);

        var future = io.concurrent(
            TickHelper(Msg).run,
            .{ entry.after_ns, entry.msg, io, loop },
        ) catch continue;
        running_timers.append(allocator, .{ .id = entry.id, .future = future }) catch {
            _ = future.cancel(io);
            continue;
        };
        owned_id = null;
    }
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
    suspended: *std.atomic.Value(bool),
) !void {
    // Take ownership of queued copies before processing. Zeroing the queue
    // first keeps run()'s unwind cleanup from freeing ids after they have been
    // handed to running_timers.
    const pending_everys = app_ctx.pendingEverySlice();
    app_ctx.pending_everys_len = 0;

    for (pending_everys) |entry| {
        var owned_id: ?[]const u8 = entry.id;
        defer if (owned_id) |id| allocator.free(id);

        // Cancel existing timer with the same id.
        cancelRunningTimer(running_timers, allocator, entry.id, io);

        var future = io.concurrent(
            EveryHelper(Msg).run,
            .{ entry.interval_ns, entry.msg, io, loop, suspended },
        ) catch continue;
        running_timers.append(allocator, .{ .id = entry.id, .future = future }) catch {
            _ = future.cancel(io);
            continue;
        };
        owned_id = null;
    }
}

/// Cancel a running timer by id (swap-remove).
fn cancelRunningTimer(running_timers: *std.ArrayList(TimerHandle), allocator: std.mem.Allocator, id: []const u8, io: std.Io) void {
    var i: usize = 0;
    while (i < running_timers.items.len) {
        if (std.mem.eql(u8, running_timers.items[i].id, id)) {
            _ = running_timers.items[i].future.cancel(io);
            allocator.free(running_timers.items[i].id);
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
    allocator: std.mem.Allocator,
    io: std.Io,
) void {
    // Take ownership of queued cancel ids before processing so unwind cleanup
    // only sees entries that have not reached the drain step.
    const pending_cancels = app_ctx.pendingCancelSlice();
    app_ctx.pending_cancels_len = 0;

    for (pending_cancels) |id| {
        defer allocator.free(id);
        cancelRunningTimer(running_timers, allocator, id, io);
    }
}

fn processPendingTerminalImages(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    registry: *terminal_image.Registry,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    opts: root.RunOptions,
) !void {
    // Take ownership of queued image effects before processing so unwind
    // cleanup only sees entries that have not reached the drain step.
    const pending_unloads = app_ctx.pendingTerminalImageUnloadSlice();
    app_ctx.pending_terminal_image_unloads_len = 0;

    for (pending_unloads) |handle| {
        _ = registry.unload(vx.*, tty, handle);
    }

    const pending_loads = app_ctx.pendingTerminalImageLoadSlice();
    app_ctx.pending_terminal_image_loads_len = 0;

    for (pending_loads) |entry| {
        defer allocator.free(entry.path);

        switch (loadTerminalImagePath(registry, vx, tty, allocator, entry.path, opts)) {
            .loaded => |handle| {
                loop.postEvent(.{ .user_msg = entry.loaded(entry.request_id, handle) }) catch {
                    _ = registry.unload(vx.*, tty, handle);
                };
            },
            .failed => |reason| {
                loop.postEvent(.{ .user_msg = entry.failed(entry.request_id, reason) }) catch {};
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
    opts: root.RunOptions,
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
        .paste_start => .paste,
        .paste_end => .paste,
        .frame => .frame,
        .frame_canceled => .frame,
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

fn trace(opts: root.RunOptions, event: root.TraceEvent) void {
    if (opts.runtime.trace_fn) |trace_fn| {
        trace_fn(opts.runtime.trace_context, event);
    }
}

fn useUnicodeWidth(vx: *vaxis.Vaxis) void {
    vx.caps.unicode = .unicode;
    vx.screen.width_method = .unicode;
}

fn render(
    comptime App: type,
    vx: *vaxis.Vaxis,
    terminal_images: *terminal_image.Registry,
    frame_arena: *std.heap.ArenaAllocator,
    app: *const App,
    writer: *std.Io.Writer,
    io: std.Io,
    measure: bool,
    opts: root.RunOptions,
) !RenderTimings {
    // Reuse frame scratch capacity across renders to avoid per-frame allocator churn.
    _ = frame_arena.reset(.retain_capacity);

    const win = vx.window();
    win.clear();

    var sfc: Surface = .initVaxis(win, frame_arena.allocator(), terminal_images);

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

test "InternalEvent instantiation" {
    const TestMsg = union(enum) { hello, value: u32 };
    const Event = InternalEvent(TestMsg);

    const ev: Event = .{ .user_msg = .hello };
    try std.testing.expect(ev == .user_msg);

    const key_ev: Event = .{ .key_press = .{ .codepoint = 'a' } };
    try std.testing.expect(key_ev == .key_press);

    const paste_ev: Event = .{ .paste = "hello" };
    try std.testing.expect(paste_ev == .paste);

    const paste_start_ev: Event = .paste_start;
    try std.testing.expect(paste_start_ev == .paste_start);

    const paste_end_ev: Event = .paste_end;
    try std.testing.expect(paste_end_ev == .paste_end);

    const frame_ev: Event = .{ .frame = .{ .now_ns = 100, .delta_ns = 16, .index = 2 } };
    try std.testing.expect(frame_ev == .frame);
}

test "BracketedPasteAccumulator combines pasted key text" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start(allocator);
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.multicodepoint, .text = "hello" });
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.enter });
    try paste.appendKey(allocator, .{ .codepoint = '世', .text = "世界" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello\r世界", text);
}

test "BracketedPasteAccumulator restarts nested paste" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start(allocator);
    try paste.appendKey(allocator, .{ .codepoint = 'a', .text = "old" });
    paste.start(allocator);
    try paste.appendKey(allocator, .{ .codepoint = 'n', .text = "new" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("new", text);
}

test "BracketedPasteAccumulator ignores non-text special keys" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start(allocator);
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.up });
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.left_shift });

    try std.testing.expectEqual(@as(?[]u8, null), paste.finish(allocator));
}

test "BracketedPasteAccumulator drops invalid utf8" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    var invalid = [_]u8{0xff};
    paste.start(allocator);
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.multicodepoint, .text = invalid[0..] });

    try std.testing.expectEqual(@as(?[]u8, null), paste.finish(allocator));
}

test "BracketedPasteAccumulator failure swallows until paste end" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start(allocator);
    paste.fail();
    try paste.appendKey(allocator, .{ .codepoint = 't', .text = "tail" });

    try std.testing.expect(paste.active);
    try std.testing.expect(paste.failed);
    try std.testing.expectEqual(@as(?[]u8, null), paste.finish(allocator));
    try std.testing.expect(!paste.active);
    try std.testing.expect(!paste.failed);
}

test "BracketedPasteAccumulator maps ctrl-j paste key to newline" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start(allocator);
    try paste.appendKey(allocator, .{ .codepoint = 'a', .text = "aaaaa" });
    try paste.appendKey(allocator, .{ .codepoint = 'j', .mods = .{ .ctrl = true } });
    try paste.appendKey(allocator, .{ .codepoint = 'b', .text = "bbbbb" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("aaaaa\nbbbbb", text);
}

test "BracketedPasteAccumulator preserves direct line-feed codepoint" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start(allocator);
    try paste.appendKey(allocator, .{ .codepoint = 'a', .text = "aaaaa" });
    try paste.appendKey(allocator, .{ .codepoint = '\n' });
    try paste.appendKey(allocator, .{ .codepoint = 'b', .text = "bbbbb" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("aaaaa\nbbbbb", text);
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
