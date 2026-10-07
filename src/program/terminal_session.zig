const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const types = @import("../program_types.zig");
const InternalEvent = types.InternalEvent;
const runtime = @import("../runtime.zig");
const terminal_mouse = @import("../terminal_mouse.zig");
const foreground_job = @import("../foreground_job.zig");
const foreground_command = @import("../foreground_command.zig");
const resize_poll_interval_ns: u64 = 100 * std.time.ns_per_ms;

/// The terminal's final storage. Initialize in place before publishing reader,
/// polling-thread, or suspended-flag references; never move a live session.
pub fn TerminalSession(comptime Msg: type) type {
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        io: std.Io,
        options: types.TerminalOptions,
        tty_buf: [4096]u8 = undefined,
        tty: vaxis.Tty = undefined,
        vx: vaxis.Vaxis = undefined,
        loop: vaxis.Loop(InternalEvent(Msg)) = undefined,
        modes: TerminalModes = .{},
        mouse_policy: terminal_mouse.Policy,
        suspended: std.atomic.Value(bool) = .init(false),
        resize_poll: ResizePollState(Msg) = undefined,
        resize_thread: ?std.Thread = null,
        poll_enabled: bool = false,
        teardown_mask: if (foreground_job.supported) ?foreground_job.TtouMask else void = if (foreground_job.supported) null else {},

        pub fn init(self: *Self, allocator: std.mem.Allocator, io: std.Io, options: types.TerminalOptions) !void {
            self.* = .{
                .allocator = allocator,
                .io = io,
                .options = options,
                .mouse_policy = .{ .enabled = options.mouse, .coordinate_protocol = options.mouse_coordinate_protocol },
            };
            self.tty = try vaxis.Tty.init(io, &self.tty_buf);
            errdefer self.deinitTty();
            self.vx = try vaxis.Vaxis.init(io, allocator, options.env_map, .{
                // OSC 52 responses are freed by the parser: InternalEvent has
                // no allocator-owning paste variant.
                .system_clipboard_allocator = allocator,
            });
            useUnicodeWidth(&self.vx);
            self.loop = .init(io, &self.tty, &self.vx);
            self.resize_poll = .init(&self.tty, &self.loop);
        }

        pub fn start(self: *Self) !void {
            var reader = loopReader(&self.loop, self.io);
            try self.startWithReader(&reader);
        }

        // Use the existing mouse reader protocol for every setup transition.
        fn startWithReader(self: *Self, reader: anytype) !void {
            // Responses to capability queries require the reader to be live.
            try reader.start();
            errdefer {
                reader.stop();
                drainInternalEventsForShutdown(Msg, &self.loop, self.allocator);
            }
            try self.vx.enterAltScreen(self.writer());
            try queryTerminal(&self.vx, self.writer(), self.io, .fromSeconds(1), self.options.keyboard_protocol, &self.modes, reader);
            try self.vx.setBracketedPaste(self.writer(), true);
            errdefer self.vx.setBracketedPaste(self.writer(), false) catch {};
            errdefer self.mouse_policy.leaveWithReader(&self.vx, self.writer(), reader) catch {};
            if (self.mouse_policy.enabled) try self.mouse_policy.enterWithReader(&self.vx, self.writer(), reader);
            self.poll_enabled = builtin.os.tag != .windows and !self.vx.state.in_band_resize;
        }

        /// Runs after the runtime producer barrier and before image teardown.
        pub fn stopInput(self: *Self) void {
            var reader = loopReader(&self.loop, self.io);
            self.mouse_policy.leaveWithReader(&self.vx, self.writer(), &reader) catch {};
            self.vx.setBracketedPaste(self.writer(), false) catch {};
        }

        pub fn stopReader(self: *Self) void {
            stopLoopReader(&self.loop, self.io);
        }

        pub fn checkInputFailure(self: *Self) !void {
            try checkLoopInputFailure(&self.loop);
        }

        pub fn stopAndDrain(self: *Self) void {
            stopLoopAndDrain(Msg, &self.loop, self.allocator, self.io);
        }

        pub fn writer(self: *Self) *std.Io.Writer {
            return self.tty.writer();
        }

        pub fn getWinsize(self: *Self) !vaxis.Winsize {
            return self.tty.getWinsize();
        }

        pub fn resize(self: *Self, size: vaxis.Winsize) !void {
            try self.vx.resize(self.allocator, self.writer(), size);
            useUnicodeWidth(&self.vx);
        }

        pub fn seedResize(self: *Self, size: vaxis.Winsize) void {
            self.resize_poll.seed(size);
        }

        pub fn takeResize(self: *Self) ?vaxis.Winsize {
            return self.resize_poll.takeLatest();
        }

        pub fn startResizePolling(self: *Self) !void {
            if (!self.poll_enabled) return;
            self.resize_thread = try std.Thread.spawn(.{ .allocator = self.allocator }, ResizePollState(Msg).run, .{&self.resize_poll});
        }

        pub fn stopResizePolling(self: *Self) void {
            if (self.resize_thread) |thread| {
                self.resize_poll.stop();
                thread.join();
                self.resize_thread = null;
            }
        }

        /// Cover polling shutdown, producer joins, and final output after a
        /// failed foreground restore leaves this process in a background group.
        pub fn beginTeardown(self: *Self) void {
            if (comptime foreground_job.supported) self.teardown_mask = foreground_job.TtouMask.init() catch null;
        }

        pub fn deinit(self: *Self) void {
            self.stopResizePolling();
            self.stopAndDrain();
            self.modes.cleanup(&self.vx, self.writer());
            self.vx.deinit(self.allocator, self.writer());
            self.deinitTty();
            if (comptime foreground_job.supported) {
                if (self.teardown_mask) |*mask| mask.restore() catch {};
            }
        }

        fn deinitTty(self: *Self) void {
            if (comptime foreground_job.supported and !builtin.is_test) {
                if (foreground_job.TtouMask.init()) |value| {
                    var mask = value;
                    self.tty.deinit();
                    mask.restore() catch {};
                } else |_| self.tty.fd.close(self.io);
            } else self.tty.deinit();
        }

        pub fn runForeground(self: *Self, entry: anytype) foreground_command.ForegroundCommandOutcome {
            const allocator = self.allocator;
            const io = self.io;
            const tty = &self.tty;
            const vx = &self.vx;
            const loop = &self.loop;
            const suspended = &self.suspended;
            const mouse_policy = self.mouse_policy;
            const modes = &self.modes;
            if (!foreground_job.supported or builtin.is_test) return foreground_job.failure(.unsupported, "Unsupported");
            const terminal = foreground_job.Terminal.capture(tty.fd.handle) catch |err| return foreground_job.failure(.admission, @errorName(err));
            var prepared = foreground_job.Prepared.init(allocator, entry.input.argv, entry.input.childCwd(), entry.input.childEnvironment()) catch |err| return foreground_job.failure(.prepare, @errorName(err));
            defer prepared.deinit();
            prepared.prepareLaunch(terminal.fd) catch |err| return foreground_job.failure(if (err == error.Unsupported) .unsupported else .prepare, @errorName(err));
            suspended.store(true, .seq_cst);
            defer suspended.store(false, .seq_cst);
            stopLoopReader(loop, io);
            self.checkInputFailure() catch |err| return foreground_job.failure(.restore_tui, @errorName(err));
            const saved = modes.snapshot(vx);
            modes.leave(vx, tty.writer(), mouse_policy) catch |err| return foreground_job.failure(.restore_tui, @errorName(err));
            const outcome = foreground_job.run(&prepared, terminal, &tty.termios);
            if (outcome.isFatal()) return outcome;
            modes.restore(saved, vx, tty.writer(), mouse_policy) catch |err| return foreground_job.failure(.restore_tui, @errorName(err));
            const size = tty.getWinsize() catch |err| return foreground_job.failure(.restore_tui, @errorName(err));
            vx.resize(allocator, tty.writer(), size) catch |err| return foreground_job.failure(.restore_tui, @errorName(err));
            useUnicodeWidth(vx);
            var reader = loopReader(loop, io);
            reader.start() catch |err| return foreground_job.failure(.restore_tui, @errorName(err));
            vx.queueRefresh();
            return outcome;
        }
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

        /// Poll outside std.Io's bounded concurrency pool. The POSIX terminal
        /// baseline is two slots: libvaxis SIGWINCH handling and its tty reader.
        /// Joining the reader does not promise immediate backend slot reuse.
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
            try checkLoopInputFailure(self.loop);
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

/// Inspect the retained reason without consuming buffered events. Restart calls
/// this after the previous reader has joined, before start reopens the queue.
fn checkLoopInputFailure(loop: anytype) !void {
    try loop.queue.lock();
    defer loop.queue.unlock();
    if (loop.queue.closed) |err| {
        if (err != error.Closed) return err;
    }
}

/// Join before normal close so a racing input failure can retain its reason.
/// Cancel interrupts tty reads and full-queue waits without another Io slot.
fn stopLoopReader(loop: anytype, io: std.Io) void {
    if (loop.thread) |*future| {
        if (builtin.os.tag == .windows and !builtin.is_test) loop.tty.interruptInput();
        _ = future.cancel(io);
        loop.thread = null;
    }
    loop.queue.close(error.Closed);
}

pub fn drainInternalEventsForShutdown(
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
            // No callback during shutdown: queued Timer Notice owns no Msg.
            .timer_notification => {},
            else => {},
        }
    }
}

fn queryTerminal(
    vx: *vaxis.Vaxis,
    writer: *std.Io.Writer,
    io: std.Io,
    timeout: std.Io.Duration,
    keyboard_protocol: types.KeyboardProtocol,
    modes: *TerminalModes,
    reader: anytype,
) !void {
    // Split vaxis' query/wait/enable flow so Chasen can keep enhanced
    // keyboard reporting opt-in while still using the other detected features.
    modes.in_band_resize = true; // query emits 2048 even without a response
    errdefer modes.poison(vx, writer);
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
    reader.stop();
    const kitty = vx.caps.kitty_keyboard and vx.env_map.get("VHS_RECORD") == null;
    vx.caps.kitty_keyboard = false; // Own the non-idempotent push separately.
    modes.unicode = true; // Conservative cleanup ownership if enable fails.
    try vx.enableDetectedFeatures(writer);
    modes.unicode = vx.caps.unicode == .unicode and !vx.caps.explicit_width;
    vx.caps.kitty_keyboard = kitty;
    modes.kitty_flags = @bitCast(vx.opts.kitty_keyboard_flags);
    if (kitty) try modes.setKitty(vx, writer, true);
    try reader.start();
}

fn useUnicodeWidth(vx: *vaxis.Vaxis) void {
    // Keep the runtime surface width policy aligned with chasen.text.displayWidth.
    vx.caps.unicode = .unicode;
    vx.screen.width_method = .unicode;
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

    // During foreground execution the queue rejects wakes with Closed, while
    // the latest coalesced dimensions survive for the next runtime turn.
    var loop = vaxis.Loop(Event).init(std.testing.io, undefined, undefined);
    var resize_poll = ResizePollState(TestMsg).init(undefined, &loop);
    stopLoopReader(&loop, std.testing.io);
    try std.testing.expect(loop.thread == null);

    resize_poll.publish(.{ .rows = 50, .cols = 160, .x_pixel = 1600, .y_pixel = 1000 });
    try std.testing.expectError(error.Closed, loop.tryEvent());
    loop.queue.reopen();

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

test "loop reader refuses restart after failure before or during stop without consuming buffered input" {
    const Msg = enum {
        noop,
        pub const undelivered_policy = .plain;
    };
    const Loop = vaxis.Loop(InternalEvent(Msg));
    const Reader = struct {
        fn run(loop: *Loop, started: *std.Io.Event, io: std.Io) void {
            var wait: std.Io.Event = .unset;
            started.set(io);
            wait.wait(io) catch {
                // Deterministically return an input failure during cancel/join.
                loop.queue.close(error.EndOfStream);
                return;
            };
        }
    };
    for ([_]bool{ false, true }) |already_failed| {
        const io = std.testing.io;
        var loop = Loop.init(io, undefined, undefined);
        try std.testing.expect(try loop.tryPostEvent(.{ .key_press = .{ .codepoint = 'q' } }));
        var started: std.Io.Event = .unset;
        loop.thread = try io.concurrent(Reader.run, .{ &loop, &started, io });
        started.waitUncancelable(io);
        if (already_failed) loop.queue.close(error.EndOfStream);
        var reader = loopReader(&loop, io);
        reader.stop();
        try std.testing.expect(loop.thread == null);
        try std.testing.expectError(error.EndOfStream, reader.start());
        try std.testing.expectEqual(@as(u21, 'q'), (try loop.tryEvent()).?.key_press.codepoint);
        try std.testing.expectError(error.EndOfStream, loop.tryEvent());
    }
}

/// Wire ownership, distinct from capability responses in vx.state. This record
/// owns one kitty layer and only the modes enabled by this runtime invocation.
const TerminalModes = struct {
    in_band_resize: bool = false,
    unicode: bool = false,
    kitty: bool = false,
    kitty_flags: u5 = 0,
    kitty_uncertain: bool = false,
    poisoned: bool = false,
    const Saved = struct { modes: TerminalModes, alt: bool, paste: bool, mouse: bool, pixels: bool };
    fn snapshot(self: TerminalModes, vx: *vaxis.Vaxis) Saved {
        return .{ .modes = self, .alt = vx.state.alt_screen, .paste = vx.state.bracketed_paste, .mouse = vx.state.mouse, .pixels = vx.state.pixel_mouse };
    }
    fn poison(self: *TerminalModes, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        // Failed File.Writer flush retains its pending bytes. Never allow a
        // later reset/flush to replay a partially transmitted stack operation.
        _ = writer.consumeAll();
        self.poisoned = true;
        if (self.kitty_uncertain) {
            self.kitty = false;
            vx.state.kitty_keyboard = false;
        }
    }
    fn setKitty(self: *TerminalModes, vx: *vaxis.Vaxis, writer: *std.Io.Writer, enable: bool) !void {
        self.kitty_uncertain = true;
        errdefer self.poison(vx, writer);
        if (enable) try writer.print("\x1b[>{d}u", .{self.kitty_flags}) else try writer.writeAll("\x1b[<u");
        try writer.flush();
        self.kitty_uncertain = false;
        self.kitty = enable;
        vx.state.kitty_keyboard = enable;
    }
    fn leave(self: *TerminalModes, vx: *vaxis.Vaxis, writer: *std.Io.Writer, mouse: terminal_mouse.Policy) !void {
        errdefer self.poison(vx, writer);
        try mouse.leave(vx, writer);
        try vx.setBracketedPaste(writer, false);
        if (self.in_band_resize) {
            try writer.writeAll("\x1b[?2048l");
            try writer.flush();
            self.in_band_resize = false;
        }
        vx.state.in_band_resize = false;
        if (self.unicode) {
            try writer.writeAll("\x1b[?2027l");
            try writer.flush();
            self.unicode = false;
        }
        if (self.kitty) try self.setKitty(vx, writer, false);
        try writer.writeAll("\x1b[?25h\x1b[0m\x1b[0 q");
        try writer.flush();
        if (vx.state.alt_screen) try vx.exitAltScreen(writer);
    }
    fn restore(self: *TerminalModes, saved: Saved, vx: *vaxis.Vaxis, writer: *std.Io.Writer, mouse: terminal_mouse.Policy) !void {
        errdefer self.poison(vx, writer);
        if (saved.alt) try vx.enterAltScreen(writer);
        if (saved.modes.unicode) {
            self.unicode = true;
            try writer.writeAll("\x1b[?2027h");
            try writer.flush();
        }
        self.kitty_flags = saved.modes.kitty_flags;
        if (saved.modes.kitty) try self.setKitty(vx, writer, true);
        if (saved.modes.in_band_resize) {
            self.in_band_resize = true;
            try writer.writeAll("\x1b[?2048h");
            try writer.flush();
        }
        if (saved.paste) try vx.setBracketedPaste(writer, true);
        if (saved.mouse) try mouse.enterCoordinates(vx, writer, saved.pixels);
    }
    fn cleanup(self: *TerminalModes, vx: *vaxis.Vaxis, writer: *std.Io.Writer) void {
        // Idempotent final resets use only a clean buffer. The one known kitty
        // layer is popped at most once; an uncertain stack is never retried.
        if (self.poisoned) _ = writer.consumeAll();
        if (self.kitty and !self.kitty_uncertain) self.setKitty(vx, writer, false) catch {};
        vx.state.kitty_keyboard = false;
        if (self.in_band_resize) writer.writeAll("\x1b[?2048l") catch {
            _ = writer.consumeAll();
        };
        if (self.unicode) writer.writeAll("\x1b[?2027l") catch {
            _ = writer.consumeAll();
        };
        writer.flush() catch {
            _ = writer.consumeAll();
        };
        vx.state.in_band_resize = false;
        self.in_band_resize = false;
        self.unicode = false;
    }
};

const ForegroundWireWriter = struct {
    writer: std.Io.Writer,
    output: [1024]u8 = undefined,
    used: usize = 0,
    remaining: usize,
    fn init(buffer: []u8, budget: usize) ForegroundWireWriter {
        return .{ .writer = .{ .vtable = &.{ .drain = drain }, .buffer = buffer }, .remaining = budget };
    }
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *ForegroundWireWriter = @alignCast(@fieldParentPtr("writer", writer));
        if (self.remaining == 0) return error.WriteFailed;
        const header = writer.buffered();
        if (header.len > 0) {
            const n = @min(header.len, self.remaining);
            @memcpy(self.output[self.used..][0..n], header[0..n]);
            self.used += n;
            self.remaining -= n;
            return writer.consume(n);
        }
        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            const n = @min(chunk.len, self.remaining);
            @memcpy(self.output[self.used..][0..n], chunk[0..n]);
            self.used += n;
            self.remaining -= n;
            consumed += n;
            if (n != chunk.len) return consumed;
        }
        for (0..splat) |_| {
            const chunk = data[data.len - 1];
            const n = @min(chunk.len, self.remaining);
            @memcpy(self.output[self.used..][0..n], chunk[0..n]);
            self.used += n;
            self.remaining -= n;
            consumed += n;
            if (n != chunk.len) return consumed;
        }
        return consumed;
    }
};

test "foreground uncertain buffered kitty bytes cannot replay during final cleanup" {
    for ([_]bool{ false, true }) |enable| {
        var env = try std.testing.environ.createMap(std.testing.allocator);
        defer env.deinit();
        var vx = try vaxis.Vaxis.init(std.testing.io, std.testing.allocator, &env, .{});
        var buffer: [64]u8 = undefined;
        var writer = ForegroundWireWriter.init(&buffer, 2);
        var modes: TerminalModes = .{ .kitty = !enable, .kitty_flags = 1, .in_band_resize = true };
        vx.state.kitty_keyboard = !enable;
        // Two bytes reach the simulated terminal, the remaining stack bytes
        // stay buffered when the next native drain fails.
        try std.testing.expectError(error.WriteFailed, modes.setKitty(&vx, &writer.writer, enable));
        try std.testing.expectEqual(@as(usize, 0), writer.writer.end);
        try std.testing.expect(modes.kitty_uncertain);
        try std.testing.expect(!vx.state.kitty_keyboard);
        writer.remaining = 900;
        modes.cleanup(&vx, &writer.writer);
        vx.deinit(std.testing.allocator, &writer.writer);
        const output = writer.output[0..writer.used];
        try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[>1u") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[<u") == null);
        try std.testing.expect(std.mem.indexOf(u8, output, "\x1b[?2048l") != null);
    }
}

test "foreground leave failures at every byte prevent duplicate kitty cleanup" {
    // One real buffered writer, not a mock operation counter: exercise all
    // partial boundaries of the finite leave sequence including its flushes.
    for (0..90) |budget| {
        var env = try std.testing.environ.createMap(std.testing.allocator);
        defer env.deinit();
        var vx = try vaxis.Vaxis.init(std.testing.io, std.testing.allocator, &env, .{});
        vx.state.kitty_keyboard = true;
        vx.state.alt_screen = true;
        vx.state.bracketed_paste = true;
        vx.state.mouse = true;
        var buffer: [64]u8 = undefined;
        var writer = ForegroundWireWriter.init(&buffer, budget);
        var modes: TerminalModes = .{ .kitty = true, .kitty_flags = 1, .in_band_resize = true, .unicode = true };
        const mouse: terminal_mouse.Policy = .{ .enabled = true, .coordinate_protocol = .cell_sgr };
        modes.leave(&vx, &writer.writer, mouse) catch {
            try std.testing.expect(modes.poisoned);
            try std.testing.expectEqual(@as(usize, 0), writer.writer.end);
        };
        writer.remaining = 900;
        modes.cleanup(&vx, &writer.writer);
        vx.deinit(std.testing.allocator, &writer.writer);
        try std.testing.expect(std.mem.count(u8, writer.output[0..writer.used], "\x1b[<u") <= 1);
    }
}

test "foreground restore failures at every byte never replay the kitty push" {
    for (0..90) |budget| {
        var env = try std.testing.environ.createMap(std.testing.allocator);
        defer env.deinit();
        var vx = try vaxis.Vaxis.init(std.testing.io, std.testing.allocator, &env, .{});
        var buffer: [64]u8 = undefined;
        var writer = ForegroundWireWriter.init(&buffer, budget);
        var modes: TerminalModes = .{};
        const saved: TerminalModes.Saved = .{
            .modes = .{ .kitty = true, .kitty_flags = 1, .in_band_resize = true, .unicode = true },
            .alt = true,
            .paste = true,
            .mouse = true,
            .pixels = true,
        };
        const mouse: terminal_mouse.Policy = .{ .enabled = true, .coordinate_protocol = .auto };
        modes.restore(saved, &vx, &writer.writer, mouse) catch {
            try std.testing.expect(modes.poisoned);
            try std.testing.expectEqual(@as(usize, 0), writer.writer.end);
        };
        writer.remaining = 900;
        modes.cleanup(&vx, &writer.writer);
        vx.deinit(std.testing.allocator, &writer.writer);
        const output = writer.output[0..writer.used];
        try std.testing.expect(std.mem.count(u8, output, "\x1b[>1u") <= 1);
        try std.testing.expect(std.mem.count(u8, output, "\x1b[<u") <= 1);
    }
}

test "terminal session initialization unwinds allocation failures and binds final storage" {
    const Case = struct {
        fn run(allocator: std.mem.Allocator, env: *std.process.Environ.Map, failures: *usize) !void {
            const Msg = enum {
                noop,
                pub const undelivered_policy = .plain;
            };
            var session: TerminalSession(Msg) = undefined;
            session.init(allocator, std.testing.io, .{ .env_map = env }) catch |err| {
                if (err == error.OutOfMemory) failures.* += 1;
                if (comptime builtin.os.tag == .linux) {
                    // TestTty allocates independently before the injected Vaxis
                    // allocator fails. Its descriptor must have been closed.
                    if (err == error.OutOfMemory) try std.testing.expectEqual(std.os.linux.E.BADF, std.os.linux.errno(std.os.linux.fcntl(session.tty.fd, std.os.linux.F.GETFD, 0)));
                }
                return err;
            };
            defer session.deinit();
            try std.testing.expect(session.loop.tty == &session.tty);
            try std.testing.expect(session.loop.vaxis == &session.vx);
            try std.testing.expect(session.resize_poll.tty == &session.tty);
            try std.testing.expect(session.resize_poll.loop == &session.loop);
            try std.testing.expect(!session.suspended.load(.seq_cst));
        }
    };
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    var failures: usize = 0;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{ &env, &failures });
    try std.testing.expect(failures > 0);
}

test "terminal session setup unwinds initial query and mouse reader start failures" {
    const Reader = struct {
        calls: usize = 0,
        fail_at: usize,
        running: bool = false,
        pub fn start(self: *@This()) !void {
            self.calls += 1;
            if (self.calls == self.fail_at) return error.StartFailed;
            self.running = true;
        }
        pub fn stop(self: *@This()) void {
            self.running = false;
        }
    };
    const Msg = struct {
        bytes: []u8,
        freed: *usize,
        pub const undelivered_policy = .deinit;
        pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
            self.freed.* += 1;
        }
    };
    for (1..4) |fail_at| {
        var freed: usize = 0;
        {
            var env: std.process.Environ.Map = .init(std.testing.allocator);
            defer env.deinit();
            var session: TerminalSession(Msg) = undefined;
            try session.init(std.testing.allocator, std.testing.io, .{ .env_map = &env, .mouse = true });
            defer session.deinit();
            session.vx.query_futex.store(1, .release);
            try std.testing.expect(try session.loop.tryPostEvent(.{ .user_msg = .{
                .bytes = try std.testing.allocator.dupe(u8, "setup owned message"),
                .freed = &freed,
            } }));
            var reader: Reader = .{ .fail_at = fail_at };
            try std.testing.expectError(error.StartFailed, session.startWithReader(&reader));
            try std.testing.expectEqual(fail_at, reader.calls);
            try std.testing.expect(!reader.running);
            try std.testing.expect(session.loop.thread == null);
            if (fail_at > 1) {
                try std.testing.expectEqual(@as(usize, 1), freed);
                try std.testing.expectEqual(@as(?InternalEvent(Msg), null), try session.loop.tryEvent());
            }
            if (fail_at == 2) try std.testing.expect(session.modes.poisoned);
            if (fail_at == 3) {
                try std.testing.expect(!session.vx.state.mouse);
                try std.testing.expect(!session.vx.state.bracketed_paste);
            }
        }
        try std.testing.expectEqual(@as(usize, 1), freed);
    }
}
