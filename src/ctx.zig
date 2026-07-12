const std = @import("std");
const terminal_image = @import("terminal_image_types.zig");
const foreground_command = @import("foreground_command.zig");
const clipboard_types = @import("clipboard.zig");
const runtime_limits = @import("runtime_limits.zig");

pub const TaskFailure = union(enum) {
    start_failed: []const u8,
    /// The app queued the task, but runtime error unwind happened before the
    /// task was transferred to a future. The existing failure callback still
    /// consumes captured `spawnWith` context; its returned message is disposed
    /// as undelivered instead of being posted.
    runtime_abandoned,
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
    const max_tasks = runtime_limits.max_tasks;
    const max_ticks = 8;
    const max_everys = 8;
    const max_terminal_image_loads = runtime_limits.max_terminal_image_loads;
    const max_terminal_image_unloads = 8;
    const max_foreground_commands = 1;
    const max_clipboard_copies = 4;

    const max_cancels = 8;

    return struct {
        const Self = @This();
        const TimerScheduleError = error{TimerLimitExceeded} || std.mem.Allocator.Error;
        const TimerCancelError = error{TimerCancelLimitExceeded} || std.mem.Allocator.Error;

        pub const TerminalImageLoadedFn = *const fn (terminal_image.TerminalImageRequestId, terminal_image.TerminalImageHandle) Msg;
        pub const TerminalImageFailedFn = *const fn (terminal_image.TerminalImageRequestId, terminal_image.LoadError) Msg;
        pub const ForegroundCommandFinishedFn = *const fn (foreground_command.ForegroundCommandResult) Msg;
        pub const ClipboardCopyFinishedFn = *const fn (clipboard_types.ClipboardCopyResult) Msg;

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

        pub const ClipboardCopyOutcome = clipboard_types.ClipboardCopyOutcome;
        pub const ClipboardCopyResult = clipboard_types.ClipboardCopyResult;
        pub const ClipboardCopyRequestId = clipboard_types.ClipboardCopyRequestId;

        pub const ClipboardCopyEntry = struct {
            request_id: clipboard_types.ClipboardCopyRequestId,
            text: []const u8,
            finished: ClipboardCopyFinishedFn,
        };

        // Private runtime handles. Set by Program before passing to app code.
        _io: std.Io = undefined,
        _allocator: std.mem.Allocator = undefined,
        _should_quit: bool = false,
        _pending_tasks: [max_tasks]TaskEntry = undefined,
        _pending_tasks_len: u8 = 0,
        _pending_tasks_with: [max_tasks]TaskWithEntry = undefined,
        _pending_tasks_with_len: u8 = 0,
        _pending_ticks: [max_ticks]TickEntry = undefined,
        _pending_ticks_len: u8 = 0,
        _pending_everys: [max_everys]EveryEntry = undefined,
        _pending_everys_len: u8 = 0,
        _pending_cancels: [max_cancels][]const u8 = undefined,
        _pending_cancels_len: u8 = 0,
        _pending_terminal_image_loads: [max_terminal_image_loads]TerminalImageLoadEntry = undefined,
        _pending_terminal_image_loads_len: u8 = 0,
        _next_terminal_image_request_id: u64 = 1,
        _pending_terminal_image_unloads: [max_terminal_image_unloads]terminal_image.TerminalImageHandle = undefined,
        _pending_terminal_image_unloads_len: u8 = 0,
        _pending_foreground_commands: [max_foreground_commands]ForegroundCommandEntry = undefined,
        _pending_foreground_commands_len: u8 = 0,
        _next_foreground_command_request_id: u64 = 1,
        _pending_clipboard_copies: [max_clipboard_copies]ClipboardCopyEntry = undefined,
        _pending_clipboard_copies_len: u8 = 0,
        _next_clipboard_copy_request_id: u64 = 1,
        _redraw_suppressed: bool = false,
        _frame_requested: bool = false,

        pub const FrameEffects = struct {
            ctx: *Self,

            /// Request one future frame event.
            ///
            /// The runtime coalesces repeated calls while a frame is already
            /// pending. Call this again from the frame update to keep animating.
            pub fn request(self: FrameEffects) void {
                self.ctx._frame_requested = true;
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
                self.ctx._redraw_suppressed = true;
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
            /// Started task futures are awaited during terminal shutdown and
            /// should eventually return.
            pub fn spawn(self: TaskEffects, opts: SpawnOptions) error{TaskLimitExceeded}!void {
                if (self.ctx._pending_tasks_len + self.ctx._pending_tasks_with_len >= max_tasks) return error.TaskLimitExceeded;
                self.ctx._pending_tasks[self.ctx._pending_tasks_len] = .{
                    .run = opts.run,
                    .failed = opts.failed,
                };
                self.ctx._pending_tasks_len += 1;
            }

            /// Spawn an async task with captured context.
            ///
            /// The caller must ensure `opts.ctx` remains valid until the task
            /// returns. Started task futures are awaited during terminal
            /// shutdown and should eventually return.
            pub fn spawnWith(
                self: TaskEffects,
                opts: SpawnWithOptions,
            ) error{TaskLimitExceeded}!void {
                if (self.ctx._pending_tasks_len + self.ctx._pending_tasks_with_len >= max_tasks)
                    return error.TaskLimitExceeded;
                self.ctx._pending_tasks_with[self.ctx._pending_tasks_with_len] = .{
                    .ctx = opts.ctx,
                    .run = opts.run,
                    .failed = opts.failed,
                };
                self.ctx._pending_tasks_with_len += 1;
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
            ///
            /// If the runtime cannot start or track the timer helper, this
            /// API currently has no failure callback and the timer message may
            /// never be delivered.
            ///
            /// The runtime may copy this template and drop pending copies
            /// during replacement or shutdown without calling
            /// `Msg.deinitUndelivered`. Use only a non-owning/copy-safe message
            /// variant; heap-owning results belong in task callbacks.
            pub fn tick(self: TimerEffects, id: []const u8, after_ns: u64, msg: Msg) TimerScheduleError!void {
                for (self.ctx._pending_ticks[0..self.ctx._pending_ticks_len]) |*entry| {
                    if (std.mem.eql(u8, entry.id, id)) {
                        entry.after_ns = after_ns;
                        entry.msg = msg;
                        return;
                    }
                }
                if (self.ctx._pending_ticks_len >= max_ticks) return error.TimerLimitExceeded;
                self.ctx._pending_ticks[self.ctx._pending_ticks_len] = .{
                    .id = try self.ctx._allocator.dupe(u8, id),
                    .after_ns = after_ns,
                    .msg = msg,
                };
                self.ctx._pending_ticks_len += 1;
            }

            /// Schedule a repeating timer.
            ///
            /// The message will be delivered every `interval_ns` nanoseconds
            /// until the future is cancelled. If a timer with the same `id` is
            /// already pending, it is overwritten.
            ///
            /// The id is copied into runtime-owned memory while queueing, so
            /// callers may pass temporary or dynamically formatted ids.
            ///
            /// If the runtime cannot start or track the timer helper, this
            /// API currently has no failure callback and the timer message may
            /// never be delivered.
            ///
            /// The runtime reuses this template for every firing and may drop
            /// it without calling `Msg.deinitUndelivered`. Use only a
            /// non-owning/copy-safe message variant.
            pub fn every(self: TimerEffects, id: []const u8, interval_ns: u64, msg: Msg) TimerScheduleError!void {
                for (self.ctx._pending_everys[0..self.ctx._pending_everys_len]) |*entry| {
                    if (std.mem.eql(u8, entry.id, id)) {
                        entry.interval_ns = interval_ns;
                        entry.msg = msg;
                        return;
                    }
                }
                if (self.ctx._pending_everys_len >= max_everys) return error.TimerLimitExceeded;
                self.ctx._pending_everys[self.ctx._pending_everys_len] = .{
                    .id = try self.ctx._allocator.dupe(u8, id),
                    .interval_ns = interval_ns,
                    .msg = msg,
                };
                self.ctx._pending_everys_len += 1;
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
                if (self.ctx._pending_terminal_image_loads_len >= max_terminal_image_loads)
                    return error.TerminalImageLoadLimitExceeded;

                const copied_path = try self.ctx._allocator.dupe(u8, path);
                const request_id = terminal_image.TerminalImageRequestId{ .id = self.ctx._next_terminal_image_request_id };
                self.ctx._next_terminal_image_request_id +%= 1;
                self.ctx._pending_terminal_image_loads[self.ctx._pending_terminal_image_loads_len] = .{
                    .request_id = request_id,
                    .path = copied_path,
                    .loaded = loaded_fn,
                    .failed = failed_fn,
                };
                self.ctx._pending_terminal_image_loads_len += 1;
                return request_id;
            }

            /// Queue a terminal image handle for release by the runtime.
            pub fn unload(self: ImageEffects, handle: terminal_image.TerminalImageHandle) error{TerminalImageUnloadLimitExceeded}!void {
                if (self.ctx._pending_terminal_image_unloads_len >= max_terminal_image_unloads)
                    return error.TerminalImageUnloadLimitExceeded;
                self.ctx._pending_terminal_image_unloads[self.ctx._pending_terminal_image_unloads_len] = handle;
                self.ctx._pending_terminal_image_unloads_len += 1;
            }
        };

        pub const TerminalEffects = struct {
            ctx: *Self,

            pub const ForegroundCommandOptions = struct {
                argv: []const []const u8,
                cwd: ?[]const u8 = null,
                finished: ForegroundCommandFinishedFn,
            };

            pub const ClipboardCopyOptions = struct {
                text: []const u8,
                finished: ClipboardCopyFinishedFn,
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
                if (self.ctx._pending_foreground_commands_len >= max_foreground_commands)
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
                    .id = self.ctx._next_foreground_command_request_id,
                };
                self.ctx._next_foreground_command_request_id +%= 1;
                self.ctx._pending_foreground_commands[self.ctx._pending_foreground_commands_len] = .{
                    .request_id = request_id,
                    .argv = copied_argv,
                    .cwd = copied_cwd,
                    .finished = opts.finished,
                };
                self.ctx._pending_foreground_commands_len += 1;
                return request_id;
            }

            /// Queue a best-effort OSC 52 clipboard write.
            ///
            /// `text` is copied while queueing because effects are drained
            /// after `update` returns. The `finished` callback reports whether
            /// the runtime emitted the sequence or hit a detectable local
            /// failure; terminal-side clipboard acceptance cannot be proven.
            /// The returned request id is repeated in `ClipboardCopyResult` so
            /// apps can route presentation through metadata captured when the
            /// copy was queued instead of reconstructing origin in a callback.
            ///
            /// If multiple copies are emitted in one drain, terminals normally
            /// keep the last payload.
            pub fn copyToClipboard(
                self: TerminalEffects,
                opts: ClipboardCopyOptions,
            ) (error{ClipboardCopyLimitExceeded} || std.mem.Allocator.Error)!clipboard_types.ClipboardCopyRequestId {
                if (self.ctx._pending_clipboard_copies_len >= max_clipboard_copies)
                    return error.ClipboardCopyLimitExceeded;

                const copied_text = try self.ctx._allocator.dupe(u8, opts.text);
                errdefer self.ctx._allocator.free(copied_text);

                const request_id: clipboard_types.ClipboardCopyRequestId = .{
                    .id = self.ctx._next_clipboard_copy_request_id,
                };
                self.ctx._next_clipboard_copy_request_id +%= 1;
                self.ctx._pending_clipboard_copies[self.ctx._pending_clipboard_copies_len] = .{
                    .request_id = request_id,
                    .text = copied_text,
                    .finished = opts.finished,
                };
                self.ctx._pending_clipboard_copies_len += 1;
                return request_id;
            }
        };

        /// Request the application to exit.
        pub fn quit(self: *@This()) void {
            self._should_quit = true;
        }

        /// Return whether the application has requested runtime exit.
        pub fn shouldQuit(self: *const @This()) bool {
            return self._should_quit;
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

        pub fn resetRedrawSuppressed(self: *@This()) void {
            self._redraw_suppressed = false;
        }

        pub fn redrawWasSuppressed(self: *const @This()) bool {
            return self._redraw_suppressed;
        }

        pub fn takeFrameRequest(self: *@This()) bool {
            const requested = self._frame_requested;
            self._frame_requested = false;
            return requested;
        }

        pub fn hasPendingForegroundCommands(self: *const @This()) bool {
            return self._pending_foreground_commands_len > 0;
        }

        pub fn hasPendingClipboardCopies(self: *const @This()) bool {
            return self._pending_clipboard_copies_len > 0;
        }

        pub fn takePendingTasks(self: *@This()) []const TaskEntry {
            const pending = self._pending_tasks[0..self._pending_tasks_len];
            self._pending_tasks_len = 0;
            return pending;
        }

        pub fn takePendingTasksWith(self: *@This()) []const TaskWithEntry {
            const pending = self._pending_tasks_with[0..self._pending_tasks_with_len];
            self._pending_tasks_with_len = 0;
            return pending;
        }

        pub fn takePendingTicks(self: *@This()) []const TickEntry {
            const pending = self._pending_ticks[0..self._pending_ticks_len];
            self._pending_ticks_len = 0;
            return pending;
        }

        pub fn takePendingEverys(self: *@This()) []const EveryEntry {
            const pending = self._pending_everys[0..self._pending_everys_len];
            self._pending_everys_len = 0;
            return pending;
        }

        pub fn takePendingCancels(self: *@This()) []const []const u8 {
            const pending = self._pending_cancels[0..self._pending_cancels_len];
            self._pending_cancels_len = 0;
            return pending;
        }

        pub fn takePendingTerminalImageLoads(self: *@This()) []const TerminalImageLoadEntry {
            const pending = self._pending_terminal_image_loads[0..self._pending_terminal_image_loads_len];
            self._pending_terminal_image_loads_len = 0;
            return pending;
        }

        pub fn takePendingTerminalImageUnloads(self: *@This()) []const terminal_image.TerminalImageHandle {
            const pending = self._pending_terminal_image_unloads[0..self._pending_terminal_image_unloads_len];
            self._pending_terminal_image_unloads_len = 0;
            return pending;
        }

        pub fn takePendingForegroundCommands(self: *@This()) []const ForegroundCommandEntry {
            comptime std.debug.assert(max_foreground_commands == 1);
            const pending = self._pending_foreground_commands[0..self._pending_foreground_commands_len];
            self._pending_foreground_commands_len = 0;
            return pending;
        }

        pub fn takePendingClipboardCopies(self: *@This()) []const ClipboardCopyEntry {
            const pending = self._pending_clipboard_copies[0..self._pending_clipboard_copies_len];
            self._pending_clipboard_copies_len = 0;
            return pending;
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

        fn cancelTimerInternal(self: *@This(), id: []const u8) TimerCancelError!void {
            if (self._pending_cancels_len >= max_cancels) return error.TimerCancelLimitExceeded;
            const copied_id = try self._allocator.dupe(u8, id);
            errdefer self._allocator.free(copied_id);

            // Remove from pending ticks (swap-remove).
            {
                var i: u8 = 0;
                while (i < self._pending_ticks_len) {
                    if (std.mem.eql(u8, self._pending_ticks[i].id, id)) {
                        self._allocator.free(self._pending_ticks[i].id);
                        self._pending_ticks_len -= 1;
                        if (i < self._pending_ticks_len) {
                            self._pending_ticks[i] = self._pending_ticks[self._pending_ticks_len];
                        }
                    } else {
                        i += 1;
                    }
                }
            }
            // Remove from pending everys (swap-remove).
            {
                var i: u8 = 0;
                while (i < self._pending_everys_len) {
                    if (std.mem.eql(u8, self._pending_everys[i].id, id)) {
                        self._allocator.free(self._pending_everys[i].id);
                        self._pending_everys_len -= 1;
                        if (i < self._pending_everys_len) {
                            self._pending_everys[i] = self._pending_everys[self._pending_everys_len];
                        }
                    } else {
                        i += 1;
                    }
                }
            }
            // Queue for runtime to cancel running timers.
            self._pending_cancels[self._pending_cancels_len] = copied_id;
            self._pending_cancels_len += 1;
        }

        /// Release copied data for queued effects that have not been handed to
        /// the runtime.
        ///
        /// App callbacks may queue effects and then return an error before the
        /// runtime drains them. This cleanup is for that unwind path; normally
        /// the runtime consumes and frees these copies while draining effects.
        pub fn runtimeClearPendingEffectCopies(self: *@This()) void {
            for (self._pending_ticks[0..self._pending_ticks_len]) |entry| {
                self._allocator.free(entry.id);
            }
            self._pending_ticks_len = 0;

            for (self._pending_everys[0..self._pending_everys_len]) |entry| {
                self._allocator.free(entry.id);
            }
            self._pending_everys_len = 0;

            for (self._pending_cancels[0..self._pending_cancels_len]) |id| {
                self._allocator.free(id);
            }
            self._pending_cancels_len = 0;

            for (self._pending_terminal_image_loads[0..self._pending_terminal_image_loads_len]) |entry| {
                self._allocator.free(entry.path);
            }
            self._pending_terminal_image_loads_len = 0;

            self._pending_terminal_image_unloads_len = 0;

            for (self._pending_foreground_commands[0..self._pending_foreground_commands_len]) |entry| {
                for (entry.argv) |arg| {
                    self._allocator.free(arg);
                }
                self._allocator.free(entry.argv);
                if (entry.cwd) |cwd| self._allocator.free(cwd);
            }
            self._pending_foreground_commands_len = 0;

            for (self._pending_clipboard_copies[0..self._pending_clipboard_copies_len]) |entry| {
                self._allocator.free(entry.text);
            }
            self._pending_clipboard_copies_len = 0;
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
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_tasks_len);

    try ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed });
    try std.testing.expectEqual(@as(u8, 2), ctx_val._pending_tasks_len);

    const slice = ctx_val._pending_tasks[0..ctx_val._pending_tasks_len];
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(*const fn (TaskFailure) TestMsg, task.failed), slice[0].failed);
}

test "Ctx frame request marks a pending frame request" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    try std.testing.expectEqual(false, ctx_val._frame_requested);
    ctx_val.frame().request();
    try std.testing.expectEqual(true, ctx_val._frame_requested);
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
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().tick("t1", 1_000_000_000, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);

    try ctx_val.timer().tick("t2", 500_000_000, .ping);
    try std.testing.expectEqual(@as(u8, 2), ctx_val._pending_ticks_len);

    const slice = ctx_val._pending_ticks[0..ctx_val._pending_ticks_len];
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), slice[0].after_ns);
    try std.testing.expect(slice[0].msg == .timeout);
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[1].after_ns);
    try std.testing.expect(slice[1].msg == .ping);
}

test "Ctx tick returns error when timer queue is full" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    for (0..8) |i| {
        const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
        try ctx_val.timer().tick(ids[i], 1_000_000_000, .timeout);
    }
    try std.testing.expectError(error.TimerLimitExceeded, ctx_val.timer().tick("overflow", 1_000_000_000, .timeout));
}

test "Ctx every accumulates entries" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().every("e1", 1_000_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_everys_len);

    try ctx_val.timer().every("e2", 500_000_000, .heartbeat);
    try std.testing.expectEqual(@as(u8, 2), ctx_val._pending_everys_len);

    const slice = ctx_val._pending_everys[0..ctx_val._pending_everys_len];
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), slice[0].interval_ns);
    try std.testing.expect(slice[0].msg == .tick_msg);
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[1].interval_ns);
    try std.testing.expect(slice[1].msg == .heartbeat);
}

test "Ctx every returns error when timer queue is full" {
    const TestMsg = union(enum) { tick_msg };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    for (0..8) |i| {
        const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
        try ctx_val.timer().every(ids[i], 1_000_000_000, .tick_msg);
    }
    try std.testing.expectError(error.TimerLimitExceeded, ctx_val.timer().every("overflow", 1_000_000_000, .tick_msg));
}

test "Ctx tick same id overwrites existing entry" {
    const TestMsg = union(enum) { timeout, ping };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().tick("timer1", 1_000_000_000, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);

    // Same id should overwrite, not grow the queue.
    try ctx_val.timer().tick("timer1", 2_000_000_000, .ping);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);

    const slice = ctx_val._pending_ticks[0..ctx_val._pending_ticks_len];
    try std.testing.expectEqual(@as(u64, 2_000_000_000), slice[0].after_ns);
    try std.testing.expect(slice[0].msg == .ping);
}

test "Ctx every same id overwrites existing entry" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().every("refresh", 1_000_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_everys_len);

    // Same id should overwrite.
    try ctx_val.timer().every("refresh", 500_000_000, .heartbeat);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_everys_len);

    const slice = ctx_val._pending_everys[0..ctx_val._pending_everys_len];
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[0].interval_ns);
    try std.testing.expect(slice[0].msg == .heartbeat);
}

test "Ctx timer cancel removes from pending queues" {
    const TestMsg = union(enum) { timeout, tick_msg };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().tick("t1", 1_000_000_000, .timeout);
    try ctx_val.timer().every("e1", 500_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_everys_len);

    try ctx_val.timer().cancel("t1");
    try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_everys_len);

    try ctx_val.timer().cancel("e1");
    try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_everys_len);
}

test "Ctx timer cancel queues id for runtime cancellation" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().cancel("running_timer");
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_cancels_len);

    const cancels = ctx_val._pending_cancels[0..ctx_val._pending_cancels_len];
    try std.testing.expectEqual(@as(usize, 1), cancels.len);
    try std.testing.expectEqualStrings("running_timer", cancels[0]);
}

test "Ctx timer cancel then tick queues cancel and replacement" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().cancel("restart");
    try ctx_val.timer().tick("restart", 1_000_000_000, .timeout);

    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_cancels_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);

    try std.testing.expectEqualStrings("restart", ctx_val._pending_cancels[0..ctx_val._pending_cancels_len][0]);
    try std.testing.expectEqualStrings("restart", ctx_val._pending_ticks[0..ctx_val._pending_ticks_len][0].id);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), ctx_val._pending_ticks[0..ctx_val._pending_ticks_len][0].after_ns);
}

test "Ctx timer cancel leaves pending timers unchanged when cancel queue is full" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    const cancel_ids = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7" };
    for (cancel_ids) |id| try ctx_val.timer().cancel(id);
    try ctx_val.timer().tick("pending", 1_000_000_000, .timeout);

    try std.testing.expectError(error.TimerCancelLimitExceeded, ctx_val.timer().cancel("pending"));
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);
    try std.testing.expectEqualStrings("pending", ctx_val._pending_ticks[0..ctx_val._pending_ticks_len][0].id);
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
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_tasks_with_len);

    try ctx_val.task().spawnWith(.{ .ctx = @ptrCast(&dummy_ctx), .run = task.run, .failed = task.failed });
    try std.testing.expectEqual(@as(u8, 2), ctx_val._pending_tasks_with_len);

    const slice = ctx_val._pending_tasks_with[0..ctx_val._pending_tasks_with_len];
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&dummy_ctx)), slice[0].ctx);
}

test "Ctx image loadPath copies queued path" {
    const TestMsg = union(enum) { loaded, failed };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

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

    const pending = ctx_val._pending_terminal_image_loads[0..ctx_val._pending_terminal_image_loads_len];
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

    const pending = ctx_val._pending_terminal_image_unloads[0..ctx_val._pending_terminal_image_unloads_len];
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
    defer ctx_val.runtimeClearPendingEffectCopies();

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
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_foreground_commands_len);

    arg0[0] = 'X';
    arg1[0] = 'Y';
    cwd[1] = 'z';

    const entry = ctx_val._pending_foreground_commands[0..ctx_val._pending_foreground_commands_len][0];
    try std.testing.expectEqual(@as(u64, 1), entry.request_id.id);
    try std.testing.expectEqualStrings("ed", entry.argv[0]);
    try std.testing.expectEqualStrings("file", entry.argv[1]);
    try std.testing.expectEqualStrings("/tmp", entry.cwd.?);
}

test "Ctx terminal foreground command rejects empty argv and overflow" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

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

test "Ctx terminal clipboard copy queues owned text" {
    const TestMsg = union(enum) { finished: u64 };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    const finished = &struct {
        fn done(result: Ctx(TestMsg).ClipboardCopyResult) TestMsg {
            return .{ .finished = result.request_id.id };
        }
    }.done;

    var text = [_]u8{ 'c', 'l', 'i', 'p' };
    const request_id = try ctx_val.terminal().copyToClipboard(.{
        .text = text[0..],
        .finished = finished,
    });

    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_clipboard_copies_len);
    text[0] = 'X';

    const entry = ctx_val._pending_clipboard_copies[0..ctx_val._pending_clipboard_copies_len][0];
    try std.testing.expectEqual(request_id.id, entry.request_id.id);
    try std.testing.expectEqualStrings("clip", entry.text);
    try std.testing.expectEqual(@as(Ctx(TestMsg).ClipboardCopyFinishedFn, finished), entry.finished);
    const completion = entry.finished(.{ .request_id = entry.request_id, .outcome = .sent });
    try std.testing.expectEqual(request_id.id, completion.finished);
}

test "Ctx terminal clipboard copy rejects overflow" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    const finished = &struct {
        fn done(_: Ctx(TestMsg).ClipboardCopyResult) TestMsg {
            return .finished;
        }
    }.done;

    for (0..4) |_| {
        _ = try ctx_val.terminal().copyToClipboard(.{
            .text = "clip",
            .finished = finished,
        });
    }
    try std.testing.expectError(error.ClipboardCopyLimitExceeded, ctx_val.terminal().copyToClipboard(.{
        .text = "overflow",
        .finished = finished,
    }));
}

test "Ctx _redraw_suppressed defaults to false" {
    const TestMsg = union(enum) { hello };
    const ctx_val: Ctx(TestMsg) = .{};

    try std.testing.expectEqual(false, ctx_val._redraw_suppressed);
}

test "Ctx redraw skip sets _redraw_suppressed to true" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Ctx(TestMsg) = .{};

    ctx_val.redraw().skip();
    try std.testing.expectEqual(true, ctx_val._redraw_suppressed);
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

test "Ctx take pending queues returns empty slices initially" {
    const TestMsg = union(enum) { done };
    var ctx_val: Ctx(TestMsg) = .{};

    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingTasks().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingTasksWith().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingTicks().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingEverys().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingCancels().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingTerminalImageLoads().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingTerminalImageUnloads().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingForegroundCommands().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.takePendingClipboardCopies().len);
}

test "Ctx take pending ticks clears queue and allows requeue" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().tick("first", 1, .timeout);
    const taken = ctx_val.takePendingTicks();

    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings("first", taken[0].id);
    try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_ticks_len);
    std.testing.allocator.free(taken[0].id);

    ctx_val.runtimeClearPendingEffectCopies();
    try ctx_val.timer().tick("second", 2, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);
    try std.testing.expectEqualStrings("second", ctx_val._pending_ticks[0].id);
}

test "Ctx taken effect copies are not cleared by runtime cleanup" {
    const TestMsg = union(enum) { timeout, loaded, failed, finished };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try ctx_val.timer().tick("taken-tick", 1, .timeout);
    _ = try ctx_val.image().loadPath("image.png", &struct {
        fn loaded(_: terminal_image.TerminalImageRequestId, _: terminal_image.TerminalImageHandle) TestMsg {
            return .loaded;
        }
    }.loaded, &struct {
        fn failed(_: terminal_image.TerminalImageRequestId, _: terminal_image.LoadError) TestMsg {
            return .failed;
        }
    }.failed);
    _ = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"true"},
        .cwd = "/tmp",
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });
    _ = try ctx_val.terminal().copyToClipboard(.{
        .text = "clipboard",
        .finished = &struct {
            fn done(_: Ctx(TestMsg).ClipboardCopyResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    const ticks = ctx_val.takePendingTicks();
    const loads = ctx_val.takePendingTerminalImageLoads();
    const foreground = ctx_val.takePendingForegroundCommands();
    const clipboard = ctx_val.takePendingClipboardCopies();

    ctx_val.runtimeClearPendingEffectCopies();

    try std.testing.expectEqualStrings("taken-tick", ticks[0].id);
    try std.testing.expectEqualStrings("image.png", loads[0].path);
    try std.testing.expectEqualStrings("true", foreground[0].argv[0]);
    try std.testing.expectEqualStrings("/tmp", foreground[0].cwd.?);
    try std.testing.expectEqualStrings("clipboard", clipboard[0].text);

    for (ticks) |entry| std.testing.allocator.free(entry.id);
    for (loads) |entry| std.testing.allocator.free(entry.path);
    for (foreground) |entry| {
        for (entry.argv) |arg| std.testing.allocator.free(arg);
        std.testing.allocator.free(entry.argv);
        if (entry.cwd) |cwd| std.testing.allocator.free(cwd);
    }
    for (clipboard) |entry| std.testing.allocator.free(entry.text);
}

test "Ctx foreground pending helper transitions through take" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try std.testing.expectEqual(false, ctx_val.hasPendingForegroundCommands());
    _ = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"true"},
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });
    try std.testing.expectEqual(true, ctx_val.hasPendingForegroundCommands());

    const foreground = ctx_val.takePendingForegroundCommands();
    defer {
        for (foreground) |entry| {
            for (entry.argv) |arg| std.testing.allocator.free(arg);
            std.testing.allocator.free(entry.argv);
            if (entry.cwd) |cwd| std.testing.allocator.free(cwd);
        }
    }

    try std.testing.expectEqual(@as(usize, 1), foreground.len);
    try std.testing.expectEqual(false, ctx_val.hasPendingForegroundCommands());
}

test "Ctx clipboard pending helper transitions through take" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Ctx(TestMsg) = .{ ._allocator = std.testing.allocator };
    defer ctx_val.runtimeClearPendingEffectCopies();

    try std.testing.expectEqual(false, ctx_val.hasPendingClipboardCopies());
    _ = try ctx_val.terminal().copyToClipboard(.{
        .text = "clip",
        .finished = &struct {
            fn done(_: Ctx(TestMsg).ClipboardCopyResult) TestMsg {
                return .finished;
            }
        }.done,
    });
    try std.testing.expectEqual(true, ctx_val.hasPendingClipboardCopies());

    const clipboard = ctx_val.takePendingClipboardCopies();
    defer {
        for (clipboard) |entry| std.testing.allocator.free(entry.text);
    }

    try std.testing.expectEqual(@as(usize, 1), clipboard.len);
    try std.testing.expectEqualStrings("clip", clipboard[0].text);
    try std.testing.expectEqual(false, ctx_val.hasPendingClipboardCopies());
}
