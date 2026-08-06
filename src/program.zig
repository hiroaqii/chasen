const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const ctx_mod = @import("ctx.zig");
const root = @import("root.zig");
const terminal_image = @import("terminal_image.zig");
const terminal_mouse = @import("terminal_mouse.zig");
const foreground_command = @import("foreground_command.zig");
const runtime_limits = @import("runtime_limits.zig");

const frame_interval_ns: u64 = std.time.ns_per_s / 60;
const resize_poll_interval_ns: u64 = 100 * std.time.ns_per_ms;
const max_effect_drain_rounds: usize = 8;
const delivery_retry_ns: u64 = 100 * std.time.ns_per_us;

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
        // Deliberately no libvaxis `.paste` field. Chasen does not expose an
        // OSC 52 clipboard-read request; ordinary user paste is assembled from
        // the bracketed-paste markers below. Without this field libvaxis frees
        // an unsolicited OSC 52 response immediately instead of transferring
        // allocator-owned text through its blocking event-queue post.
        paste_start,
        paste_end,
        frame: root.Frame,
        frame_canceled,
        /// Non-owning wake for a coalesced resize poll. The latest size is
        /// stored outside the bounded queue so a full queue never loses the
        /// final resize.
        resize_pending,
        /// Wakes the main loop when a bounded synchronous effect drain leaves
        /// work for another pass. It carries no app-owned payload.
        continue_effect_drain,

        /// Async task result injected via postEvent.
        user_msg: Msg,
    };
}

fn ResizePollState(comptime Msg: type) type {
    return struct {
        const Self = @This();

        tty: *vaxis.Tty,
        loop: *vaxis.Loop(InternalEvent(Msg)),
        sequence: std.atomic.Value(u32) = .init(0),
        cells: std.atomic.Value(u32) = .init(0),
        pixels: std.atomic.Value(u32) = .init(0),
        pending: std.atomic.Value(bool) = .init(false),
        stopping: std.atomic.Value(bool) = .init(false),
        initial: ?vaxis.Winsize = null,

        fn init(tty: *vaxis.Tty, loop: *vaxis.Loop(InternalEvent(Msg))) Self {
            return .{ .tty = tty, .loop = loop };
        }

        fn seed(self: *Self, winsize: vaxis.Winsize) void {
            self.initial = winsize;
        }

        /// Poll outside std.Io's bounded concurrency pool. This preserves the
        /// supported concurrency-limit-1 configuration, where the vaxis tty
        /// reader already owns the only std.Io concurrent slot.
        fn run(self: *Self) void {
            var last = self.initial;
            while (!self.stopping.load(.acquire)) {
                if (!sleepInterval()) return;
                if (self.stopping.load(.acquire)) return;
                const winsize = self.tty.getWinsize() catch continue;
                if (last) |previous| {
                    if (winsizeEqual(previous, winsize)) continue;
                }
                last = winsize;
                self.publish(winsize);
            }
        }

        fn stop(self: *Self) void {
            self.stopping.store(true, .release);
        }

        /// Publish the latest dimensions from an ordinary polling thread.
        ///
        /// A small sequence lock gives the runtime a consistent pair of 32-bit
        /// snapshots even on targets where atomic u64 is unavailable. The wake
        /// does not wait for queue capacity: if the queue is full, an existing
        /// event wakes the consumer, which checks `pending` before dispatch.
        fn publish(self: *Self, winsize: vaxis.Winsize) void {
            _ = self.sequence.fetchAdd(1, .acq_rel);
            self.cells.store(packPair(winsize.rows, winsize.cols), .unordered);
            self.pixels.store(packPair(winsize.x_pixel, winsize.y_pixel), .unordered);
            _ = self.sequence.fetchAdd(1, .release);
            self.pending.store(true, .release);
            _ = self.loop.tryPostEvent(.resize_pending) catch false;
        }

        /// Consume one coalesced snapshot. A concurrent later signal either
        /// becomes this snapshot or leaves `pending` set for the next turn.
        fn takeLatest(self: *Self) ?vaxis.Winsize {
            if (!self.pending.swap(false, .acquire)) return null;

            while (true) {
                const before = self.sequence.load(.acquire);
                if (before & 1 != 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                const cells = self.cells.load(.unordered);
                const pixels = self.pixels.load(.unordered);
                const after = self.sequence.load(.acquire);
                if (before == after) {
                    return .{
                        .rows = unpackLow(cells),
                        .cols = unpackHigh(cells),
                        .x_pixel = unpackLow(pixels),
                        .y_pixel = unpackHigh(pixels),
                    };
                }
            }
        }

        fn packPair(low: u16, high: u16) u32 {
            return @as(u32, low) | (@as(u32, high) << 16);
        }

        fn unpackLow(value: u32) u16 {
            return @truncate(value);
        }

        fn unpackHigh(value: u32) u16 {
            return @truncate(value >> 16);
        }

        fn winsizeEqual(lhs: vaxis.Winsize, rhs: vaxis.Winsize) bool {
            return lhs.rows == rhs.rows and
                lhs.cols == rhs.cols and
                lhs.x_pixel == rhs.x_pixel and
                lhs.y_pixel == rhs.y_pixel;
        }

        fn sleepInterval() bool {
            switch (builtin.os.tag) {
                .windows => return false,
                else => {
                    var duration: std.posix.timespec = .{
                        .sec = 0,
                        .nsec = @intCast(resize_poll_interval_ns),
                    };
                    while (true) {
                        switch (std.posix.errno(std.posix.system.nanosleep(&duration, &duration))) {
                            .SUCCESS => return true,
                            .INTR => continue,
                            else => return false,
                        }
                    }
                },
            }
        }
    };
}

fn TaskDelivery(comptime Msg: type) type {
    return union(enum) {
        posted,
        undelivered: Msg,
    };
}

fn PendingTaskFuture(comptime Msg: type) type {
    return std.Io.Future(TaskDelivery(Msg));
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

/// Post a plain/copy-safe internal event without blocking shutdown behind a
/// full queue. Timer templates are documented as non-owning in the current API.
fn postPlainUntilShutdown(
    comptime Msg: type,
    event: InternalEvent(Msg),
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    shutting_down: *const std.atomic.Value(bool),
) void {
    while (!shutting_down.load(.seq_cst)) {
        const posted = loop.tryPostEvent(event) catch return;
        if (posted) return;
        io.sleep(.fromNanoseconds(delivery_retry_ns), .awake) catch return;
    }
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

    fn start(self: *BracketedPasteAccumulator) void {
        self.cancel();
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

    fn cancel(self: *BracketedPasteAccumulator) void {
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
            shutting_down: *const std.atomic.Value(bool),
        ) TaskDelivery(Msg) {
            const msg = task.run(alloc, spawn_io);
            return transferTaskMessage(Msg, msg, spawn_io, loop_ptr, shutting_down);
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
            shutting_down: *const std.atomic.Value(bool),
        ) TaskDelivery(Msg) {
            const msg = run_fn(ctx_ptr, alloc, spawn_io);
            return transferTaskMessage(Msg, msg, spawn_io, loop_ptr, shutting_down);
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
            shutting_down: *const std.atomic.Value(bool),
        ) void {
            tick_io.sleep(.fromNanoseconds(@intCast(after_ns)), .awake) catch return;
            postPlainUntilShutdown(Msg, .{ .user_msg = msg }, tick_io, loop_ptr, shutting_down);
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
            shutting_down: *const std.atomic.Value(bool),
        ) void {
            while (!shutting_down.load(.seq_cst)) {
                every_io.sleep(.fromNanoseconds(@intCast(interval_ns)), .awake) catch return;
                if (suspended.load(.seq_cst)) continue;
                postPlainUntilShutdown(Msg, .{ .user_msg = msg }, every_io, loop_ptr, shutting_down);
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
            shutting_down: *const std.atomic.Value(bool),
        ) void {
            frame_io.sleep(.fromNanoseconds(@intCast(after_ns)), .awake) catch return;
            if (suspended.load(.seq_cst)) {
                postPlainUntilShutdown(Msg, .frame_canceled, frame_io, loop_ptr, shutting_down);
                return;
            }
            const now_ns = timestampNs(frame_io);
            postPlainUntilShutdown(Msg, .{ .frame = .{
                .now_ns = now_ns,
                .delta_ns = deltaNs(last_frame_ns, now_ns),
                .index = index,
            } }, frame_io, loop_ptr, shutting_down);
        }
    };
}

/// A running timer tracked by id so it can be cancelled.
const TimerHandle = struct {
    id: []const u8,
    future: std.Io.Future(void),
};

fn RuntimeCompletionBuffer(comptime Msg: type) type {
    return struct {
        const Self = @This();
        // A single drain pass can manufacture at most one completion per
        // queued task start failure and terminal image load. Preallocating the
        // sum keeps runtime-thread callbacks allocation-free, which avoids an
        // error path that would otherwise need another callback transport.
        const capacity = runtime_limits.max_tasks + runtime_limits.max_terminal_image_loads;

        items: std.ArrayList(Msg) = .empty,

        fn init(self: *Self, allocator: std.mem.Allocator) !void {
            try self.items.ensureTotalCapacityPrecise(allocator, capacity);
        }

        fn append(self: *Self, msg: Msg) error{RuntimeCompletionLimitExceeded}!void {
            if (self.items.items.len >= capacity) return error.RuntimeCompletionLimitExceeded;
            self.items.appendAssumeCapacity(msg);
        }

        fn deinitUndelivered(self: *Self, allocator: std.mem.Allocator) void {
            for (self.items.items) |*msg| {
                root.runtime.deinitUndeliveredMessage(Msg, msg, allocator);
            }
            self.items.deinit(allocator);
            self.* = .{};
        }
    };
}

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
        // libvaxis requires an allocator to decode OSC 52 responses. The
        // InternalEvent type intentionally omits its `.paste` field, so
        // libvaxis frees decoded text synchronously instead of queueing it.
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
    var mouse_reader = loopReader(&loop, io);
    const mouse_policy: terminal_mouse.Policy = .{
        .enabled = opts.terminal.mouse,
        .coordinate_protocol = opts.terminal.mouse_coordinate_protocol,
    };
    try loop.start();
    // Setup unwind uses the same cancellation-based reader stop as normal
    // shutdown. It must not depend on allocating an additional worker after
    // the tty producer has already started.
    errdefer stopLoopAndDrain(Msg, &loop, allocator, io);

    try vx.enterAltScreen(tty.writer());
    try queryTerminal(&vx, tty.writer(), io, .fromSeconds(1), opts.terminal.keyboard_protocol);

    // Bracketed paste belongs to Chasen's terminal ownership. It is enabled
    // by default so apps can receive Event.paste instead of raw paste markers.
    try vx.setBracketedPaste(tty.writer(), true);
    defer {
        _ = vx.setBracketedPaste(tty.writer(), false) catch {};
    }

    defer {
        // This also covers setup errors before shutdownRuntime owns the loop.
        // The reader must be stopped before every best-effort reset.
        _ = mouse_policy.leaveWithReader(&vx, tty.writer(), &mouse_reader) catch {};
    }
    if (mouse_policy.enabled) {
        try mouse_policy.enterWithReader(&vx, tty.writer(), &mouse_reader);
    }

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
    defer app_ctx.runtimeClearPendingEffectCopies();
    var frame_in_flight = false;
    var frame_future: ?std.Io.Future(void) = null;
    var last_frame_ns = timestampNs(io);
    var next_frame_index: u64 = 0;
    var runtime_suspended: std.atomic.Value(bool) = .init(false);
    var runtime_shutting_down: std.atomic.Value(bool) = .init(false);
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
    var pending_futures: std.ArrayList(PendingTaskFuture(Msg)) = .empty;

    // --- Running timers (id-tracked for cancel support) ---
    // Completed one-shot ticks remain here until shutdown because std.Io.Future
    // has no non-blocking completion check. This is not a leak, but apps should
    // avoid creating unbounded unique timer ids in long-lived sessions.
    var running_timers: std.ArrayList(TimerHandle) = .empty;
    var runtime_completions: RuntimeCompletionBuffer(Msg) = .{};
    try runtime_completions.init(allocator);
    var effect_drain_continuation_pending = false;

    // This defer runs before App.deinit and before the remaining terminal
    // resource defers. It is the single owner of started task outcomes,
    // queued-but-unstarted task contexts, and undelivered queue messages.
    defer shutdownRuntime(
        App,
        &app_ctx,
        &pending_futures,
        &running_timers,
        &runtime_completions,
        &frame_future,
        &loop,
        allocator,
        io,
        &runtime_shutting_down,
    );

    // POSIX signal callbacks cannot safely enter libvaxis' std.Io-mutex queue,
    // even through tryPostEvent. For terminals without in-band resize, poll
    // from an ordinary bounded-stack thread instead. It is intentionally not a
    // std.Io concurrent task: the supported concurrency-limit-1 configuration
    // already spends its only slot on the vaxis tty reader.
    var resize_poll = ResizePollState(Msg).init(&tty, &loop);
    const use_resize_poll = builtin.os.tag != .windows and !vx.state.in_band_resize;
    var resize_thread: ?std.Thread = null;
    defer if (resize_thread) |thread| {
        resize_poll.stop();
        thread.join();
        resize_thread = null;
    };

    trace(opts, .startup);

    if (@hasDecl(App, "init")) {
        try app.init(&app_ctx);
        // Process tasks, ticks, and everys spawned during init
        trace(opts, .effect_drain_start);
        var init_stats: ?root.RuntimeStats = null;
        _ = try drainPendingEffects(App, &app, &app_ctx, &pending_futures, &running_timers, &runtime_completions, &terminal_images, &vx, &tty, allocator, io, &loop, &runtime_suspended, &runtime_shutting_down, &frame_in_flight, &frame_future, &effect_drain_continuation_pending, last_frame_ns, next_frame_index, &init_stats, mouse_policy, opts);
        trace(opts, .effect_drain_end);
    }

    // Deliver the initial terminal size before the first render. Resize events
    // only arrive after the terminal changes, but apps often need the current
    // size for first-frame layout and scroll bounds.
    if (tty.getWinsize()) |ws| {
        resize_poll.seed(ws);
        var initial_stats: ?root.RuntimeStats = null;
        // Keep the vaxis screen size in sync before the first render. The app
        // also receives the winsize event below to initialize layout state.
        try vx.resize(allocator, tty.writer(), ws);
        useUnicodeWidth(&vx);
        trace(opts, .event_received);
        _ = try dispatchAppEvent(App, &app, .{ .winsize = ws }, &app_ctx, io, &initial_stats, opts);
        trace(opts, .effect_drain_start);
        _ = try drainPendingEffects(App, &app, &app_ctx, &pending_futures, &running_timers, &runtime_completions, &terminal_images, &vx, &tty, allocator, io, &loop, &runtime_suspended, &runtime_shutting_down, &frame_in_flight, &frame_future, &effect_drain_continuation_pending, last_frame_ns, next_frame_index, &initial_stats, mouse_policy, opts);
        trace(opts, .effect_drain_end);
    } else |_| {}

    // Initial render
    _ = try render(App, &vx, &terminal_images, &frame_arena, &app, tty.writer(), io, false, opts);

    if (use_resize_poll) {
        resize_thread = try std.Thread.spawn(.{
            .allocator = allocator,
        }, ResizePollState(Msg).run, .{&resize_poll});
    }

    // --- Main loop ---
    while (!app_ctx.shouldQuit()) {
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
                try applyTerminalResize(App, &vx, &tty, &app, &app_ctx, allocator, io, &stats, opts, ws);
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
            .paste_start => {
                bracketed_paste.start();
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
                app_ctx.frame().request();
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
        if (resize_poll.takeLatest()) |ws| {
            try applyTerminalResize(App, &vx, &tty, &app, &app_ctx, allocator, io, &stats, opts, ws);
            needs_render = true;
        }

        // Process tasks, ticks, and everys spawned during update
        trace(opts, .effect_drain_start);
        const effect_drain_start = timingStart(stats_enabled, io);
        if (app_ctx.hasPendingForegroundCommands()) {
            bracketed_paste.cancel();
        }
        // Drain effects even when the app already requested a redraw; using
        // short-circuit `or` here would delay queued effects until the next event.
        const effect_result = try drainPendingEffects(App, &app, &app_ctx, &pending_futures, &running_timers, &runtime_completions, &terminal_images, &vx, &tty, allocator, io, &loop, &runtime_suspended, &runtime_shutting_down, &frame_in_flight, &frame_future, &effect_drain_continuation_pending, last_frame_ns, next_frame_index, &stats, mouse_policy, opts);
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

/// Terminal teardown ownership barrier.
///
/// The ordinary app loop has stopped consuming events, but the tty and task
/// producers may still be running. Cancel the existing tty reader future,
/// dispose its remaining queue, then collect every task outcome before
/// App.deinit releases app state.
fn shutdownRuntime(
    comptime App: type,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    pending_futures: *std.ArrayList(PendingTaskFuture(App.Msg)),
    running_timers: *std.ArrayList(TimerHandle),
    runtime_completions: *RuntimeCompletionBuffer(App.Msg),
    frame_future: *?std.Io.Future(void),
    loop: *vaxis.Loop(InternalEvent(App.Msg)),
    allocator: std.mem.Allocator,
    io: std.Io,
    shutting_down: *std.atomic.Value(bool),
) void {
    shutting_down.store(true, .seq_cst);

    // Do not call Loop.stop here: its DSR wake + await can block behind a full
    // queue or a terminal that does not answer the query. Canceling the
    // existing reader future interrupts both tty reads and queue waits.
    stopLoopAndDrain(App.Msg, loop, allocator, io);

    if (frame_future.*) |*future| {
        _ = future.cancel(io);
        frame_future.* = null;
    }

    for (running_timers.items) |*handle| {
        _ = handle.future.cancel(io);
        allocator.free(handle.id);
    }
    running_timers.deinit(allocator);
    running_timers.* = .empty;

    // A worker outcome is exclusive: `.posted` means the queue owns the Msg;
    // `.undelivered` means the future still owns it. Drain once more after all
    // futures settle so every `.posted` outcome reaches typed cleanup too.
    for (pending_futures.items) |*future| {
        var outcome = future.await(io);
        switch (outcome) {
            .posted => {},
            .undelivered => |*msg| root.runtime.deinitUndeliveredMessage(App.Msg, msg, allocator),
        }
    }
    pending_futures.deinit(allocator);
    pending_futures.* = .empty;

    drainInternalEventsForShutdown(App.Msg, loop, allocator);
    runtime_completions.deinitUndelivered(allocator);
    discardQueuedTasks(App.Msg, app_ctx, allocator);
}

/// Stop the input producer without allocating another concurrent task, then
/// dispose every event that will no longer enter ordinary app dispatch.
fn stopLoopAndDrain(
    comptime Msg: type,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    allocator: std.mem.Allocator,
    io: std.Io,
) void {
    stopLoopReader(loop, io);
    drainInternalEventsForShutdown(Msg, loop, allocator);
}

fn LoopReader(comptime Loop: type) type {
    return struct {
        loop: *Loop,
        io: std.Io,

        pub fn stop(self: *@This()) void {
            stopLoopReader(self.loop, self.io);
        }

        pub fn start(self: *@This()) !void {
            try self.loop.start();
        }
    };
}

fn loopReader(loop: anytype, io: std.Io) LoopReader(@TypeOf(loop.*)) {
    return .{
        .loop = loop,
        .io = io,
    };
}

/// Cancel the already-started vaxis reader future in place.
///
/// `vaxis.Loop.stop` wakes the tty with a device-status query and then awaits
/// the reader. Chasen cannot use that blocking sequence when the reader may be
/// waiting to push into a full event queue, and allocating a helper future at
/// shutdown is not total for bounded or non-concurrent `std.Io` instances.
/// `Future.cancel` instead interrupts both tty reads and queue condition waits,
/// which are cancellation points in the supported concurrent Io contract.
/// No second concurrency slot and no terminal DSR response are required.
fn stopLoopReader(loop: anytype, io: std.Io) void {
    loop.should_quit = true;
    if (loop.thread) |*future| {
        _ = future.cancel(io);
        loop.thread = null;
    }
    loop.should_quit = false;
}

fn drainInternalEventsForShutdown(
    comptime Msg: type,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    allocator: std.mem.Allocator,
) void {
    while (loop.tryEvent() catch null) |event| {
        switch (event) {
            .user_msg => |value| {
                var msg = value;
                root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
            },
            else => {},
        }
    }
}

/// Error unwind may bypass `drainPendingEffects` after App.update queued task
/// entries. Reuse the failure callback so captured spawnWith context follows
/// its existing consume path, then dispose the manufactured undelivered Msg.
fn discardQueuedTasks(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    allocator: std.mem.Allocator,
) void {
    for (app_ctx.takePendingTasks()) |entry| {
        var msg = entry.failed(.runtime_abandoned);
        root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
    }
    for (app_ctx.takePendingTasksWith()) |entry| {
        var msg = entry.failed(entry.ctx, .runtime_abandoned, allocator);
        root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
    }
}

/// Apply one terminal-size snapshot and notify the application.
///
/// Both in-band resize events and coalesced polling state enter through this
/// runtime-thread boundary. The polling thread never resizes Vaxis or calls app
/// code itself.
fn applyTerminalResize(
    comptime App: type,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    io: std.Io,
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
    winsize: vaxis.Winsize,
) !void {
    try vx.resize(allocator, tty.writer(), winsize);
    useUnicodeWidth(vx);
    _ = try dispatchAppEvent(App, app, .{ .winsize = winsize }, app_ctx, io, stats, opts);
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
    app_ctx.resetRedrawSuppressed();

    trace(opts, .update_start);
    const update_start = timingStart(measure, io);
    try app.update(msg, app_ctx);

    if (stats.*) |*s| {
        s.update_ns = timingElapsed(update_start, io);
        s.did_update = true;
    }
    trace(opts, .update_end);

    return !app_ctx.redrawWasSuppressed();
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
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
) !EffectDrainResult {
    var result: EffectDrainResult = .{};
    var consumed: usize = 0;
    defer {
        for (completions.items.items[consumed..]) |*msg| {
            root.runtime.deinitUndeliveredMessage(App.Msg, msg, allocator);
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
    pending_futures: *std.ArrayList(PendingTaskFuture(App.Msg)),
    running_timers: *std.ArrayList(TimerHandle),
    runtime_completions: *RuntimeCompletionBuffer(App.Msg),
    terminal_images: *terminal_image.Registry,
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(App.Msg)),
    suspended: *std.atomic.Value(bool),
    shutting_down: *const std.atomic.Value(bool),
    frame_in_flight: *bool,
    frame_future: *?std.Io.Future(void),
    effect_drain_continuation_pending: *bool,
    last_frame_ns: u64,
    next_frame_index: u64,
    stats: *?root.RuntimeStats,
    mouse_policy: terminal_mouse.Policy,
    opts: root.RunOptions,
) !EffectDrainResult {
    var result: EffectDrainResult = .{};
    const Msg = App.Msg;

    for (0..max_effect_drain_rounds) |round| {
        const completion_result = try applyRuntimeCompletions(App, app, app_ctx, runtime_completions, allocator, io, stats, opts);
        result.needs_render = result.needs_render or completion_result.needs_render;
        const foreground_needs_render = try processPendingForegroundCommands(App, app, app_ctx, vx, tty, allocator, io, loop, suspended, mouse_policy, opts.terminal.keyboard_protocol, stats, opts);
        result.needs_render = result.needs_render or foreground_needs_render;
        const clipboard_needs_render = try processPendingClipboardCopies(App, app, app_ctx, vx, tty, allocator, io, stats, opts);
        result.needs_render = result.needs_render or clipboard_needs_render;
        try spawnPendingTasks(App, app_ctx, pending_futures, runtime_completions, allocator, io, loop, shutting_down);
        processPendingCancels(Msg, app_ctx, running_timers, allocator, io);
        try spawnPendingTicks(Msg, app_ctx, running_timers, allocator, io, loop, shutting_down);
        try spawnPendingEvery(Msg, app_ctx, running_timers, allocator, io, loop, suspended, shutting_down);
        try processPendingTerminalImages(Msg, app_ctx, runtime_completions, terminal_images, vx, tty.writer(), allocator, opts);
        startPendingFrame(Msg, app_ctx, io, loop, suspended, shutting_down, frame_in_flight, frame_future, last_frame_ns, next_frame_index);

        const has_follow_up = runtime_completions.items.items.len > 0 or
            app_ctx.hasPendingForegroundCommands() or
            app_ctx.hasPendingClipboardCopies();
        if (!has_follow_up) break;
        if (round + 1 == max_effect_drain_rounds) {
            try scheduleEffectDrainContinuation(Msg, loop, effect_drain_continuation_pending);
        }
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
    mouse_policy: terminal_mouse.Policy,
    keyboard_protocol: root.KeyboardProtocol,
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
) !bool {
    const Runner = struct {
        vx: *vaxis.Vaxis,
        tty: *vaxis.Tty,
        allocator: std.mem.Allocator,
        io: std.Io,
        loop: *vaxis.Loop(InternalEvent(App.Msg)),
        suspended: *std.atomic.Value(bool),
        mouse_policy: terminal_mouse.Policy,
        keyboard_protocol: root.KeyboardProtocol,

        fn run(
            self: @This(),
            entry: *const ctx_mod.Ctx(App.Msg).ForegroundCommandEntry,
        ) !foreground_command.ForegroundCommandOutcome {
            return runForegroundCommand(
                self.vx,
                self.tty,
                self.allocator,
                self.io,
                self.loop,
                self.suspended,
                self.mouse_policy,
                self.keyboard_protocol,
                entry,
            );
        }
    };

    return processPendingForegroundCommandsWithRunner(
        App,
        app,
        app_ctx,
        allocator,
        io,
        stats,
        opts,
        Runner{
            .vx = vx,
            .tty = tty,
            .allocator = allocator,
            .io = io,
            .loop = loop,
            .suspended = suspended,
            .mouse_policy = mouse_policy,
            .keyboard_protocol = keyboard_protocol,
        },
    );
}

fn processPendingForegroundCommandsWithRunner(
    comptime App: type,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    io: std.Io,
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
    runner: anytype,
) !bool {
    // The take API returns Ctx-backed storage. This is safe while the
    // foreground queue capacity is 1. Copy each owner by value before a
    // callback can queue into the same backing slot.
    const pending_commands = app_ctx.takePendingForegroundCommands();
    var needs_render = false;

    for (pending_commands) |queued_entry| {
        var entry = queued_entry;
        defer entry.runtimeDeinit(allocator);

        const outcome = try runner.run(&entry);
        const result: foreground_command.ForegroundCommandResult = .{
            .request_id = entry.request_id,
            .outcome = outcome,
        };
        needs_render = try applyMsg(App, app, entry.finished(result), app_ctx, io, stats, opts) or needs_render;
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
    stats: *?root.RuntimeStats,
    opts: root.RunOptions,
) !bool {
    const ClipboardEntry = ctx_mod.Ctx(App.Msg).ClipboardCopyEntry;
    const pending_copies = app_ctx.takePendingClipboardCopies();
    if (pending_copies.len == 0) return false;

    const entries = allocator.alloc(ClipboardEntry, pending_copies.len) catch |err| {
        for (pending_copies) |entry| allocator.free(entry.text);
        return err;
    };
    defer {
        for (entries) |entry| allocator.free(entry.text);
        allocator.free(entries);
    }

    @memcpy(entries, pending_copies);

    var needs_render = false;
    for (entries) |entry| {
        const outcome: ctx_mod.Ctx(App.Msg).ClipboardCopyOutcome = if (vx.*.copyToSystemClipboard(tty.writer(), entry.text, allocator)) |_| .sent else |err| .{ .write_failed = @errorName(err) };
        needs_render = try applyMsg(App, app, entry.finished(.{
            .request_id = entry.request_id,
            .outcome = outcome,
        }), app_ctx, io, stats, opts) or needs_render;
    }

    return needs_render;
}

fn runForegroundCommand(
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: anytype,
    suspended: *std.atomic.Value(bool),
    mouse_policy: terminal_mouse.Policy,
    keyboard_protocol: root.KeyboardProtocol,
    entry: anytype,
) !foreground_command.ForegroundCommandOutcome {
    if (builtin.os.tag == .windows) {
        return .{ .spawn_failed = "Unsupported" };
    }

    suspended.store(true, .seq_cst);
    defer suspended.store(false, .seq_cst);

    // Mouse reporting is part of Chasen's terminal ownership. Recover reader
    // ownership before resetting it; a reset failure prevents child admission.
    var mouse_reader = loopReader(loop, io);
    try mouse_policy.leaveWithReader(vx, tty.writer(), &mouse_reader);
    // Do not leak Chasen's paste mode into the foreground child process.
    _ = vx.setBracketedPaste(tty.writer(), false) catch {};
    _ = vx.exitAltScreen(tty.writer()) catch {};

    // Keep the parent /dev/tty fd open. Closing and reopening it would leave
    // run()'s deferred cleanup with a deinitialized tty if re-init failed.
    try leaveRawMode(tty);

    const outcome = runChildOnControllingTty(
        io,
        entry.argv,
        entry.runtimeChildCwd(),
        entry.runtimeChildEnvironment(),
    );
    try restoreTerminalAfterForeground(vx, tty, allocator, io, loop, mouse_policy, keyboard_protocol);

    return outcome;
}

fn runChildOnControllingTty(
    io: std.Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environ_map: ?*const std.process.Environ.Map,
) foreground_command.ForegroundCommandOutcome {
    var child_tty = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch |err| {
        return .{ .spawn_failed = @errorName(err) };
    };
    defer child_tty.close(io);

    return spawnAndWaitForegroundCommand(
        io,
        argv,
        cwd,
        environ_map,
        .{ .file = child_tty },
        .{ .file = child_tty },
        .{ .file = child_tty },
    );
}

fn spawnAndWaitForegroundCommand(
    io: std.Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environ_map: ?*const std.process.Environ.Map,
    stdin: std.process.SpawnOptions.StdIo,
    stdout: std.process.SpawnOptions.StdIo,
    stderr: std.process.SpawnOptions.StdIo,
) foreground_command.ForegroundCommandOutcome {
    return spawnAndWaitForegroundCommandWithOps(
        io,
        argv,
        cwd,
        environ_map,
        stdin,
        stdout,
        stderr,
        NativeForegroundCommandProcessOps{},
    );
}

const NativeForegroundCommandProcessOps = struct {
    fn spawn(
        _: @This(),
        io: std.Io,
        options: std.process.SpawnOptions,
    ) std.process.SpawnError!std.process.Child {
        return std.process.spawn(io, options);
    }

    fn wait(
        _: @This(),
        child: *std.process.Child,
        io: std.Io,
    ) std.process.Child.WaitError!std.process.Child.Term {
        return child.wait(io);
    }

    fn kill(_: @This(), child: *std.process.Child, io: std.Io) void {
        child.kill(io);
    }
};

fn spawnAndWaitForegroundCommandWithOps(
    io: std.Io,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
    environ_map: ?*const std.process.Environ.Map,
    stdin: std.process.SpawnOptions.StdIo,
    stdout: std.process.SpawnOptions.StdIo,
    stderr: std.process.SpawnOptions.StdIo,
    process_ops: anytype,
) foreground_command.ForegroundCommandOutcome {
    var child = process_ops.spawn(io, .{
        .argv = argv,
        .cwd = cwd,
        .environ_map = environ_map,
        .stdin = stdin,
        .stdout = stdout,
        .stderr = stderr,
    }) catch |err| {
        return .{ .spawn_failed = @errorName(err) };
    };

    const term = process_ops.wait(&child, io) catch |err| {
        process_ops.kill(&child, io);
        return .{ .wait_failed = @errorName(err) };
    };

    return foregroundCommandOutcomeFromTerm(term);
}

fn foregroundCommandOutcomeFromTerm(term: std.process.Child.Term) foreground_command.ForegroundCommandOutcome {
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
    mouse_policy: terminal_mouse.Policy,
    keyboard_protocol: root.KeyboardProtocol,
) !void {
    try enterRawMode(tty);
    try loop.start();
    try vx.enterAltScreen(tty.writer());

    // Capability and size refresh are useful after returning from an editor,
    // but failure here should not leave the runtime stopped.
    queryTerminal(vx, tty.writer(), io, .fromSeconds(1), keyboard_protocol) catch {};
    if (mouse_policy.enabled) {
        var mouse_reader = loopReader(loop, io);
        try mouse_policy.enterWithReader(vx, tty.writer(), &mouse_reader);
    }
    _ = vx.setBracketedPaste(tty.writer(), true) catch {};

    if (tty.getWinsize()) |ws| {
        vx.resize(allocator, tty.writer(), ws) catch {};
        useUnicodeWidth(vx);
    } else |_| {}
}

fn leaveRawMode(tty: *vaxis.Tty) !void {
    // libvaxis intentionally uses a lightweight Tty stub under `zig test`.
    // Foreground-command terminal handoff is integration-only, while allowing
    // the surrounding production effect drain to be instantiated in tests.
    if (builtin.is_test) return error.Unsupported;
    if (builtin.os.tag == .windows) return error.Unsupported;
    try std.posix.tcsetattr(tty.fd.handle, .FLUSH, tty.termios);
}

fn enterRawMode(tty: *vaxis.Tty) !void {
    if (builtin.is_test) return error.Unsupported;
    if (builtin.os.tag == .windows) return error.Unsupported;
    tty.termios = try vaxis.Tty.makeRaw(tty.fd.handle);
}

/// Starts tasks queued in Ctx and tracks their futures for shutdown.
/// Task start failures are delivered through the app-provided failure callback
/// before ownership is transferred to the concurrent task body.
fn spawnPendingTasks(
    comptime App: type,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    pending_futures: *std.ArrayList(PendingTaskFuture(App.Msg)),
    runtime_completions: *RuntimeCompletionBuffer(App.Msg),
    allocator: std.mem.Allocator,
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(App.Msg)),
    shutting_down: *const std.atomic.Value(bool),
) !void {
    const Msg = App.Msg;
    for (app_ctx.takePendingTasks()) |task| {
        pending_futures.ensureUnusedCapacity(allocator, 1) catch |err| {
            var msg = task.failed(.{ .start_failed = @errorName(err) });
            runtime_completions.append(msg) catch |append_err| {
                root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                return append_err;
            };
            continue;
        };
        const future = io.concurrent(
            SpawnHelper(Msg).run,
            .{ task, allocator, io, loop, shutting_down },
        ) catch |err| {
            var msg = task.failed(.{ .start_failed = @errorName(err) });
            runtime_completions.append(msg) catch |append_err| {
                root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                return append_err;
            };
            continue;
        };
        pending_futures.appendAssumeCapacity(future);
    }
    for (app_ctx.takePendingTasksWith()) |entry| {
        pending_futures.ensureUnusedCapacity(allocator, 1) catch |err| {
            var msg = entry.failed(entry.ctx, .{ .start_failed = @errorName(err) }, allocator);
            runtime_completions.append(msg) catch |append_err| {
                root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                return append_err;
            };
            continue;
        };
        const future = io.concurrent(
            SpawnWithHelper(Msg).run,
            .{ entry.ctx, entry.run, allocator, io, loop, shutting_down },
        ) catch |err| {
            var msg = entry.failed(entry.ctx, .{ .start_failed = @errorName(err) }, allocator);
            runtime_completions.append(msg) catch |append_err| {
                root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                return append_err;
            };
            continue;
        };
        pending_futures.appendAssumeCapacity(future);
    }
}

fn startPendingFrame(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    io: std.Io,
    loop: *vaxis.Loop(InternalEvent(Msg)),
    suspended: *std.atomic.Value(bool),
    shutting_down: *const std.atomic.Value(bool),
    frame_in_flight: *bool,
    frame_future: *?std.Io.Future(void),
    last_frame_ns: u64,
    next_frame_index: u64,
) void {
    if (!app_ctx.takeFrameRequest()) return;

    if (frame_in_flight.*) return;

    const after_ns = frameDelayNs(last_frame_ns, timestampNs(io));
    frame_future.* = io.concurrent(
        FrameHelper(Msg).run,
        .{ after_ns, last_frame_ns, next_frame_index, io, loop, suspended, shutting_down },
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
    shutting_down: *const std.atomic.Value(bool),
) !void {
    // Take ownership of queued copies before processing. Zeroing the queue
    // first keeps run()'s unwind cleanup from freeing ids after they have been
    // handed to running_timers.
    const pending_ticks = app_ctx.takePendingTicks();

    for (pending_ticks) |entry| {
        var owned_id: ?[]const u8 = entry.id;
        defer if (owned_id) |id| allocator.free(id);

        // Cancel existing timer with the same id.
        cancelRunningTimer(running_timers, allocator, entry.id, io);

        var future = io.concurrent(
            TickHelper(Msg).run,
            .{ entry.after_ns, entry.msg, io, loop, shutting_down },
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
    shutting_down: *const std.atomic.Value(bool),
) !void {
    // Take ownership of queued copies before processing. Zeroing the queue
    // first keeps run()'s unwind cleanup from freeing ids after they have been
    // handed to running_timers.
    const pending_everys = app_ctx.takePendingEverys();

    for (pending_everys) |entry| {
        var owned_id: ?[]const u8 = entry.id;
        defer if (owned_id) |id| allocator.free(id);

        // Cancel existing timer with the same id.
        cancelRunningTimer(running_timers, allocator, entry.id, io);

        var future = io.concurrent(
            EveryHelper(Msg).run,
            .{ entry.interval_ns, entry.msg, io, loop, suspended, shutting_down },
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
    const pending_cancels = app_ctx.takePendingCancels();

    for (pending_cancels) |id| {
        defer allocator.free(id);
        cancelRunningTimer(running_timers, allocator, id, io);
    }
}

fn processPendingTerminalImages(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    runtime_completions: *RuntimeCompletionBuffer(Msg),
    registry: *terminal_image.Registry,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    opts: root.RunOptions,
) !void {
    // Take ownership of queued image effects before processing so unwind
    // cleanup only sees entries that have not reached the drain step.
    const pending_unloads = app_ctx.takePendingTerminalImageUnloads();

    for (pending_unloads) |handle| {
        _ = registry.unload(vx.*, tty, handle);
    }

    const pending_loads = app_ctx.takePendingTerminalImageLoads();

    for (pending_loads) |entry| {
        defer allocator.free(entry.path);

        switch (loadTerminalImagePath(registry, vx, tty, allocator, entry.path, opts)) {
            .loaded => |handle| {
                var msg = entry.loaded(entry.request_id, handle);
                runtime_completions.append(msg) catch |err| {
                    root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                    _ = registry.unload(vx.*, tty, handle);
                    return err;
                };
            },
            .failed => |reason| {
                var msg = entry.failed(entry.request_id, reason);
                runtime_completions.append(msg) catch |err| {
                    root.runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
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

fn frameDelayNs(last_frame_ns: u64, now_ns: u64) u64 {
    return frame_interval_ns -| deltaNs(last_frame_ns, now_ns);
}

fn eventKind(event: anytype) root.RuntimeEventKind {
    return switch (event) {
        .key_press => .key_press,
        .winsize => .winsize,
        .user_msg => .user_msg,
        .mouse => .mouse,
        .focus_in => .focus_in,
        .focus_out => .focus_out,
        .paste_start => .paste,
        .paste_end => .paste,
        .frame => .frame,
        .frame_canceled => .frame,
        .resize_pending => .winsize,
        .continue_effect_drain => .user_msg,
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
    // Keep the runtime surface width policy aligned with chasen.text.displayWidth.
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

    const paste_start_ev: Event = .paste_start;
    try std.testing.expect(paste_start_ev == .paste_start);

    const paste_end_ev: Event = .paste_end;
    try std.testing.expect(paste_end_ev == .paste_end);

    const frame_ev: Event = .{ .frame = .{ .now_ns = 100, .delta_ns = 16, .index = 2 } };
    try std.testing.expect(frame_ev == .frame);
}

const OwnershipTestPayload = struct {
    bytes: []u8,
    deinit_count: *usize,
};

const OwnershipTestMsg = union(enum) {
    owned: OwnershipTestPayload,

    pub const undelivered_policy = .deinit;

    pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
        switch (self.*) {
            .owned => |owned| {
                allocator.free(owned.bytes);
                owned.deinit_count.* += 1;
            },
        }
        self.* = undefined;
    }
};

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
        .posted => return error.TestUnexpectedResult,
        .undelivered => |value| {
            var msg = value;
            root.runtime.deinitUndeliveredMessage(OwnershipTestMsg, &msg, std.testing.allocator);
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
    drainInternalEventsForShutdown(OwnershipTestMsg, &loop, std.testing.allocator);
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
        .posted => return error.TestUnexpectedResult,
        .undelivered => |*msg| root.runtime.deinitUndeliveredMessage(OwnershipTestMsg, msg, std.testing.allocator),
    }
    try std.testing.expectEqual(@as(usize, 1), deinit_count);

    drainInternalEventsForShutdown(OwnershipTestMsg, &loop, std.testing.allocator);
}

test "resize poll coalesces latest size without waiting for queue capacity" {
    const TestMsg = union(enum) {
        noop,

        pub const undelivered_policy = .plain;
    };
    const Event = InternalEvent(TestMsg);

    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    while (try loop.tryPostEvent(.continue_effect_drain)) {}
    var resize_poll = ResizePollState(TestMsg).init(undefined, &loop);

    // publish runs on the ordinary polling thread. A full queue can reject its
    // wake without losing the latest dimensions.
    resize_poll.publish(.{ .rows = 20, .cols = 80, .x_pixel = 800, .y_pixel = 400 });
    resize_poll.publish(.{ .rows = 40, .cols = 120, .x_pixel = 1200, .y_pixel = 800 });

    const latest = resize_poll.takeLatest().?;
    try std.testing.expectEqual(@as(u16, 40), latest.rows);
    try std.testing.expectEqual(@as(u16, 120), latest.cols);
    try std.testing.expectEqual(@as(u16, 1200), latest.x_pixel);
    try std.testing.expectEqual(@as(u16, 800), latest.y_pixel);
    try std.testing.expectEqual(@as(?vaxis.Winsize, null), resize_poll.takeLatest());

    drainInternalEventsForShutdown(TestMsg, &loop, std.testing.allocator);
}

test "resize poll survives a stopped reader until the next loop turn" {
    const TestMsg = union(enum) {
        noop,

        pub const undelivered_policy = .plain;
    };
    const Event = InternalEvent(TestMsg);

    // A foreground handoff stops only the tty reader; the queue and coalesced
    // state remain live. Publishing while thread is null models a poll during
    // the child process, before restoreTerminalAfterForeground restarts it.
    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    var resize_poll = ResizePollState(TestMsg).init(undefined, &loop);
    try std.testing.expect(loop.thread == null);

    resize_poll.publish(.{ .rows = 50, .cols = 160, .x_pixel = 1600, .y_pixel = 1000 });
    const wake = (try loop.tryEvent()).?;
    try std.testing.expect(wake == .resize_pending);

    const latest = resize_poll.takeLatest().?;
    try std.testing.expectEqual(@as(u16, 50), latest.rows);
    try std.testing.expectEqual(@as(u16, 160), latest.cols);
    try std.testing.expectEqual(@as(u16, 1600), latest.x_pixel);
    try std.testing.expectEqual(@as(u16, 1000), latest.y_pixel);
}

test "resize poll thread wakes an empty event queue" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const TestMsg = union(enum) {
        noop,

        pub const undelivered_policy = .plain;
    };
    const Event = InternalEvent(TestMsg);

    var tty_buf: [64]u8 = undefined;
    var tty = try vaxis.Tty.init(std.testing.io, &tty_buf);
    defer tty.deinit();
    var loop = vaxis.Loop(Event).init(std.testing.io, &tty, undefined);
    var resize_poll = ResizePollState(TestMsg).init(&tty, &loop);
    resize_poll.seed(.{ .rows = 1, .cols = 1, .x_pixel = 1, .y_pixel = 1 });

    const thread = try std.Thread.spawn(.{
        .allocator = std.testing.allocator,
    }, ResizePollState(TestMsg).run, .{&resize_poll});
    defer {
        resize_poll.stop();
        thread.join();
    }

    var wake: ?Event = null;
    for (0..100) |_| {
        if (try loop.tryEvent()) |event| {
            wake = event;
            break;
        }
        try std.testing.io.sleep(.fromMilliseconds(5), .awake);
    }

    try std.testing.expect(wake != null);
    try std.testing.expect(wake.? == .resize_pending);
    const latest = resize_poll.takeLatest().?;
    try std.testing.expectEqual(@as(u16, 40), latest.rows);
    try std.testing.expectEqual(@as(u16, 80), latest.cols);
}

test "libvaxis frees OSC 52 responses without queueing owned paste" {
    const TestMsg = union(enum) {
        noop,

        pub const undelivered_policy = .plain;
    };
    const Event = InternalEvent(TestMsg);

    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    while (try loop.tryPostEvent(.continue_effect_drain)) {}

    var parser: vaxis.Parser = .{};
    var cache: vaxis.GraphemeCache = .{};
    for ([_][]const u8{
        "\x1b]52;c;Zmlyc3Q=\x1b\\",
        "\x1b]52;c;c2Vjb25k\x1b\\",
    }) |input| {
        const result = try parser.parse(input, std.testing.allocator);
        try std.testing.expectEqual(input.len, result.n);
        try std.testing.expect(result.event.? == .paste);

        // InternalEvent has no `.paste` field, so libvaxis frees the decoded
        // bytes here instead of attempting a blocking post into the full queue.
        try vaxis.loop.handleEventGeneric(
            &loop,
            undefined,
            &cache,
            Event,
            result.event.?,
            std.testing.allocator,
        );
    }

    // The pinned libvaxis revision has an errdefer immediately after its
    // decode-buffer allocation. A correctly sized but invalid base64 payload
    // therefore returns an error without leaking producer-local memory before
    // an event exists for handleEventGeneric to dispose.
    try std.testing.expectError(
        error.InvalidCharacter,
        parser.parse("\x1b]52;c;!!!!\x1b\\", std.testing.allocator),
    );

    drainInternalEventsForShutdown(TestMsg, &loop, std.testing.allocator);
}

test "loop reader stop needs no extra concurrency slot on full queue" {
    const TestMsg = union(enum) {
        noop,

        pub const undelivered_policy = .plain;
    };
    const Event = InternalEvent(TestMsg);
    const BlockedProducer = struct {
        fn run(
            loop: *vaxis.Loop(Event),
            started: *std.atomic.Value(bool),
        ) void {
            started.store(true, .seq_cst);
            loop.postEvent(.continue_effect_drain) catch {};
        }
    };
    const Probe = struct {
        fn run() void {}
    };

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{
        .concurrent_limit = .limited(1),
    });
    defer threaded.deinit();
    const io = threaded.io();
    var loop = vaxis.Loop(Event).init(io, undefined, undefined);
    while (try loop.tryPostEvent(.continue_effect_drain)) {}

    var started: std.atomic.Value(bool) = .init(false);
    loop.thread = try io.concurrent(BlockedProducer.run, .{ &loop, &started });
    while (!started.load(.seq_cst)) {
        try io.sleep(.fromMilliseconds(1), .awake);
    }
    try std.testing.expectError(error.ConcurrencyUnavailable, io.concurrent(Probe.run, .{}));

    stopLoopReader(&loop, io);

    try std.testing.expect(loop.thread == null);
    drainInternalEventsForShutdown(TestMsg, &loop, std.testing.allocator);
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
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            unreachable;
        }

        fn failed(_: ctx_mod.TaskFailure) TestMsg {
            return .failed;
        }
    };
    const Event = InternalEvent(TestMsg);

    var app_ctx: ctx_mod.Ctx(TestMsg) = .{
        ._allocator = std.testing.allocator,
        ._io = std.testing.io,
    };
    try app_ctx.task().spawn(.{ .run = Task.run, .failed = Task.failed });
    var pending_futures: std.ArrayList(PendingTaskFuture(TestMsg)) = .empty;
    var completions: RuntimeCompletionBuffer(TestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    while (try loop.tryPostEvent(.continue_effect_drain)) {}
    var shutting_down: std.atomic.Value(bool) = .init(false);

    try spawnPendingTasks(
        TestApp,
        &app_ctx,
        &pending_futures,
        &completions,
        std.testing.failing_allocator,
        std.testing.io,
        &loop,
        &shutting_down,
    );
    try std.testing.expectEqual(@as(usize, 0), pending_futures.items.len);
    try std.testing.expectEqual(@as(usize, 1), completions.items.items.len);

    var app: TestApp = .{};
    var stats: ?root.RuntimeStats = null;
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
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            unreachable;
        }

        fn failed(_: ctx_mod.TaskFailure) TestMsg {
            return .second;
        }
    };
    const TestApp = struct {
        update_count: usize = 0,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), msg: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            self.update_count += 1;
            switch (msg) {
                .first => try ctx.task().spawn(.{ .run = Task.run, .failed = Task.failed }),
                .second => {},
            }
        }
    };
    const Event = InternalEvent(TestMsg);

    var app: TestApp = .{};
    var app_ctx: ctx_mod.Ctx(TestMsg) = .{
        ._allocator = std.testing.allocator,
        ._io = std.testing.io,
    };
    var pending_futures: std.ArrayList(PendingTaskFuture(TestMsg)) = .empty;
    var running_timers: std.ArrayList(TimerHandle) = .empty;
    var completions: RuntimeCompletionBuffer(TestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    try completions.append(.first);
    var terminal_images: terminal_image.Registry = .{};
    defer terminal_images.deinit(std.testing.allocator);
    var tty_buffer: [64]u8 = undefined;
    var tty = try vaxis.Tty.init(std.testing.io, &tty_buffer);
    defer tty.deinit();
    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    while (try loop.tryPostEvent(.continue_effect_drain)) {}
    var suspended: std.atomic.Value(bool) = .init(false);
    var shutting_down: std.atomic.Value(bool) = .init(false);
    var frame_in_flight = false;
    var frame_future: ?std.Io.Future(void) = null;
    var continuation_pending = false;
    var stats: ?root.RuntimeStats = null;

    _ = try drainPendingEffects(
        TestApp,
        &app,
        &app_ctx,
        &pending_futures,
        &running_timers,
        &completions,
        &terminal_images,
        undefined,
        &tty,
        std.testing.failing_allocator,
        std.testing.io,
        &loop,
        &suspended,
        &shutting_down,
        &frame_in_flight,
        &frame_future,
        &continuation_pending,
        0,
        0,
        &stats,
        .{
            .enabled = false,
            .coordinate_protocol = .cell_sgr,
        },
        .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        }, .terminal = .{ .env_map = undefined } },
    );

    try std.testing.expectEqual(@as(usize, 2), app.update_count);
    try std.testing.expectEqual(@as(usize, 0), completions.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), app_ctx.takePendingTasks().len);
    drainInternalEventsForShutdown(TestMsg, &loop, std.testing.allocator);
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

    var app_ctx: ctx_mod.Ctx(TestMsg) = .{
        ._allocator = std.testing.allocator,
        ._io = std.testing.io,
    };
    _ = try app_ctx.image().loadPath("missing.png", Callback.loaded, Callback.failed);
    var completions: RuntimeCompletionBuffer(TestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    var registry: terminal_image.Registry = .{};
    defer registry.deinit(std.testing.allocator);

    try processPendingTerminalImages(
        TestMsg,
        &app_ctx,
        &completions,
        &registry,
        undefined,
        undefined,
        std.testing.allocator,
        .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
        }, .terminal = .{ .env_map = undefined } },
    );
    try std.testing.expectEqual(@as(usize, 1), completions.items.items.len);

    var app: TestApp = .{};
    var stats: ?root.RuntimeStats = null;
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
    var app_ctx: ctx_mod.Ctx(OwnershipTestMsg) = .{
        ._allocator = std.testing.allocator,
        ._io = std.testing.io,
    };
    var completions: RuntimeCompletionBuffer(OwnershipTestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    try completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "delivered-completion"),
        .deinit_count = &deinit_count,
    } });
    var stats: ?root.RuntimeStats = null;

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
    var app_ctx: ctx_mod.Ctx(OwnershipTestMsg) = .{
        ._allocator = std.testing.allocator,
        ._io = std.testing.io,
    };
    var completions: RuntimeCompletionBuffer(OwnershipTestMsg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    try completions.append(.{ .owned = .{
        .bytes = try std.testing.allocator.dupe(u8, "update-error-completion"),
        .deinit_count = &deinit_count,
    } });
    var stats: ?root.RuntimeStats = null;

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

test "discard queued spawnWith task consumes context and returned message" {
    const Capture = struct {
        bytes: []u8,
        failure_seen: *bool,
        deinit_count: *usize,

        fn run(_: *anyopaque, _: std.mem.Allocator, _: std.Io) OwnershipTestMsg {
            unreachable;
        }

        fn failed(ptr: *anyopaque, failure: ctx_mod.TaskFailure, allocator: std.mem.Allocator) OwnershipTestMsg {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.failure_seen.* = failure == .runtime_abandoned;
            const msg: OwnershipTestMsg = .{ .owned = .{
                .bytes = self.bytes,
                .deinit_count = self.deinit_count,
            } };
            allocator.destroy(self);
            return msg;
        }
    };

    var failure_seen = false;
    var deinit_count: usize = 0;
    const capture = try std.testing.allocator.create(Capture);
    capture.* = .{
        .bytes = try std.testing.allocator.dupe(u8, "captured-task-context"),
        .failure_seen = &failure_seen,
        .deinit_count = &deinit_count,
    };

    var app_ctx: ctx_mod.Ctx(OwnershipTestMsg) = .{
        ._allocator = std.testing.allocator,
        ._io = std.testing.io,
    };
    try app_ctx.task().spawnWith(.{
        .ctx = capture,
        .run = Capture.run,
        .failed = Capture.failed,
    });

    discardQueuedTasks(OwnershipTestMsg, &app_ctx, std.testing.allocator);

    try std.testing.expect(failure_seen);
    try std.testing.expectEqual(@as(usize, 1), deinit_count);
    try std.testing.expectEqual(@as(usize, 0), app_ctx.takePendingTasksWith().len);
}

test "BracketedPasteAccumulator combines pasted key text" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
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

    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = 'a', .text = "old" });
    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = 'n', .text = "new" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("new", text);
}

test "BracketedPasteAccumulator ignores non-text special keys" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.up });
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.left_shift });

    try std.testing.expectEqual(@as(?[]u8, null), paste.finish(allocator));
}

test "BracketedPasteAccumulator drops invalid utf8" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    var invalid = [_]u8{0xff};
    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.multicodepoint, .text = invalid[0..] });

    try std.testing.expectEqual(@as(?[]u8, null), paste.finish(allocator));
}

test "BracketedPasteAccumulator failure swallows until paste end" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
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

    paste.start();
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

    paste.start();
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

test "frameDelayNs paces relative to last delivered frame" {
    try std.testing.expectEqual(frame_interval_ns, frameDelayNs(100, 100));
    try std.testing.expectEqual(frame_interval_ns - 5, frameDelayNs(100, 105));
    try std.testing.expectEqual(@as(u64, 0), frameDelayNs(100, 100 + frame_interval_ns));
    try std.testing.expectEqual(@as(u64, 0), frameDelayNs(100, 101 + frame_interval_ns));
    try std.testing.expectEqual(frame_interval_ns, frameDelayNs(100, 99));
}

test "elapsedNs uses deltaNs clamping" {
    try std.testing.expectEqual(@as(u64, 5), elapsedNs(10, 15));
    try std.testing.expectEqual(@as(u64, 0), elapsedNs(10, 9));
}

test "timingStart returns zero when timing is disabled" {
    const io: std.Io = undefined;
    try std.testing.expectEqual(@as(u64, 0), timingStart(false, io));
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

const InjectedForegroundCommandProcessOps = struct {
    mode: enum { spawn_failure, wait_failure },
    seen_environment: *?*const std.process.Environ.Map,
    kill_count: *usize,

    const ChildState = struct {};

    fn spawn(
        self: @This(),
        _: std.Io,
        options: std.process.SpawnOptions,
    ) error{InjectedSpawn}!ChildState {
        self.seen_environment.* = options.environ_map;
        if (self.mode == .spawn_failure) return error.InjectedSpawn;
        return .{};
    }

    fn wait(
        self: @This(),
        _: *ChildState,
        _: std.Io,
    ) error{InjectedWait}!std.process.Child.Term {
        if (self.mode == .wait_failure) return error.InjectedWait;
        return .{ .exited = 0 };
    }

    fn kill(self: @This(), _: *ChildState, _: std.Io) void {
        self.kill_count.* += 1;
    }
};

test "foreground command inherit cwd reaches child spawn" {
    const TestMsg = union(enum) { finished };
    var app_ctx: ctx_mod.Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer app_ctx.runtimeClearPendingEffectCopies();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{try foregroundCommandTestTruePath()},
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    const pending = app_ctx.takePendingForegroundCommands();
    var entry = pending[0];
    defer entry.runtimeDeinit(std.testing.allocator);
    switch (entry.runtimeChildCwd()) {
        .inherit => {},
        else => return error.TestUnexpectedResult,
    }
    const outcome = spawnAndWaitForegroundCommand(
        std.testing.io,
        entry.argv,
        entry.runtimeChildCwd(),
        entry.runtimeChildEnvironment(),
        .ignore,
        .ignore,
        .ignore,
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
    var app_ctx: ctx_mod.Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer app_ctx.runtimeClearPendingEffectCopies();
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

    const pending = app_ctx.takePendingForegroundCommands();
    var entry = pending[0];
    defer entry.runtimeDeinit(std.testing.allocator);
    switch (entry.runtimeChildCwd()) {
        .dir => {},
        else => return error.TestUnexpectedResult,
    }
    const queued_environment = entry.runtimeChildEnvironment() orelse return error.TestUnexpectedResult;
    const outcome = spawnAndWaitForegroundCommand(
        std.testing.io,
        entry.argv,
        entry.runtimeChildCwd(),
        queued_environment,
        .ignore,
        .ignore,
        .ignore,
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
    var app_ctx: ctx_mod.Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer app_ctx.runtimeClearPendingEffectCopies();

    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ printenv_path, parent_canary },
        .environment = .inherit,
        .finished = finished,
    });
    {
        const pending = app_ctx.takePendingForegroundCommands();
        var entry = pending[0];
        defer entry.runtimeDeinit(std.testing.allocator);
        try std.testing.expect(entry.runtimeChildEnvironment() == null);
        const outcome = spawnAndWaitForegroundCommand(
            std.testing.io,
            entry.argv,
            entry.runtimeChildCwd(),
            entry.runtimeChildEnvironment(),
            .ignore,
            .ignore,
            .ignore,
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
        const pending = app_ctx.takePendingForegroundCommands();
        var entry = pending[0];
        defer entry.runtimeDeinit(std.testing.allocator);
        const queued_empty = entry.runtimeChildEnvironment() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), queued_empty.count());
        const outcome = spawnAndWaitForegroundCommand(
            std.testing.io,
            entry.argv,
            entry.runtimeChildCwd(),
            queued_empty,
            .ignore,
            .ignore,
            .ignore,
        );
        switch (outcome) {
            .exited => |code| try std.testing.expect(code != 0),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "foreground environment spawn and wait seams preserve replacement pointer and failures" {
    var replacement: std.process.Environ.Map = .init(std.testing.allocator);
    defer replacement.deinit();
    try replacement.put("ISSUE55_SEAM", "value");

    var seen_environment: ?*const std.process.Environ.Map = null;
    var kill_count: usize = 0;
    const spawn_failure = spawnAndWaitForegroundCommandWithOps(
        std.testing.io,
        &.{"command"},
        .inherit,
        &replacement,
        .ignore,
        .ignore,
        .ignore,
        InjectedForegroundCommandProcessOps{
            .mode = .spawn_failure,
            .seen_environment = &seen_environment,
            .kill_count = &kill_count,
        },
    );
    try std.testing.expectEqualStrings("InjectedSpawn", spawn_failure.spawn_failed);
    try std.testing.expect(seen_environment.? == &replacement);
    try std.testing.expectEqual(@as(usize, 0), kill_count);

    seen_environment = null;
    const wait_failure = spawnAndWaitForegroundCommandWithOps(
        std.testing.io,
        &.{"command"},
        .inherit,
        &replacement,
        .ignore,
        .ignore,
        .ignore,
        InjectedForegroundCommandProcessOps{
            .mode = .wait_failure,
            .seen_environment = &seen_environment,
            .kill_count = &kill_count,
        },
    );
    try std.testing.expectEqualStrings("InjectedWait", wait_failure.wait_failed);
    try std.testing.expect(seen_environment.? == &replacement);
    try std.testing.expectEqual(@as(usize, 1), kill_count);
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

    var app_ctx: ctx_mod.Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer app_ctx.runtimeClearPendingEffectCopies();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ try foregroundCommandTestTouchPath(), "marker" },
        .cwd = .{ .dir = caller_dir },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    const pending = app_ctx.takePendingForegroundCommands();
    var entry = pending[0];
    defer entry.runtimeDeinit(std.testing.allocator);
    const duplicate_fd = switch (entry.runtimeChildCwd()) {
        .dir => |dir| dir.handle,
        else => return error.TestUnexpectedResult,
    };

    caller_dir.close(std.testing.io);
    caller_open = false;
    try tmp.dir.rename("original", tmp.dir, "renamed", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);

    const outcome = spawnAndWaitForegroundCommand(
        std.testing.io,
        entry.argv,
        entry.runtimeChildCwd(),
        entry.runtimeChildEnvironment(),
        .ignore,
        .ignore,
        .ignore,
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

    var app_ctx: ctx_mod.Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer app_ctx.runtimeClearPendingEffectCopies();
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

    const pending = app_ctx.takePendingForegroundCommands();
    var entry = pending[0];
    defer entry.runtimeDeinit(std.testing.allocator);
    switch (entry.runtimeChildCwd()) {
        .path => |path| try std.testing.expectEqualStrings(expected_path, path),
        else => return error.TestUnexpectedResult,
    }

    try tmp.dir.rename("original", tmp.dir, "renamed", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);
    const outcome = spawnAndWaitForegroundCommand(
        std.testing.io,
        entry.argv,
        entry.runtimeChildCwd(),
        entry.runtimeChildEnvironment(),
        .ignore,
        .ignore,
        .ignore,
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

    var app_ctx: ctx_mod.Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer app_ctx.runtimeClearPendingEffectCopies();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{try foregroundCommandTestTouchPath()},
        .cwd = .{ .dir = .{ .handle = file.handle } },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    const pending = app_ctx.takePendingForegroundCommands();
    var entry = pending[0];
    defer entry.runtimeDeinit(std.testing.allocator);
    const outcome = spawnAndWaitForegroundCommand(
        std.testing.io,
        entry.argv,
        entry.runtimeChildCwd(),
        entry.runtimeChildEnvironment(),
        .ignore,
        .ignore,
        .ignore,
    );
    switch (outcome) {
        .spawn_failed => {},
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
            entry: *const ctx_mod.Ctx(TestMsg).ForegroundCommandEntry,
        ) !foreground_command.ForegroundCommandOutcome {
            self.first_duplicate.* = switch (entry.runtimeChildCwd()) {
                .dir => |dir| dir.handle,
                else => return error.TestUnexpectedResult,
            };
            const environment = entry.runtimeChildEnvironment() orelse return error.TestUnexpectedResult;
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

    var app_ctx: ctx_mod.Ctx(TestMsg) = .{
        ._allocator = std.testing.allocator,
        ._io = std.testing.io,
    };
    defer app_ctx.runtimeClearPendingEffectCopies();
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
    var stats: ?root.RuntimeStats = null;
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
    try std.testing.expectEqual(@as(u8, 1), app_ctx._pending_foreground_commands_len);

    const follow_up = app_ctx._pending_foreground_commands[0].runtimeChildCwd();
    const second_fd = switch (follow_up) {
        .dir => |dir| dir.handle,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(foregroundCommandProgramTestFdOpen(second_fd));
    const follow_up_environment = app_ctx._pending_foreground_commands[0].runtimeChildEnvironment() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("second", follow_up_environment.get("ISSUE55_OWNER").?);
    app_ctx.runtimeClearPendingEffectCopies();
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
    };
    const TestMsg = union(enum) {
        finished,

        pub const undelivered_policy = .plain;
    };
    const TestApp = struct {
        fail_update: bool,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), _: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            if (self.fail_update) return error.InjectedAppUpdate;
        }
    };
    const Runner = struct {
        mode: Mode,
        duplicate_fd: *?std.Io.Dir.Handle,

        fn run(
            self: @This(),
            entry: *const ctx_mod.Ctx(TestMsg).ForegroundCommandEntry,
        ) !foreground_command.ForegroundCommandOutcome {
            self.duplicate_fd.* = switch (entry.runtimeChildCwd()) {
                .dir => |dir| dir.handle,
                else => return error.TestUnexpectedResult,
            };
            const environment = entry.runtimeChildEnvironment() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("owned", environment.get("ISSUE55_TERMINAL").?);
            return switch (self.mode) {
                .terminal_leave_error => error.InjectedTerminalLeave,
                .terminal_restore_error => error.InjectedTerminalRestore,
                .spawn_failure => .{ .spawn_failed = "InjectedSpawn" },
                .wait_failure => .{ .wait_failed = "InjectedWait" },
                .exited, .app_update_error => .{ .exited = 0 },
                .signaled => .{ .signaled = 15 },
            };
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

            var app_ctx: ctx_mod.Ctx(TestMsg) = .{
                ._allocator = std.testing.allocator,
                ._io = std.testing.io,
            };
            defer app_ctx.runtimeClearPendingEffectCopies();
            _ = try app_ctx.terminal().runForegroundCommand(.{
                .argv = &.{"command"},
                .cwd = .{ .dir = caller_dir },
                .environment = .{ .replace = &caller_environment },
                .finished = &struct {
                    fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                        return .finished;
                    }
                }.done,
            });

            var duplicate_fd: ?std.Io.Dir.Handle = null;
            var app: TestApp = .{ .fail_update = mode == .app_update_error };
            var stats: ?root.RuntimeStats = null;
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

            const owned_fd = duplicate_fd orelse return error.TestUnexpectedResult;
            try std.testing.expect(!foregroundCommandProgramTestFdOpen(owned_fd));
            try std.testing.expect(foregroundCommandProgramTestFdOpen(caller_dir.handle));
            try std.testing.expectEqual(@as(u8, 0), app_ctx._pending_foreground_commands_len);
        }
    };

    const cases = [_]struct { mode: Mode, expected_error: ?anyerror }{
        .{ .mode = .terminal_leave_error, .expected_error = error.InjectedTerminalLeave },
        .{ .mode = .terminal_restore_error, .expected_error = error.InjectedTerminalRestore },
        .{ .mode = .spawn_failure, .expected_error = null },
        .{ .mode = .wait_failure, .expected_error = null },
        .{ .mode = .exited, .expected_error = null },
        .{ .mode = .signaled, .expected_error = null },
        .{ .mode = .app_update_error, .expected_error = error.InjectedAppUpdate },
    };
    for (cases) |case| try Harness.run(case.mode, case.expected_error);
}

test "foreground command termination mapping preserves exit signal and wait outcomes" {
    const exited = foregroundCommandOutcomeFromTerm(.{ .exited = 7 });
    try std.testing.expectEqual(@as(u8, 7), exited.exited);

    const signaled = foregroundCommandOutcomeFromTerm(.{ .signal = .TERM });
    try std.testing.expectEqual(@as(u32, @intFromEnum(std.posix.SIG.TERM)), signaled.signaled);

    const stopped = foregroundCommandOutcomeFromTerm(.{ .stopped = .STOP });
    try std.testing.expectEqual(@as(u32, @intFromEnum(std.posix.SIG.STOP)), stopped.signaled);

    const unknown = foregroundCommandOutcomeFromTerm(.{ .unknown = 99 });
    try std.testing.expectEqualStrings("UnknownTermination", unknown.wait_failed);
}
