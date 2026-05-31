const std = @import("std");
const cmd_mod = @import("cmd.zig");
const terminal_image = @import("terminal_image.zig");

/// Context object passed to `update`, providing side-effect methods.
///
/// Provides `quit()` to exit the application and `spawn()` to launch
/// async tasks whose results are delivered back as messages.
pub fn Ctx(comptime Msg: type) type {
    const TaskFn = *const fn (std.mem.Allocator, std.Io) Msg;
    const max_tasks = 16;
    const max_ticks = 8;
    const max_everys = 8;
    const max_terminal_image_loads = 8;
    const max_terminal_image_unloads = 8;

    const max_cancels = 8;

    return struct {
        pub const TerminalImageLoadedFn = *const fn (*anyopaque, terminal_image.TerminalImageHandle) Msg;
        pub const TerminalImageFailedFn = *const fn (*anyopaque, terminal_image.LoadError) Msg;

        pub const TickEntry = struct {
            id: []const u8,
            after_ns: u64,
            msg: Msg,
        };

        pub const EveryEntry = struct {
            id: []const u8,
            interval_ns: u64,
            msg: Msg,
        };

        pub const TaskWithEntry = struct {
            ctx: *anyopaque,
            run: *const fn (*anyopaque, std.mem.Allocator, std.Io) Msg,
        };

        pub const TerminalImageLoadEntry = struct {
            path: []const u8,
            ctx: *anyopaque,
            loaded: TerminalImageLoadedFn,
            failed: TerminalImageFailedFn,
        };

        // Private runtime handles. Set by Program before passing to app code.
        _io: std.Io = undefined,
        _allocator: std.mem.Allocator = undefined,
        should_quit: bool = false,
        pending_tasks: [max_tasks]TaskFn = undefined,
        pending_tasks_len: u8 = 0,
        pending_tasks_with: [max_tasks]TaskWithEntry = undefined,
        pending_tasks_with_len: u8 = 0,
        pending_ticks: [max_ticks]TickEntry = undefined,
        pending_ticks_len: u8 = 0,
        pending_everys: [max_everys]EveryEntry = undefined,
        pending_everys_len: u8 = 0,
        pending_cancels: [max_cancels][]const u8 = undefined,
        pending_cancels_len: u8 = 0,
        pending_terminal_image_loads: [max_terminal_image_loads]TerminalImageLoadEntry = undefined,
        pending_terminal_image_loads_len: u8 = 0,
        pending_terminal_image_unloads: [max_terminal_image_unloads]terminal_image.TerminalImageHandle = undefined,
        pending_terminal_image_unloads_len: u8 = 0,
        redraw_suppressed: bool = false,
        frame_requested: bool = false,

        /// Request the application to exit.
        pub fn quit(self: *@This()) void {
            self.should_quit = true;
        }

        /// Spawn an async task. The task function will be called concurrently
        /// and its return value delivered as a message to `update`.
        /// The task is queued here and started by the runtime after `update` returns.
        /// Returns `error.TaskLimitExceeded` if the pending task queue is full.
        pub fn spawn(self: *@This(), task: TaskFn) error{TaskLimitExceeded}!void {
            if (self.pending_tasks_len + self.pending_tasks_with_len >= max_tasks) return error.TaskLimitExceeded;
            self.pending_tasks[self.pending_tasks_len] = task;
            self.pending_tasks_len += 1;
        }

        /// Return a slice of pending tasks.
        pub fn pendingSlice(self: *@This()) []const TaskFn {
            return self.pending_tasks[0..self.pending_tasks_len];
        }

        /// Spawn an async task with captured context.
        ///
        /// The caller must ensure `ctx` remains valid until the task finishes
        /// or is cancelled.
        /// The task is queued here and started by the runtime after `update` returns.
        /// Returns `error.TaskLimitExceeded` if the combined pending task queue is full.
        pub fn spawnWith(
            self: *@This(),
            ctx_ptr: *anyopaque,
            run_fn: *const fn (*anyopaque, std.mem.Allocator, std.Io) Msg,
        ) error{TaskLimitExceeded}!void {
            if (self.pending_tasks_len + self.pending_tasks_with_len >= max_tasks)
                return error.TaskLimitExceeded;
            self.pending_tasks_with[self.pending_tasks_with_len] = .{
                .ctx = ctx_ptr,
                .run = run_fn,
            };
            self.pending_tasks_with_len += 1;
        }

        /// Return a slice of pending task-with entries.
        pub fn pendingTaskWithSlice(self: *@This()) []const TaskWithEntry {
            return self.pending_tasks_with[0..self.pending_tasks_with_len];
        }

        /// Queue a local terminal image path to be loaded by the runtime.
        ///
        /// The path is copied while queueing because effects are drained after
        /// `init`/`update` returns. The runtime frees the copied path after it
        /// posts either `loaded` or `failed`.
        pub fn loadTerminalImagePath(
            self: *@This(),
            path: []const u8,
            ctx_ptr: *anyopaque,
            loaded_fn: TerminalImageLoadedFn,
            failed_fn: TerminalImageFailedFn,
        ) (error{TerminalImageLoadLimitExceeded} || std.mem.Allocator.Error)!void {
            if (self.pending_terminal_image_loads_len >= max_terminal_image_loads)
                return error.TerminalImageLoadLimitExceeded;

            const copied_path = try self._allocator.dupe(u8, path);
            self.pending_terminal_image_loads[self.pending_terminal_image_loads_len] = .{
                .path = copied_path,
                .ctx = ctx_ptr,
                .loaded = loaded_fn,
                .failed = failed_fn,
            };
            self.pending_terminal_image_loads_len += 1;
        }

        pub fn pendingTerminalImageLoadSlice(self: *@This()) []const TerminalImageLoadEntry {
            return self.pending_terminal_image_loads[0..self.pending_terminal_image_loads_len];
        }

        /// Queue a terminal image handle for release by the runtime.
        ///
        /// Unlike timer cancellation, image unload is an explicit resource
        /// lifecycle operation, so queue pressure is observable to the app.
        pub fn unloadTerminalImage(self: *@This(), handle: terminal_image.TerminalImageHandle) error{TerminalImageUnloadLimitExceeded}!void {
            if (self.pending_terminal_image_unloads_len >= max_terminal_image_unloads)
                return error.TerminalImageUnloadLimitExceeded;
            self.pending_terminal_image_unloads[self.pending_terminal_image_unloads_len] = handle;
            self.pending_terminal_image_unloads_len += 1;
        }

        pub fn pendingTerminalImageUnloadSlice(self: *@This()) []const terminal_image.TerminalImageHandle {
            return self.pending_terminal_image_unloads[0..self.pending_terminal_image_unloads_len];
        }

        /// Schedule a one-shot delayed message.
        /// The message will be delivered once after `after_ns` nanoseconds.
        /// If a timer with the same `id` is already pending, it is overwritten.
        /// Returns `error.TimerLimitExceeded` if the pending timer queue is full.
        ///
        /// `id` must point to memory that remains valid for the lifetime of the timer
        /// (e.g. a string literal or application-owned slice).
        pub fn tick(self: *@This(), id: []const u8, after_ns: u64, msg: Msg) error{TimerLimitExceeded}!void {
            // Overwrite existing entry with the same id.
            for (self.pending_ticks[0..self.pending_ticks_len]) |*entry| {
                if (std.mem.eql(u8, entry.id, id)) {
                    entry.* = .{ .id = id, .after_ns = after_ns, .msg = msg };
                    return;
                }
            }
            if (self.pending_ticks_len >= max_ticks) return error.TimerLimitExceeded;
            self.pending_ticks[self.pending_ticks_len] = .{ .id = id, .after_ns = after_ns, .msg = msg };
            self.pending_ticks_len += 1;
        }

        /// Return a slice of pending tick entries.
        pub fn pendingTickSlice(self: *@This()) []const TickEntry {
            return self.pending_ticks[0..self.pending_ticks_len];
        }

        /// Schedule a repeating timer.
        /// The message will be delivered every `interval_ns` nanoseconds
        /// until the future is cancelled.
        /// If a timer with the same `id` is already pending, it is overwritten.
        /// Returns `error.TimerLimitExceeded` if the pending timer queue is full.
        ///
        /// `id` must point to memory that remains valid for the lifetime of the timer
        /// (e.g. a string literal or application-owned slice).
        pub fn every(self: *@This(), id: []const u8, interval_ns: u64, msg: Msg) error{TimerLimitExceeded}!void {
            // Overwrite existing entry with the same id.
            for (self.pending_everys[0..self.pending_everys_len]) |*entry| {
                if (std.mem.eql(u8, entry.id, id)) {
                    entry.* = .{ .id = id, .interval_ns = interval_ns, .msg = msg };
                    return;
                }
            }
            if (self.pending_everys_len >= max_everys) return error.TimerLimitExceeded;
            self.pending_everys[self.pending_everys_len] = .{ .id = id, .interval_ns = interval_ns, .msg = msg };
            self.pending_everys_len += 1;
        }

        /// Return the current monotonic timestamp.
        pub fn now(self: *const @This()) std.Io.Timestamp {
            return std.Io.Clock.now(.awake, self._io);
        }

        /// Return the program-level allocator.
        pub fn allocator(self: *const @This()) std.mem.Allocator {
            return self._allocator;
        }

        /// Return the runtime I/O handle.
        pub fn io(self: *const @This()) std.Io {
            return self._io;
        }

        /// Return a slice of pending every entries.
        pub fn pendingEverySlice(self: *@This()) []const EveryEntry {
            return self.pending_everys[0..self.pending_everys_len];
        }

        /// Cancel a timer by id.
        /// Removes any matching entry from the pending tick/every queues.
        /// Also queues the id for the runtime to cancel running timers.
        /// If the pending cancel queue is full, the cancel request is silently dropped.
        pub fn cancelTimer(self: *@This(), id: []const u8) void {
            // Remove from pending ticks (swap-remove).
            {
                var i: u8 = 0;
                while (i < self.pending_ticks_len) {
                    if (std.mem.eql(u8, self.pending_ticks[i].id, id)) {
                        self.pending_ticks_len -= 1;
                        if (i < self.pending_ticks_len) {
                            self.pending_ticks[i] = self.pending_ticks[self.pending_ticks_len];
                        }
                    } else {
                        i += 1;
                    }
                }
            }
            // Remove from pending everys (swap-remove).
            {
                var i: u8 = 0;
                while (i < self.pending_everys_len) {
                    if (std.mem.eql(u8, self.pending_everys[i].id, id)) {
                        self.pending_everys_len -= 1;
                        if (i < self.pending_everys_len) {
                            self.pending_everys[i] = self.pending_everys[self.pending_everys_len];
                        }
                    } else {
                        i += 1;
                    }
                }
            }
            // Queue for runtime to cancel running timers.
            if (self.pending_cancels_len < max_cancels) {
                self.pending_cancels[self.pending_cancels_len] = id;
                self.pending_cancels_len += 1;
            }
        }

        /// Return a slice of pending cancel ids.
        pub fn pendingCancelSlice(self: *@This()) []const []const u8 {
            return self.pending_cancels[0..self.pending_cancels_len];
        }

        /// Suppress the default redraw for the current update cycle.
        ///
        /// By default, `view` is called after every `update`. Call this
        /// method inside `update` when the message does not affect
        /// the visual state and a redraw would be wasteful.
        pub fn suppressRedraw(self: *@This()) void {
            self.redraw_suppressed = true;
        }

        /// Request one future frame event.
        ///
        /// The runtime coalesces repeated calls while a frame is already
        /// pending. Call this again from the frame update to keep animating.
        pub fn requestFrame(self: *@This()) void {
            self.frame_requested = true;
        }

        /// Dispatch a command descriptor.
        ///
        /// Maps each `Cmd` variant to the corresponding `Ctx` method.
        /// `batch` and `sequence` are dispatched recursively. Their command
        /// slices must remain valid until this method returns.
        ///
        /// Note: `sequence` currently guarantees dispatch order only. It does
        /// not wait for timer or task completion.
        pub fn dispatch(self: *@This(), command: cmd_mod.Cmd(Msg)) (error{TaskLimitExceeded} || error{TimerLimitExceeded})!void {
            switch (command) {
                .none => {},
                .quit => self.quit(),
                .suppress_redraw => self.suppressRedraw(),
                .request_frame => self.requestFrame(),
                .cancel_timer => |id| self.cancelTimer(id),
                .task => |task_fn| try self.spawn(task_fn),
                .task_with => |tw| try self.spawnWith(tw.ctx, tw.run),
                .tick => |t| try self.tick(t.id, t.after_ns, t.msg),
                .every => |e| try self.every(e.id, e.interval_ns, e.msg),
                .batch => |cmds| {
                    for (cmds) |c| try self.dispatch(c);
                },
                .sequence => |cmds| {
                    for (cmds) |c| try self.dispatch(c);
                },
            }
        }
    };
}

test "Ctx spawn accumulates tasks" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    const task1 = &struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .hello;
        }
    }.run;

    try ctx_val.spawn(task1);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_tasks_len);

    try ctx_val.spawn(task1);
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_tasks_len);

    const slice = ctx_val.pendingSlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
}

test "Ctx requestFrame marks a pending frame request" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    try std.testing.expectEqual(false, ctx_val.frame_requested);
    ctx_val.requestFrame();
    try std.testing.expectEqual(true, ctx_val.frame_requested);
}

test "Ctx spawn returns error when task queue is full" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    const task = &struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .hello;
        }
    }.run;

    for (0..16) |_| try ctx_val.spawn(task);
    try std.testing.expectError(error.TaskLimitExceeded, ctx_val.spawn(task));
}

test "Ctx tick accumulates entries" {
    const TestMsg = union(enum) { timeout, ping };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.tick("t1", 1_000_000_000, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);

    try ctx_val.tick("t2", 500_000_000, .ping);
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_ticks_len);

    const slice = ctx_val.pendingTickSlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), slice[0].after_ns);
    try std.testing.expect(slice[0].msg == .timeout);
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[1].after_ns);
    try std.testing.expect(slice[1].msg == .ping);
}

test "Ctx tick returns error when timer queue is full" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{};

    for (0..8) |i| {
        const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
        try ctx_val.tick(ids[i], 1_000_000_000, .timeout);
    }
    try std.testing.expectError(error.TimerLimitExceeded, ctx_val.tick("overflow", 1_000_000_000, .timeout));
}

test "Ctx every accumulates entries" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.every("e1", 1_000_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    try ctx_val.every("e2", 500_000_000, .heartbeat);
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_everys_len);

    const slice = ctx_val.pendingEverySlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), slice[0].interval_ns);
    try std.testing.expect(slice[0].msg == .tick_msg);
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[1].interval_ns);
    try std.testing.expect(slice[1].msg == .heartbeat);
}

test "Ctx every returns error when timer queue is full" {
    const TestMsg = union(enum) { tick_msg };
    var ctx_val: Ctx(TestMsg) = .{};

    for (0..8) |i| {
        const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
        try ctx_val.every(ids[i], 1_000_000_000, .tick_msg);
    }
    try std.testing.expectError(error.TimerLimitExceeded, ctx_val.every("overflow", 1_000_000_000, .tick_msg));
}

test "Ctx tick same id overwrites existing entry" {
    const TestMsg = union(enum) { timeout, ping };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.tick("timer1", 1_000_000_000, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);

    // Same id should overwrite, not grow the queue.
    try ctx_val.tick("timer1", 2_000_000_000, .ping);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);

    const slice = ctx_val.pendingTickSlice();
    try std.testing.expectEqual(@as(u64, 2_000_000_000), slice[0].after_ns);
    try std.testing.expect(slice[0].msg == .ping);
}

test "Ctx every same id overwrites existing entry" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.every("refresh", 1_000_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    // Same id should overwrite.
    try ctx_val.every("refresh", 500_000_000, .heartbeat);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    const slice = ctx_val.pendingEverySlice();
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[0].interval_ns);
    try std.testing.expect(slice[0].msg == .heartbeat);
}

test "Ctx cancelTimer removes from pending queues" {
    const TestMsg = union(enum) { timeout, tick_msg };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.tick("t1", 1_000_000_000, .timeout);
    try ctx_val.every("e1", 500_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    ctx_val.cancelTimer("t1");
    try std.testing.expectEqual(@as(u8, 0), ctx_val.pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    ctx_val.cancelTimer("e1");
    try std.testing.expectEqual(@as(u8, 0), ctx_val.pending_everys_len);
}

test "Ctx cancelTimer queues id for runtime cancellation" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{};

    ctx_val.cancelTimer("running_timer");
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_cancels_len);

    const cancels = ctx_val.pendingCancelSlice();
    try std.testing.expectEqual(@as(usize, 1), cancels.len);
    try std.testing.expectEqualStrings("running_timer", cancels[0]);
}

test "Ctx spawnWith accumulates tasks" {
    const TestMsg = union(enum) { done };
    var ctx_val: Ctx(TestMsg) = .{};

    var dummy_ctx: u32 = 42;
    const run_fn = &struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: std.Io) TestMsg {
            return .done;
        }
    }.run;

    try ctx_val.spawnWith(@ptrCast(&dummy_ctx), run_fn);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_tasks_with_len);

    try ctx_val.spawnWith(@ptrCast(&dummy_ctx), run_fn);
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_tasks_with_len);

    const slice = ctx_val.pendingTaskWithSlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
}

test "Ctx loadTerminalImagePath copies queued path" {
    const TestMsg = union(enum) { loaded, failed };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };

    var path_buf = [_]u8{ 'a', '.', 'p', 'n', 'g' };
    try ctx_val.loadTerminalImagePath(&path_buf, undefined, &struct {
        fn loaded(_: *anyopaque, _: terminal_image.TerminalImageHandle) TestMsg {
            return .loaded;
        }
    }.loaded, &struct {
        fn failed(_: *anyopaque, _: terminal_image.LoadError) TestMsg {
            return .failed;
        }
    }.failed);
    defer {
        for (ctx_val.pendingTerminalImageLoadSlice()) |entry| {
            std.testing.allocator.free(entry.path);
        }
        ctx_val.pending_terminal_image_loads_len = 0;
    }

    path_buf[0] = 'b';

    const pending = ctx_val.pendingTerminalImageLoadSlice();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqualStrings("a.png", pending[0].path);
}

test "Ctx unloadTerminalImage queues handles" {
    const TestMsg = union(enum) { done };
    var ctx_val: Ctx(TestMsg) = .{};

    const handle = terminal_image.TerminalImageHandle{ .id = 7, .generation = 2 };
    try ctx_val.unloadTerminalImage(handle);

    const pending = ctx_val.pendingTerminalImageUnloadSlice();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(handle, pending[0]);
}

test "Ctx unloadTerminalImage returns error when queue is full" {
    const TestMsg = union(enum) { done };
    var ctx_val: Ctx(TestMsg) = .{};

    const handle = terminal_image.TerminalImageHandle{ .id = 7, .generation = 2 };
    for (0..8) |_| try ctx_val.unloadTerminalImage(handle);

    try std.testing.expectError(error.TerminalImageUnloadLimitExceeded, ctx_val.unloadTerminalImage(handle));
}

test "dispatch .none does nothing" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.dispatch(.none);

    try std.testing.expectEqual(@as(u8, 0), ctx_val.pending_tasks_len);
    try std.testing.expectEqual(false, ctx_val.should_quit);
}

test "dispatch .quit sets should_quit" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.dispatch(.quit);

    try std.testing.expectEqual(true, ctx_val.should_quit);
}

test "dispatch .suppress_redraw sets redraw_suppressed" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.dispatch(.suppress_redraw);

    try std.testing.expectEqual(true, ctx_val.redraw_suppressed);
}

test "dispatch .request_frame marks a pending frame request" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.dispatch(.request_frame);

    try std.testing.expectEqual(true, ctx_val.frame_requested);
}

test "dispatch .task queues a task" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.dispatch(.{ .task = &struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .hello;
        }
    }.run });

    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_tasks_len);
}

test "dispatch .task_with queues a task_with" {
    const TestMsg = union(enum) { done };
    var ctx_val: Ctx(TestMsg) = .{};

    var dummy: u32 = 42;
    try ctx_val.dispatch(.{ .task_with = .{
        .ctx = @ptrCast(&dummy),
        .run = &struct {
            fn run(_: *anyopaque, _: std.mem.Allocator, _: std.Io) TestMsg {
                return .done;
            }
        }.run,
    } });

    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_tasks_with_len);
}

test "dispatch .tick queues a tick" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.dispatch(.{ .tick = .{ .id = "t1", .after_ns = 1_000_000, .msg = .timeout } });

    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);
}

test "dispatch .every queues an every" {
    const TestMsg = union(enum) { tick_msg };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.dispatch(.{ .every = .{ .id = "e1", .interval_ns = 500_000, .msg = .tick_msg } });

    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);
}

test "dispatch .cancel_timer queues a cancel" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{};

    try ctx_val.dispatch(.{ .cancel_timer = "timer1" });

    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_cancels_len);
    try std.testing.expectEqualStrings("timer1", ctx_val.pendingCancelSlice()[0]);
}

test "dispatch .batch processes multiple commands" {
    const TestMsg = union(enum) { hello, timeout };
    const C = cmd_mod.Cmd(TestMsg);
    var ctx_val: Ctx(TestMsg) = .{};

    const cmds = [_]C{
        .quit,
        .request_frame,
        .suppress_redraw,
        .{ .tick = .{ .id = "t1", .after_ns = 1_000_000, .msg = .timeout } },
        .{ .task = &struct {
            fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
                return .hello;
            }
        }.run },
    };
    try ctx_val.dispatch(.{ .batch = &cmds });

    try std.testing.expectEqual(true, ctx_val.should_quit);
    try std.testing.expectEqual(true, ctx_val.frame_requested);
    try std.testing.expectEqual(true, ctx_val.redraw_suppressed);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_tasks_len);
}

test "dispatch .sequence processes multiple commands" {
    const TestMsg = union(enum) { hello, timeout };
    const C = cmd_mod.Cmd(TestMsg);
    var ctx_val: Ctx(TestMsg) = .{};

    const cmds = [_]C{
        .quit,
        .{ .every = .{ .id = "e1", .interval_ns = 500_000, .msg = .timeout } },
    };
    try ctx_val.dispatch(.{ .sequence = &cmds });

    try std.testing.expectEqual(true, ctx_val.should_quit);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);
}

test "Ctx redraw_suppressed defaults to false" {
    const TestMsg = union(enum) { hello };
    const ctx_val: Ctx(TestMsg) = .{};

    try std.testing.expectEqual(false, ctx_val.redraw_suppressed);
}

test "Ctx suppressRedraw sets redraw_suppressed to true" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    ctx_val.suppressRedraw();
    try std.testing.expectEqual(true, ctx_val.redraw_suppressed);
}

test "Ctx spawn and spawnWith share task limit" {
    const TestMsg = union(enum) { hello, done };
    var ctx_val: Ctx(TestMsg) = .{};

    const task = &struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .hello;
        }
    }.run;

    var dummy_ctx: u32 = 0;
    const run_with = &struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: std.Io) TestMsg {
            return .done;
        }
    }.run;

    // Fill 10 with spawn, 6 with spawnWith = 16 total (max_tasks)
    for (0..10) |_| try ctx_val.spawn(task);
    for (0..6) |_| try ctx_val.spawnWith(@ptrCast(&dummy_ctx), run_with);

    // Both should fail now
    try std.testing.expectError(error.TaskLimitExceeded, ctx_val.spawn(task));
    try std.testing.expectError(error.TaskLimitExceeded, ctx_val.spawnWith(@ptrCast(&dummy_ctx), run_with));
}
