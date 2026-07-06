const std = @import("std");
const terminal_image = @import("terminal_image_types.zig");
const foreground_command = @import("foreground_command.zig");

pub const TaskFailure = union(enum) {
    start_failed: []const u8,
};

/// Context object passed to `init` and `update`.
///
/// `Ctx` queues runtime effects for the program to drain after the current
/// app callback returns. Effects are grouped by capability namespace, while
/// `quit()` remains a direct shortcut because nearly every interactive app
/// needs it.
pub fn Ctx(comptime Msg: type) type {
    const TaskFn = *const fn (std.mem.Allocator, std.Io) Msg;
    const TaskFailedFn = *const fn (TaskFailure) Msg;
    const max_tasks = 16;
    const max_ticks = 8;
    const max_everys = 8;
    const max_terminal_image_loads = 8;
    const max_terminal_image_unloads = 8;
    const max_foreground_commands = 1;

    const max_cancels = 8;

    return struct {
        const Self = @This();
        const TimerScheduleError = error{TimerLimitExceeded} || std.mem.Allocator.Error;
        const TimerCancelError = error{TimerCancelLimitExceeded} || std.mem.Allocator.Error;

        pub const TerminalImageLoadedFn = *const fn (terminal_image.TerminalImageRequestId, terminal_image.TerminalImageHandle) Msg;
        pub const TerminalImageFailedFn = *const fn (terminal_image.TerminalImageRequestId, terminal_image.LoadError) Msg;
        pub const ForegroundCommandFinishedFn = *const fn (foreground_command.ForegroundCommandResult) Msg;

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
            failed: *const fn (*anyopaque, TaskFailure, std.mem.Allocator) Msg,
        };

        pub const SpawnOptions = struct {
            run: TaskFn,
            failed: TaskFailedFn,
        };

        pub const SpawnWithOptions = struct {
            ctx: *anyopaque,
            run: *const fn (*anyopaque, std.mem.Allocator, std.Io) Msg,
            failed: *const fn (*anyopaque, TaskFailure, std.mem.Allocator) Msg,
        };

        pub const TaskEntry = struct {
            run: TaskFn,
            failed: TaskFailedFn,
        };

        pub const TerminalImageLoadEntry = struct {
            request_id: terminal_image.TerminalImageRequestId,
            path: []const u8,
            loaded: TerminalImageLoadedFn,
            failed: TerminalImageFailedFn,
        };

        pub const ForegroundCommandEntry = struct {
            request_id: foreground_command.ForegroundCommandRequestId,
            argv: []const []const u8,
            cwd: ?[]const u8,
            finished: ForegroundCommandFinishedFn,
        };

        // Private runtime handles. Set by Program before passing to app code.
        _io: std.Io = undefined,
        _allocator: std.mem.Allocator = undefined,
        should_quit: bool = false,
        pending_tasks: [max_tasks]TaskEntry = undefined,
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
        next_terminal_image_request_id: u64 = 1,
        pending_terminal_image_unloads: [max_terminal_image_unloads]terminal_image.TerminalImageHandle = undefined,
        pending_terminal_image_unloads_len: u8 = 0,
        pending_foreground_commands: [max_foreground_commands]ForegroundCommandEntry = undefined,
        pending_foreground_commands_len: u8 = 0,
        next_foreground_command_request_id: u64 = 1,
        redraw_suppressed: bool = false,
        frame_requested: bool = false,

        pub const FrameEffects = struct {
            ctx: *Self,

            /// Request one future frame event.
            ///
            /// The runtime coalesces repeated calls while a frame is already
            /// pending. Call this again from the frame update to keep animating.
            pub fn request(self: FrameEffects) void {
                self.ctx.frame_requested = true;
            }
        };

        pub const RedrawEffects = struct {
            ctx: *Self,

            /// Skip the default redraw for the current update cycle.
            ///
            /// By default, `view` is called after every `update`. Call this
            /// method inside `update` when the message does not affect
            /// the visual state and a redraw would be wasteful. This is a
            /// one-shot request; the runtime clears it before the next update.
            pub fn skip(self: RedrawEffects) void {
                self.ctx.redraw_suppressed = true;
            }
        };

        pub const TaskEffects = struct {
            ctx: *Self,

            /// Spawn an async task. The task function will be called
            /// concurrently and its return value delivered as a message to
            /// `update`.
            ///
            /// The task is queued here and started by the runtime after
            /// `update` returns.
            pub fn spawn(self: TaskEffects, opts: SpawnOptions) error{TaskLimitExceeded}!void {
                if (self.ctx.pending_tasks_len + self.ctx.pending_tasks_with_len >= max_tasks) return error.TaskLimitExceeded;
                self.ctx.pending_tasks[self.ctx.pending_tasks_len] = .{
                    .run = opts.run,
                    .failed = opts.failed,
                };
                self.ctx.pending_tasks_len += 1;
            }

            /// Spawn an async task with captured context.
            ///
            /// The caller must ensure `ctx_ptr` remains valid until the task
            /// finishes or is cancelled.
            pub fn spawnWith(
                self: TaskEffects,
                opts: SpawnWithOptions,
            ) error{TaskLimitExceeded}!void {
                if (self.ctx.pending_tasks_len + self.ctx.pending_tasks_with_len >= max_tasks)
                    return error.TaskLimitExceeded;
                self.ctx.pending_tasks_with[self.ctx.pending_tasks_with_len] = .{
                    .ctx = opts.ctx,
                    .run = opts.run,
                    .failed = opts.failed,
                };
                self.ctx.pending_tasks_with_len += 1;
            }
        };

        pub const TimerEffects = struct {
            ctx: *Self,

            /// Schedule a one-shot delayed message.
            ///
            /// The message will be delivered once after `after_ns`
            /// nanoseconds. If a timer with the same `id` is already pending,
            /// it is overwritten.
            ///
            /// The id is copied into runtime-owned memory while queueing, so
            /// callers may pass temporary or dynamically formatted ids.
            pub fn tick(self: TimerEffects, id: []const u8, after_ns: u64, msg: Msg) TimerScheduleError!void {
                for (self.ctx.pending_ticks[0..self.ctx.pending_ticks_len]) |*entry| {
                    if (std.mem.eql(u8, entry.id, id)) {
                        entry.after_ns = after_ns;
                        entry.msg = msg;
                        return;
                    }
                }
                if (self.ctx.pending_ticks_len >= max_ticks) return error.TimerLimitExceeded;
                self.ctx.pending_ticks[self.ctx.pending_ticks_len] = .{
                    .id = try self.ctx._allocator.dupe(u8, id),
                    .after_ns = after_ns,
                    .msg = msg,
                };
                self.ctx.pending_ticks_len += 1;
            }

            /// Schedule a repeating timer.
            ///
            /// The message will be delivered every `interval_ns` nanoseconds
            /// until the future is cancelled. If a timer with the same `id` is
            /// already pending, it is overwritten.
            ///
            /// The id is copied into runtime-owned memory while queueing, so
            /// callers may pass temporary or dynamically formatted ids.
            pub fn every(self: TimerEffects, id: []const u8, interval_ns: u64, msg: Msg) TimerScheduleError!void {
                for (self.ctx.pending_everys[0..self.ctx.pending_everys_len]) |*entry| {
                    if (std.mem.eql(u8, entry.id, id)) {
                        entry.interval_ns = interval_ns;
                        entry.msg = msg;
                        return;
                    }
                }
                if (self.ctx.pending_everys_len >= max_everys) return error.TimerLimitExceeded;
                self.ctx.pending_everys[self.ctx.pending_everys_len] = .{
                    .id = try self.ctx._allocator.dupe(u8, id),
                    .interval_ns = interval_ns,
                    .msg = msg,
                };
                self.ctx.pending_everys_len += 1;
            }

            /// Cancel a timer by id.
            ///
            /// Removes any matching entry from the pending tick/every queues.
            /// Also queues the id for the runtime to cancel running timers.
            ///
            /// The id is copied into runtime-owned memory while queueing. If
            /// the cancel queue is full, an error is returned instead of
            /// silently dropping the request.
            ///
            /// If the same update queues `cancel(id)` and then queues a
            /// `tick(id, ...)` or `every(id, ...)`, the cancel applies to the
            /// previously running timer and the newly queued replacement
            /// remains scheduled.
            pub fn cancel(self: TimerEffects, id: []const u8) TimerCancelError!void {
                try self.ctx.cancelTimerInternal(id);
            }
        };

        pub const ImageEffects = struct {
            ctx: *Self,

            /// Queue a local terminal image path to be loaded by the runtime.
            ///
            /// The path is copied while queueing because effects are drained
            /// after `init`/`update` returns. The runtime frees the copied path
            /// after it posts either `loaded` or `failed`.
            ///
            /// The returned request id is passed back to the callbacks so apps
            /// can ignore stale image loads without owning callback context
            /// pointers. Once a loaded callback receives a handle, the app owns
            /// that handle: if the result is stale or otherwise unused, queue
            /// `unload` for the handle instead of silently dropping it.
            pub fn loadPath(
                self: ImageEffects,
                path: []const u8,
                loaded_fn: TerminalImageLoadedFn,
                failed_fn: TerminalImageFailedFn,
            ) (error{TerminalImageLoadLimitExceeded} || std.mem.Allocator.Error)!terminal_image.TerminalImageRequestId {
                if (self.ctx.pending_terminal_image_loads_len >= max_terminal_image_loads)
                    return error.TerminalImageLoadLimitExceeded;

                const copied_path = try self.ctx._allocator.dupe(u8, path);
                const request_id = terminal_image.TerminalImageRequestId{ .id = self.ctx.next_terminal_image_request_id };
                self.ctx.next_terminal_image_request_id +%= 1;
                self.ctx.pending_terminal_image_loads[self.ctx.pending_terminal_image_loads_len] = .{
                    .request_id = request_id,
                    .path = copied_path,
                    .loaded = loaded_fn,
                    .failed = failed_fn,
                };
                self.ctx.pending_terminal_image_loads_len += 1;
                return request_id;
            }

            /// Queue a terminal image handle for release by the runtime.
            pub fn unload(self: ImageEffects, handle: terminal_image.TerminalImageHandle) error{TerminalImageUnloadLimitExceeded}!void {
                if (self.ctx.pending_terminal_image_unloads_len >= max_terminal_image_unloads)
                    return error.TerminalImageUnloadLimitExceeded;
                self.ctx.pending_terminal_image_unloads[self.ctx.pending_terminal_image_unloads_len] = handle;
                self.ctx.pending_terminal_image_unloads_len += 1;
            }
        };

        pub const TerminalEffects = struct {
            ctx: *Self,

            pub const ForegroundCommandOptions = struct {
                argv: []const []const u8,
                cwd: ?[]const u8 = null,
                finished: ForegroundCommandFinishedFn,
            };

            /// Queue an interactive terminal foreground command.
            ///
            /// The runtime temporarily restores the terminal, runs the child
            /// connected to `/dev/tty`, then re-enters Chasen's terminal mode.
            /// argv and cwd are copied while queueing because effects are
            /// drained after `update` returns.
            ///
            /// A follow-up foreground command queued from `finished` is
            /// processed by bounded drain rounds without waiting for unrelated
            /// input. Commands beyond that guard remain queued for a later
            /// event loop iteration.
            pub fn runForegroundCommand(
                self: TerminalEffects,
                opts: ForegroundCommandOptions,
            ) (error{ ForegroundCommandLimitExceeded, ForegroundCommandEmptyArgv } || std.mem.Allocator.Error)!foreground_command.ForegroundCommandRequestId {
                if (opts.argv.len == 0) return error.ForegroundCommandEmptyArgv;
                if (self.ctx.pending_foreground_commands_len >= max_foreground_commands)
                    return error.ForegroundCommandLimitExceeded;

                var copied_argv = try self.ctx._allocator.alloc([]const u8, opts.argv.len);
                errdefer self.ctx._allocator.free(copied_argv);

                var copied_count: usize = 0;
                errdefer {
                    for (copied_argv[0..copied_count]) |arg| {
                        self.ctx._allocator.free(arg);
                    }
                }

                for (opts.argv, 0..) |arg, i| {
                    copied_argv[i] = try self.ctx._allocator.dupe(u8, arg);
                    copied_count += 1;
                }

                const copied_cwd = if (opts.cwd) |cwd| try self.ctx._allocator.dupe(u8, cwd) else null;
                errdefer if (copied_cwd) |cwd| self.ctx._allocator.free(cwd);

                const request_id = foreground_command.ForegroundCommandRequestId{
                    .id = self.ctx.next_foreground_command_request_id,
                };
                self.ctx.next_foreground_command_request_id +%= 1;
                self.ctx.pending_foreground_commands[self.ctx.pending_foreground_commands_len] = .{
                    .request_id = request_id,
                    .argv = copied_argv,
                    .cwd = copied_cwd,
                    .finished = opts.finished,
                };
                self.ctx.pending_foreground_commands_len += 1;
                return request_id;
            }
        };

        /// Request the application to exit.
        pub fn quit(self: *@This()) void {
            self.should_quit = true;
        }

        pub fn frame(self: *@This()) FrameEffects {
            return .{ .ctx = self };
        }

        pub fn redraw(self: *@This()) RedrawEffects {
            return .{ .ctx = self };
        }

        pub fn task(self: *@This()) TaskEffects {
            return .{ .ctx = self };
        }

        pub fn timer(self: *@This()) TimerEffects {
            return .{ .ctx = self };
        }

        pub fn image(self: *@This()) ImageEffects {
            return .{ .ctx = self };
        }

        pub fn terminal(self: *@This()) TerminalEffects {
            return .{ .ctx = self };
        }

        /// Return a slice of pending tasks.
        pub fn pendingSlice(self: *@This()) []const TaskEntry {
            return self.pending_tasks[0..self.pending_tasks_len];
        }

        /// Return a slice of pending task-with entries.
        pub fn pendingTaskWithSlice(self: *@This()) []const TaskWithEntry {
            return self.pending_tasks_with[0..self.pending_tasks_with_len];
        }

        pub fn pendingTerminalImageLoadSlice(self: *@This()) []const TerminalImageLoadEntry {
            return self.pending_terminal_image_loads[0..self.pending_terminal_image_loads_len];
        }

        pub fn pendingTerminalImageUnloadSlice(self: *@This()) []const terminal_image.TerminalImageHandle {
            return self.pending_terminal_image_unloads[0..self.pending_terminal_image_unloads_len];
        }

        pub fn pendingForegroundCommandSlice(self: *@This()) []const ForegroundCommandEntry {
            return self.pending_foreground_commands[0..self.pending_foreground_commands_len];
        }

        /// Return a slice of pending tick entries.
        pub fn pendingTickSlice(self: *@This()) []const TickEntry {
            return self.pending_ticks[0..self.pending_ticks_len];
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

        fn cancelTimerInternal(self: *@This(), id: []const u8) TimerCancelError!void {
            if (self.pending_cancels_len >= max_cancels) return error.TimerCancelLimitExceeded;
            const copied_id = try self._allocator.dupe(u8, id);
            errdefer self._allocator.free(copied_id);

            // Remove from pending ticks (swap-remove).
            {
                var i: u8 = 0;
                while (i < self.pending_ticks_len) {
                    if (std.mem.eql(u8, self.pending_ticks[i].id, id)) {
                        self._allocator.free(self.pending_ticks[i].id);
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
                        self._allocator.free(self.pending_everys[i].id);
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
            self.pending_cancels[self.pending_cancels_len] = copied_id;
            self.pending_cancels_len += 1;
        }

        /// Return a slice of pending cancel ids.
        pub fn pendingCancelSlice(self: *@This()) []const []const u8 {
            return self.pending_cancels[0..self.pending_cancels_len];
        }

        /// Release copied data for queued effects that have not been handed to
        /// the runtime.
        ///
        /// App callbacks may queue effects and then return an error before the
        /// runtime drains them. This cleanup is for that unwind path; normally
        /// the runtime consumes and frees these copies while draining effects.
        pub fn clearPendingEffectCopies(self: *@This()) void {
            for (self.pending_ticks[0..self.pending_ticks_len]) |entry| {
                self._allocator.free(entry.id);
            }
            self.pending_ticks_len = 0;

            for (self.pending_everys[0..self.pending_everys_len]) |entry| {
                self._allocator.free(entry.id);
            }
            self.pending_everys_len = 0;

            for (self.pending_cancels[0..self.pending_cancels_len]) |id| {
                self._allocator.free(id);
            }
            self.pending_cancels_len = 0;

            for (self.pending_terminal_image_loads[0..self.pending_terminal_image_loads_len]) |entry| {
                self._allocator.free(entry.path);
            }
            self.pending_terminal_image_loads_len = 0;

            self.pending_terminal_image_unloads_len = 0;

            for (self.pending_foreground_commands[0..self.pending_foreground_commands_len]) |entry| {
                for (entry.argv) |arg| {
                    self._allocator.free(arg);
                }
                self._allocator.free(entry.argv);
                if (entry.cwd) |cwd| self._allocator.free(cwd);
            }
            self.pending_foreground_commands_len = 0;
        }
    };
}

test "Ctx spawn accumulates tasks" {
    const TestMsg = union(enum) { hello, failed };
    var ctx_val: Ctx(TestMsg) = .{};

    const task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .hello;
        }
        fn failed(_: TaskFailure) TestMsg {
            return .failed;
        }
    };

    try ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed });
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_tasks_len);

    try ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed });
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_tasks_len);

    const slice = ctx_val.pendingSlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(*const fn (TaskFailure) TestMsg, task.failed), slice[0].failed);
}

test "Ctx frame request marks a pending frame request" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    try std.testing.expectEqual(false, ctx_val.frame_requested);
    ctx_val.frame().request();
    try std.testing.expectEqual(true, ctx_val.frame_requested);
}

test "Ctx spawn returns error when task queue is full" {
    const TestMsg = union(enum) { hello, failed };
    var ctx_val: Ctx(TestMsg) = .{};

    const task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .hello;
        }
        fn failed(_: TaskFailure) TestMsg {
            return .failed;
        }
    };

    for (0..16) |_| try ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed });
    try std.testing.expectError(error.TaskLimitExceeded, ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed }));
}

test "Ctx tick accumulates entries" {
    const TestMsg = union(enum) { timeout, ping };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    try ctx_val.timer().tick("t1", 1_000_000_000, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);

    try ctx_val.timer().tick("t2", 500_000_000, .ping);
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
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    for (0..8) |i| {
        const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
        try ctx_val.timer().tick(ids[i], 1_000_000_000, .timeout);
    }
    try std.testing.expectError(error.TimerLimitExceeded, ctx_val.timer().tick("overflow", 1_000_000_000, .timeout));
}

test "Ctx every accumulates entries" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    try ctx_val.timer().every("e1", 1_000_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    try ctx_val.timer().every("e2", 500_000_000, .heartbeat);
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
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    for (0..8) |i| {
        const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
        try ctx_val.timer().every(ids[i], 1_000_000_000, .tick_msg);
    }
    try std.testing.expectError(error.TimerLimitExceeded, ctx_val.timer().every("overflow", 1_000_000_000, .tick_msg));
}

test "Ctx tick same id overwrites existing entry" {
    const TestMsg = union(enum) { timeout, ping };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    try ctx_val.timer().tick("timer1", 1_000_000_000, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);

    // Same id should overwrite, not grow the queue.
    try ctx_val.timer().tick("timer1", 2_000_000_000, .ping);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);

    const slice = ctx_val.pendingTickSlice();
    try std.testing.expectEqual(@as(u64, 2_000_000_000), slice[0].after_ns);
    try std.testing.expect(slice[0].msg == .ping);
}

test "Ctx every same id overwrites existing entry" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    try ctx_val.timer().every("refresh", 1_000_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    // Same id should overwrite.
    try ctx_val.timer().every("refresh", 500_000_000, .heartbeat);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    const slice = ctx_val.pendingEverySlice();
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[0].interval_ns);
    try std.testing.expect(slice[0].msg == .heartbeat);
}

test "Ctx timer cancel removes from pending queues" {
    const TestMsg = union(enum) { timeout, tick_msg };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    try ctx_val.timer().tick("t1", 1_000_000_000, .timeout);
    try ctx_val.timer().every("e1", 500_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    try ctx_val.timer().cancel("t1");
    try std.testing.expectEqual(@as(u8, 0), ctx_val.pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    try ctx_val.timer().cancel("e1");
    try std.testing.expectEqual(@as(u8, 0), ctx_val.pending_everys_len);
}

test "Ctx timer cancel queues id for runtime cancellation" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    try ctx_val.timer().cancel("running_timer");
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_cancels_len);

    const cancels = ctx_val.pendingCancelSlice();
    try std.testing.expectEqual(@as(usize, 1), cancels.len);
    try std.testing.expectEqualStrings("running_timer", cancels[0]);
}

test "Ctx timer cancel then tick queues cancel and replacement" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    try ctx_val.timer().cancel("restart");
    try ctx_val.timer().tick("restart", 1_000_000_000, .timeout);

    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_cancels_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);

    try std.testing.expectEqualStrings("restart", ctx_val.pendingCancelSlice()[0]);
    try std.testing.expectEqualStrings("restart", ctx_val.pendingTickSlice()[0].id);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), ctx_val.pendingTickSlice()[0].after_ns);
}

test "Ctx timer cancel leaves pending timers unchanged when cancel queue is full" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    const cancel_ids = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7" };
    for (cancel_ids) |id| try ctx_val.timer().cancel(id);
    try ctx_val.timer().tick("pending", 1_000_000_000, .timeout);

    try std.testing.expectError(error.TimerCancelLimitExceeded, ctx_val.timer().cancel("pending"));
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);
    try std.testing.expectEqualStrings("pending", ctx_val.pendingTickSlice()[0].id);
}

test "Ctx spawnWith accumulates tasks" {
    const TestMsg = union(enum) { done, failed };
    var ctx_val: Ctx(TestMsg) = .{};

    var dummy_ctx: u32 = 42;
    const task = struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: std.Io) TestMsg {
            return .done;
        }
        fn failed(_: *anyopaque, _: TaskFailure, _: std.mem.Allocator) TestMsg {
            return .failed;
        }
    };

    try ctx_val.task().spawnWith(.{ .ctx = @ptrCast(&dummy_ctx), .run = task.run, .failed = task.failed });
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_tasks_with_len);

    try ctx_val.task().spawnWith(.{ .ctx = @ptrCast(&dummy_ctx), .run = task.run, .failed = task.failed });
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_tasks_with_len);

    const slice = ctx_val.pendingTaskWithSlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&dummy_ctx)), slice[0].ctx);
}

test "Ctx image loadPath copies queued path" {
    const TestMsg = union(enum) { loaded, failed };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    var path_buf = [_]u8{ 'a', '.', 'p', 'n', 'g' };
    const request_id = try ctx_val.image().loadPath(&path_buf, &struct {
        fn loaded(_: terminal_image.TerminalImageRequestId, _: terminal_image.TerminalImageHandle) TestMsg {
            return .loaded;
        }
    }.loaded, &struct {
        fn failed(_: terminal_image.TerminalImageRequestId, _: terminal_image.LoadError) TestMsg {
            return .failed;
        }
    }.failed);
    path_buf[0] = 'b';

    const pending = ctx_val.pendingTerminalImageLoadSlice();
    try std.testing.expectEqual(@as(u64, 1), request_id.id);
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(request_id, pending[0].request_id);
    try std.testing.expectEqualStrings("a.png", pending[0].path);
}

test "Ctx image unload queues handles" {
    const TestMsg = union(enum) { done };
    var ctx_val: Ctx(TestMsg) = .{};

    const handle = terminal_image.TerminalImageHandle{ .id = 7, .generation = 2 };
    try ctx_val.image().unload(handle);

    const pending = ctx_val.pendingTerminalImageUnloadSlice();
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(handle, pending[0]);
}

test "Ctx image unload returns error when queue is full" {
    const TestMsg = union(enum) { done };
    var ctx_val: Ctx(TestMsg) = .{};

    const handle = terminal_image.TerminalImageHandle{ .id = 7, .generation = 2 };
    for (0..8) |_| try ctx_val.image().unload(handle);

    try std.testing.expectError(error.TerminalImageUnloadLimitExceeded, ctx_val.image().unload(handle));
}

test "Ctx terminal foreground command copies argv and cwd" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    const finished = &struct {
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }
    }.done;

    var arg0 = [_]u8{ 'e', 'd' };
    var arg1 = [_]u8{ 'f', 'i', 'l', 'e' };
    var cwd = [_]u8{ '/', 't', 'm', 'p' };
    const request_id = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{ arg0[0..], arg1[0..] },
        .cwd = cwd[0..],
        .finished = finished,
    });

    try std.testing.expectEqual(@as(u64, 1), request_id.id);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_foreground_commands_len);

    arg0[0] = 'X';
    arg1[0] = 'Y';
    cwd[1] = 'z';

    const entry = ctx_val.pendingForegroundCommandSlice()[0];
    try std.testing.expectEqual(@as(u64, 1), entry.request_id.id);
    try std.testing.expectEqualStrings("ed", entry.argv[0]);
    try std.testing.expectEqualStrings("file", entry.argv[1]);
    try std.testing.expectEqualStrings("/tmp", entry.cwd.?);
}

test "Ctx terminal foreground command rejects empty argv and overflow" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.clearPendingEffectCopies();

    const finished = &struct {
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }
    }.done;

    try std.testing.expectError(error.ForegroundCommandEmptyArgv, ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{},
        .finished = finished,
    }));

    _ = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"true"},
        .finished = finished,
    });
    try std.testing.expectError(error.ForegroundCommandLimitExceeded, ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"false"},
        .finished = finished,
    }));
}

test "Ctx redraw_suppressed defaults to false" {
    const TestMsg = union(enum) { hello };
    const ctx_val: Ctx(TestMsg) = .{};

    try std.testing.expectEqual(false, ctx_val.redraw_suppressed);
}

test "Ctx redraw skip sets redraw_suppressed to true" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    ctx_val.redraw().skip();
    try std.testing.expectEqual(true, ctx_val.redraw_suppressed);
}

test "Ctx spawn and spawnWith share task limit" {
    const TestMsg = union(enum) { hello, done, failed };
    var ctx_val: Ctx(TestMsg) = .{};

    const task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .hello;
        }
        fn failed(_: TaskFailure) TestMsg {
            return .failed;
        }
    };

    var dummy_ctx: u32 = 0;
    const task_with = struct {
        fn run(_: *anyopaque, _: std.mem.Allocator, _: std.Io) TestMsg {
            return .done;
        }
        fn failed(_: *anyopaque, _: TaskFailure, _: std.mem.Allocator) TestMsg {
            return .failed;
        }
    };

    // Fill 10 with spawn, 6 with spawnWith = 16 total (max_tasks)
    for (0..10) |_| try ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed });
    for (0..6) |_| try ctx_val.task().spawnWith(.{ .ctx = @ptrCast(&dummy_ctx), .run = task_with.run, .failed = task_with.failed });

    // Both should fail now
    try std.testing.expectError(error.TaskLimitExceeded, ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed }));
    try std.testing.expectError(error.TaskLimitExceeded, ctx_val.task().spawnWith(.{ .ctx = @ptrCast(&dummy_ctx), .run = task_with.run, .failed = task_with.failed }));
}
