const std = @import("std");
const builtin = @import("builtin");
const terminal_image = @import("terminal_image_types.zig");
const foreground_command = @import("foreground_command.zig");
const clipboard_types = @import("clipboard.zig");
const runtime_limits = @import("runtime_limits.zig");

const foreground_command_duplicate_min_fd = foreground_command.foreground_command_duplicate_min_fd;
const DuplicateForegroundCommandDirResult = foreground_command.DuplicateForegroundCommandDirResult;
const NativeForegroundCommandCwdOps = foreground_command.NativeForegroundCommandCwdOps;
const NativeForegroundCommandEnvironmentOps = foreground_command.NativeForegroundCommandEnvironmentOps;
const targetSupportsForegroundCommandDir = foreground_command.targetSupportsForegroundCommandDir;
const duplicateForegroundCommandDirWith = foreground_command.duplicateForegroundCommandDirWith;

/// A task identity is scoped to one Ctx/run and never reused in that run.
pub const TaskId = enum(u64) { _ };
pub const TaskStartError = error{ OutOfMemory, ConcurrencyUnavailable };

/// Pending runtime request owner. Ctx borrows this initialized stable storage.
/// Detached batches and running operations own their resources independently.
pub fn Requests(comptime Msg: type) type {
    const TaskFn = *const fn (std.mem.Allocator, std.Io) std.Io.Cancelable!Msg;
    const TaskFailedFn = *const fn (TaskStartError) Msg;
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

        pub const SpawnOptions = struct {
            run: TaskFn,
            failed: TaskFailedFn,
        };

        const Callbacks = union(enum) {
            plain: SpawnOptions,
            owned: struct {
                context: *anyopaque,
                run: *const fn (*anyopaque, std.mem.Allocator, std.Io) std.Io.Cancelable!Msg,
                failed: *const fn (*anyopaque, TaskStartError, std.mem.Allocator) Msg,
                cleanup: *const fn (*anyopaque, std.mem.Allocator) void,
            },
        };

        /// Internal task representation. Detaching transfers ownership: consume it
        /// exactly once with run, failed, or discard. Do not copy and reuse it.
        /// The bytes hide typed callbacks, not arbitrary casts or forged values.
        pub const TaskEntry = struct {
            id: TaskId,
            canceled: bool = false,
            _storage: [@sizeOf(Callbacks)]u8 align(@alignOf(Callbacks)),

            fn init(id: TaskId, callbacks_: Callbacks) TaskEntry {
                var entry: TaskEntry = .{ .id = id, ._storage = undefined };
                @memcpy(&entry._storage, std.mem.asBytes(&callbacks_));
                return entry;
            }

            fn callbacks(self: *const TaskEntry) *const Callbacks {
                return @ptrCast(&self._storage);
            }

            pub fn run(self: TaskEntry, allocator_: std.mem.Allocator, io_: std.Io) std.Io.Cancelable!Msg {
                defer self.discard(allocator_);
                if (self.canceled) return error.Canceled;
                return switch (self.callbacks().*) {
                    .plain => |opts| opts.run(allocator_, io_),
                    .owned => |opts| opts.run(opts.context, allocator_, io_),
                };
            }

            pub fn failed(self: TaskEntry, failure: TaskStartError, allocator_: std.mem.Allocator) Msg {
                std.debug.assert(!self.canceled);
                defer self.discard(allocator_);
                return switch (self.callbacks().*) {
                    .plain => |opts| opts.failed(failure),
                    .owned => |opts| opts.failed(opts.context, failure, allocator_),
                };
            }

            pub fn discard(self: TaskEntry, allocator_: std.mem.Allocator) void {
                switch (self.callbacks().*) {
                    .plain => {},
                    .owned => |opts| opts.cleanup(opts.context, allocator_),
                }
            }
        };

        pub const TerminalImageLoadEntry = struct {
            request_id: terminal_image.TerminalImageRequestId,
            path: []const u8,
            loaded: TerminalImageLoadedFn,
            failed: TerminalImageFailedFn,
        };

        pub const ForegroundCommandEntry = struct {
            request_id: foreground_command.ForegroundCommandRequestId,
            input: foreground_command.OwnedInput,
            finished: ForegroundCommandFinishedFn,

            pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
                self.input.deinit(gpa);
                self.* = undefined;
            }

            pub fn message(self: *const @This(), outcome: foreground_command.ForegroundCommandOutcome) Msg {
                return self.finished(.{ .request_id = self.request_id, .outcome = outcome });
            }
        };

        pub const ClipboardCopyOutcome = clipboard_types.ClipboardCopyOutcome;
        pub const ClipboardCopyResult = clipboard_types.ClipboardCopyResult;
        pub const ClipboardCopyRequestId = clipboard_types.ClipboardCopyRequestId;

        pub const ClipboardCopyEntry = struct {
            request_id: clipboard_types.ClipboardCopyRequestId,
            text: []const u8,
            finished: ClipboardCopyFinishedFn,

            pub fn deinit(self: *@This(), gpa: std.mem.Allocator) void {
                gpa.free(self.text);
                self.* = undefined;
            }

            pub fn message(self: *const @This(), outcome: ClipboardCopyOutcome) Msg {
                return self.finished(.{ .request_id = self.request_id, .outcome = outcome });
            }
        };

        // Required environment and all pending state belong to this owner.
        _io: std.Io,
        _allocator: std.mem.Allocator,
        _should_quit: bool = false,
        _pending_tasks: [max_tasks]TaskEntry = undefined,
        _pending_tasks_len: u8 = 0,
        _next_task_id: u64 = 1,
        _task_runtime: ?struct {
            context: *anyopaque,
            request: *const fn (*anyopaque, TaskId, std.Io) void,
        } = null,
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

        /// Initialize before binding a Ctx. Keep stable storage after binding.
        pub fn init(gpa: std.mem.Allocator, io_: std.Io) Self {
            return .{ ._allocator = gpa, ._io = io_ };
        }

        pub fn deinit(self: *Self) void {
            self.discardPendingTasks();
            self.discardPendingEffects();
            self.* = undefined;
        }

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

            /// Queue a plain task. No context or cancellation bookkeeping is
            /// required by the caller; discard the returned ID when unused.
            pub fn spawn(self: TaskEffects, opts: SpawnOptions) error{ TaskLimitExceeded, TaskIdExhausted }!TaskId {
                return self.enqueue(.{ .plain = opts });
            }

            /// Transfer context ownership only on successful admission. Chasen
            /// calls cleanup once after run/failed, or instead of either when
            /// abandoned before start. Borrowed fields still require a valid
            /// lifetime; clear fields moved into a result before returning.
            pub fn spawnOwned(self: TaskEffects, context: anytype, comptime opts: anytype) error{ TaskLimitExceeded, TaskIdExhausted }!TaskId {
                const Pointer = @TypeOf(context);
                comptime {
                    if (@typeInfo(Pointer) != .pointer or @typeInfo(Pointer).pointer.size != .one or @typeInfo(Pointer).pointer.is_const)
                        @compileError("task context must be a mutable single-item pointer");
                }
                const Adapter = struct {
                    fn run(ptr: *anyopaque, alloc: std.mem.Allocator, io_: std.Io) std.Io.Cancelable!Msg {
                        const callback: *const fn (Pointer, std.mem.Allocator, std.Io) std.Io.Cancelable!Msg = opts.run;
                        return callback(@ptrCast(@alignCast(ptr)), alloc, io_);
                    }
                    fn failed(ptr: *anyopaque, failure: TaskStartError, alloc: std.mem.Allocator) Msg {
                        const callback: *const fn (Pointer, TaskStartError, std.mem.Allocator) Msg = opts.failed;
                        return callback(@ptrCast(@alignCast(ptr)), failure, alloc);
                    }
                    fn cleanup(ptr: *anyopaque, alloc: std.mem.Allocator) void {
                        const callback: *const fn (Pointer, std.mem.Allocator) void = opts.cleanup;
                        callback(@ptrCast(@alignCast(ptr)), alloc);
                    }
                };
                return self.enqueue(.{ .owned = .{
                    .context = context,
                    .run = Adapter.run,
                    .failed = Adapter.failed,
                    .cleanup = Adapter.cleanup,
                } });
            }

            fn enqueue(self: TaskEffects, callbacks: Callbacks) error{ TaskLimitExceeded, TaskIdExhausted }!TaskId {
                if (self.ctx._pending_tasks_len >= max_tasks) return error.TaskLimitExceeded;
                if (self.ctx._next_task_id == 0) return error.TaskIdExhausted;
                const id: TaskId = @enumFromInt(self.ctx._next_task_id);
                self.ctx._next_task_id +%= 1;
                self.ctx._pending_tasks[self.ctx._pending_tasks_len] = TaskEntry.init(id, callbacks);
                self.ctx._pending_tasks_len += 1;
                return id;
            }

            /// Owning runtime thread only (init/update). Notify without joining
            /// or allocating. Completion/queued results can still win the race.
            pub fn requestCancel(self: TaskEffects, id: TaskId) void {
                for (self.ctx._pending_tasks[0..self.ctx._pending_tasks_len]) |*entry| {
                    if (entry.id == id) {
                        entry.canceled = true;
                        return;
                    }
                }
                if (self.ctx._task_runtime) |runtime_| runtime_.request(runtime_.context, id, self.ctx._io);
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
                cwd: foreground_command.ForegroundCommandCwd = .inherit,
                environment: foreground_command.ForegroundCommandEnvironment = .inherit,
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
            /// argv, `.path` cwd bytes, and every `.replace` environment key
            /// and value are copied while queueing because effects are drained
            /// after `update` returns. The caller must keep a replacement map
            /// and its key/value storage alive and unmodified, including by
            /// other threads, until this call returns. A `.dir` cwd is
            /// duplicated with close-on-exec; the caller keeps ownership of the
            /// original descriptor. An empty replacement remains an empty child
            /// environment. cwd and environment `.inherit` values are resolved
            /// when the child is spawned. `.inherit` and `.path` cwd are
            /// available on every supported target, while `.dir` is accepted
            /// on Linux and macOS. Replacement maps are cloned, owned, and
            /// cleaned up on every compiled target, but do not expand execution
            /// support; Windows still completes accepted requests with
            /// `failed = .{ .stage = .unsupported, .error_name = "Unsupported" }`.
            /// Chasen transports replacement
            /// maps without adding secret-specific handling.
            ///
            /// A follow-up foreground command queued from `finished` is
            /// processed by bounded drain rounds without waiting for unrelated
            /// input. Commands beyond that guard remain queued for a later
            /// event loop iteration.
            pub fn runForegroundCommand(
                self: TerminalEffects,
                opts: ForegroundCommandOptions,
            ) foreground_command.ForegroundCommandQueueError!foreground_command.ForegroundCommandRequestId {
                return self.runForegroundCommandWithOps(
                    opts,
                    NativeForegroundCommandCwdOps{},
                    NativeForegroundCommandEnvironmentOps{},
                );
            }

            fn runForegroundCommandWithCwdOps(
                self: TerminalEffects,
                opts: ForegroundCommandOptions,
                cwd_ops: anytype,
            ) foreground_command.ForegroundCommandQueueError!foreground_command.ForegroundCommandRequestId {
                return self.runForegroundCommandWithOps(
                    opts,
                    cwd_ops,
                    NativeForegroundCommandEnvironmentOps{},
                );
            }

            fn runForegroundCommandWithOps(
                self: TerminalEffects,
                opts: ForegroundCommandOptions,
                cwd_ops: anytype,
                environment_ops: anytype,
            ) foreground_command.ForegroundCommandQueueError!foreground_command.ForegroundCommandRequestId {
                if (self.ctx._should_quit) return error.ForegroundCommandRuntimeStopped;
                if (opts.argv.len == 0) return error.ForegroundCommandEmptyArgv;
                if (self.ctx._pending_foreground_commands_len >= max_foreground_commands)
                    return error.ForegroundCommandLimitExceeded;
                const input = try foreground_command.OwnedInput.initWithOps(
                    self.ctx._allocator,
                    opts.argv,
                    opts.cwd,
                    opts.environment,
                    cwd_ops,
                    environment_ops,
                );

                const request_id = foreground_command.ForegroundCommandRequestId{
                    .id = self.ctx._next_foreground_command_request_id,
                };
                self.ctx._next_foreground_command_request_id +%= 1;
                self.ctx._pending_foreground_commands[self.ctx._pending_foreground_commands_len] = .{
                    .request_id = request_id,
                    .input = input,
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

        const RequestKind = enum { task, tick, every, cancel, image_load, image_unload, foreground, clipboard };

        /// Closed transfer family: a detached value never borrows queue storage.
        fn Batch(comptime kind: RequestKind) type {
            const Entry = switch (kind) {
                .task => TaskEntry,
                .tick => TickEntry,
                .every => EveryEntry,
                .cancel => []const u8,
                .image_load => TerminalImageLoadEntry,
                .image_unload => terminal_image.TerminalImageHandle,
                .foreground => ForegroundCommandEntry,
                .clipboard => ClipboardCopyEntry,
            };
            const capacity = switch (kind) {
                .task => max_tasks,
                .tick => max_ticks,
                .every => max_everys,
                .cancel => max_cancels,
                .image_load => max_terminal_image_loads,
                .image_unload => max_terminal_image_unloads,
                .foreground => max_foreground_commands,
                .clipboard => max_clipboard_copies,
            };
            return struct {
                entries: [capacity]Entry = undefined,
                len: usize,
                cursor: usize = 0,
                allocator: std.mem.Allocator,

                fn take(gpa: std.mem.Allocator, pending: *[capacity]Entry, len: *u8) @This() {
                    var batch: @This() = .{ .len = len.*, .allocator = gpa };
                    @memcpy(batch.entries[0..len.*], pending[0..len.*]);
                    len.* = 0;
                    return batch;
                }

                fn takeAt(pending: *[capacity]Entry, len: *u8, index: usize) ?Entry {
                    if (index >= len.*) return null;
                    const entry = pending[index];
                    var i = index;
                    while (i + 1 < len.*) : (i += 1) pending[i] = pending[i + 1];
                    len.* -= 1;
                    pending[len.*] = undefined;
                    return entry;
                }

                /// Transfer exactly one entry; the caller now owns its cleanup.
                pub fn next(self: *@This()) ?Entry {
                    if (self.cursor == self.len) return null;
                    const entry = self.entries[self.cursor];
                    self.entries[self.cursor] = undefined;
                    self.cursor += 1;
                    return entry;
                }

                /// Release only the unconsumed suffix. Never calls app callbacks.
                pub fn deinit(self: *@This()) void {
                    while (self.next()) |entry| switch (kind) {
                        .task => entry.discard(self.allocator),
                        .tick, .every => self.allocator.free(entry.id),
                        .cancel => self.allocator.free(entry),
                        .image_load => self.allocator.free(entry.path),
                        .image_unload => {},
                        .foreground, .clipboard => {
                            var owned = entry;
                            owned.deinit(self.allocator);
                        },
                    };
                }
            };
        }

        pub fn detachTasks(self: *Self) Batch(.task) {
            return Batch(.task).take(self._allocator, &self._pending_tasks, &self._pending_tasks_len);
        }

        pub fn detachTicks(self: *Self) Batch(.tick) {
            return Batch(.tick).take(self._allocator, &self._pending_ticks, &self._pending_ticks_len);
        }

        pub fn detachEverys(self: *Self) Batch(.every) {
            return Batch(.every).take(self._allocator, &self._pending_everys, &self._pending_everys_len);
        }

        pub fn detachCancels(self: *Self) Batch(.cancel) {
            return Batch(.cancel).take(self._allocator, &self._pending_cancels, &self._pending_cancels_len);
        }

        pub fn detachTerminalImageLoads(self: *Self) Batch(.image_load) {
            return Batch(.image_load).take(self._allocator, &self._pending_terminal_image_loads, &self._pending_terminal_image_loads_len);
        }

        pub fn detachTerminalImageUnloads(self: *Self) Batch(.image_unload) {
            return Batch(.image_unload).take(self._allocator, &self._pending_terminal_image_unloads, &self._pending_terminal_image_unloads_len);
        }

        pub fn detachForegroundCommands(self: *Self) Batch(.foreground) {
            return Batch(.foreground).take(self._allocator, &self._pending_foreground_commands, &self._pending_foreground_commands_len);
        }

        pub fn detachClipboardCopies(self: *Self) Batch(.clipboard) {
            return Batch(.clipboard).take(self._allocator, &self._pending_clipboard_copies, &self._pending_clipboard_copies_len);
        }

        pub fn removeTaskAt(self: *Self, index: usize) ?TaskEntry {
            return Batch(.task).takeAt(&self._pending_tasks, &self._pending_tasks_len, index);
        }

        pub fn removeForegroundCommandAt(self: *Self, index: usize) ?ForegroundCommandEntry {
            return Batch(.foreground).takeAt(&self._pending_foreground_commands, &self._pending_foreground_commands_len, index);
        }

        pub fn removeClipboardCopyAt(self: *Self, index: usize) ?ClipboardCopyEntry {
            return Batch(.clipboard).takeAt(&self._pending_clipboard_copies, &self._pending_clipboard_copies_len, index);
        }

        pub fn discardPendingTasks(self: *Self) void {
            var batch = self.detachTasks();
            batch.deinit();
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
        pub fn discardPendingEffects(self: *Self) void {
            {
                var batch = self.detachTicks();
                batch.deinit();
            }
            {
                var batch = self.detachEverys();
                batch.deinit();
            }
            {
                var batch = self.detachCancels();
                batch.deinit();
            }
            {
                var batch = self.detachTerminalImageLoads();
                batch.deinit();
            }
            {
                var batch = self.detachTerminalImageUnloads();
                batch.deinit();
            }
            {
                var batch = self.detachForegroundCommands();
                batch.deinit();
            }
            {
                var batch = self.detachClipboardCopies();
                batch.deinit();
            }
        }
    };
}

const InjectedForegroundCommandCwdOps = struct {
    result: DuplicateForegroundCommandDirResult,
    interrupt_once: bool = false,
    call_count: usize = 0,
    minimum_fd: ?c_int = null,

    pub fn duplicate(
        self: *@This(),
        _: std.Io.Dir,
        minimum_fd: c_int,
    ) DuplicateForegroundCommandDirResult {
        self.call_count += 1;
        self.minimum_fd = minimum_fd;
        if (self.interrupt_once) {
            self.interrupt_once = false;
            return .interrupted;
        }
        return self.result;
    }
};

const CountingForegroundCommandCwdCloseOps = struct {
    close_count: *usize,

    pub fn close(self: @This(), _: std.Io.Dir) void {
        self.close_count.* += 1;
    }
};

const FailingForegroundCommandEnvironmentOps = struct {
    call_count: usize = 0,

    pub fn clone(
        self: *@This(),
        _: *const std.process.Environ.Map,
        _: std.mem.Allocator,
    ) std.mem.Allocator.Error!std.process.Environ.Map {
        self.call_count += 1;
        return error.OutOfMemory;
    }
};

const TrackingNativeForegroundCommandCwdOps = struct {
    duplicate_fd: ?std.Io.Dir.Handle = null,

    pub fn duplicate(
        self: *@This(),
        dir: std.Io.Dir,
        minimum_fd: c_int,
    ) DuplicateForegroundCommandDirResult {
        const result = (NativeForegroundCommandCwdOps{}).duplicate(dir, minimum_fd);
        switch (result) {
            .success => |duplicated_dir| self.duplicate_fd = duplicated_dir.handle,
            else => {},
        }
        return result;
    }
};

fn foregroundCommandTestFdFlags(fd: std.Io.Dir.Handle) ?u32 {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
            break :blk switch (std.os.linux.errno(rc)) {
                .SUCCESS => @intCast(rc),
                else => null,
            };
        },
        .macos => blk: {
            const rc = std.c.fcntl(fd, std.c.F.GETFD);
            break :blk switch (std.c.errno(rc)) {
                .SUCCESS => @intCast(rc),
                else => null,
            };
        },
        else => null,
    };
}

fn foregroundCommandTestCloexecFlag() u32 {
    return switch (builtin.os.tag) {
        .linux => std.os.linux.FD_CLOEXEC,
        .macos => std.c.FD_CLOEXEC,
        else => 0,
    };
}

test "Requests spawn accumulates tasks" {
    const TestMsg = union(enum) { hello, failed };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);

    const task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!TestMsg {
            return .hello;
        }
        fn failed(_: TaskStartError) TestMsg {
            return .failed;
        }
    };

    _ = try ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed });
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_tasks_len);

    _ = try ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed });
    try std.testing.expectEqual(@as(u8, 2), ctx_val._pending_tasks_len);

    var batch = ctx_val.detachTasks();
    defer batch.deinit();
    const slice = batch.entries[0..batch.len];
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(TestMsg.hello, try batch.next().?.run(std.testing.allocator, std.testing.io));
    batch.next().?.discard(std.testing.allocator);
}

test "Requests frame request marks a pending frame request" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);

    try std.testing.expectEqual(false, ctx_val._frame_requested);
    ctx_val.frame().request();
    try std.testing.expectEqual(true, ctx_val._frame_requested);
}

test "Requests spawn returns error when task queue is full" {
    const TestMsg = union(enum) { hello, failed };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);

    const task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!TestMsg {
            return .hello;
        }
        fn failed(_: TaskStartError) TestMsg {
            return .failed;
        }
    };

    for (0..16) |_| _ = try ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed });
    try std.testing.expectError(error.TaskLimitExceeded, ctx_val.task().spawn(.{ .run = task.run, .failed = task.failed }));
}

test "Requests tick accumulates entries" {
    const TestMsg = union(enum) { timeout, ping };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

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

test "Requests tick returns error when timer queue is full" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    for (0..8) |i| {
        const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
        try ctx_val.timer().tick(ids[i], 1_000_000_000, .timeout);
    }
    try std.testing.expectError(error.TimerLimitExceeded, ctx_val.timer().tick("overflow", 1_000_000_000, .timeout));
}

test "Requests every accumulates entries" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

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

test "Requests every returns error when timer queue is full" {
    const TestMsg = union(enum) { tick_msg };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    for (0..8) |i| {
        const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h" };
        try ctx_val.timer().every(ids[i], 1_000_000_000, .tick_msg);
    }
    try std.testing.expectError(error.TimerLimitExceeded, ctx_val.timer().every("overflow", 1_000_000_000, .tick_msg));
}

test "Requests tick same id overwrites existing entry" {
    const TestMsg = union(enum) { timeout, ping };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    try ctx_val.timer().tick("timer1", 1_000_000_000, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);

    // Same id should overwrite, not grow the queue.
    try ctx_val.timer().tick("timer1", 2_000_000_000, .ping);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);

    const slice = ctx_val._pending_ticks[0..ctx_val._pending_ticks_len];
    try std.testing.expectEqual(@as(u64, 2_000_000_000), slice[0].after_ns);
    try std.testing.expect(slice[0].msg == .ping);
}

test "Requests every same id overwrites existing entry" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    try ctx_val.timer().every("refresh", 1_000_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_everys_len);

    // Same id should overwrite.
    try ctx_val.timer().every("refresh", 500_000_000, .heartbeat);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_everys_len);

    const slice = ctx_val._pending_everys[0..ctx_val._pending_everys_len];
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[0].interval_ns);
    try std.testing.expect(slice[0].msg == .heartbeat);
}

test "Requests timer cancel removes from pending queues" {
    const TestMsg = union(enum) { timeout, tick_msg };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

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

test "Requests timer cancel queues id for runtime cancellation" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    try ctx_val.timer().cancel("running_timer");
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_cancels_len);

    const cancels = ctx_val._pending_cancels[0..ctx_val._pending_cancels_len];
    try std.testing.expectEqual(@as(usize, 1), cancels.len);
    try std.testing.expectEqualStrings("running_timer", cancels[0]);
}

test "Requests timer cancel then tick queues cancel and replacement" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    try ctx_val.timer().cancel("restart");
    try ctx_val.timer().tick("restart", 1_000_000_000, .timeout);

    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_cancels_len);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);

    try std.testing.expectEqualStrings("restart", ctx_val._pending_cancels[0..ctx_val._pending_cancels_len][0]);
    try std.testing.expectEqualStrings("restart", ctx_val._pending_ticks[0..ctx_val._pending_ticks_len][0].id);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), ctx_val._pending_ticks[0..ctx_val._pending_ticks_len][0].after_ns);
}

test "Requests timer cancel leaves pending timers unchanged when cancel queue is full" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    const cancel_ids = [_][]const u8{ "c0", "c1", "c2", "c3", "c4", "c5", "c6", "c7" };
    for (cancel_ids) |id| try ctx_val.timer().cancel(id);
    try ctx_val.timer().tick("pending", 1_000_000_000, .timeout);

    try std.testing.expectError(error.TimerCancelLimitExceeded, ctx_val.timer().cancel("pending"));
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);
    try std.testing.expectEqualStrings("pending", ctx_val._pending_ticks[0..ctx_val._pending_ticks_len][0].id);
}

test "task owned entries consume once on run failure discard and pending cancel" {
    const Capture = struct {
        cleanups: *usize,
        fn run(_: *@This(), _: std.mem.Allocator, _: std.Io) std.Io.Cancelable!u32 {
            return 42;
        }
        fn failed(_: *@This(), _: TaskStartError, _: std.mem.Allocator) u32 {
            return 17;
        }
        fn cleanup(self: *@This(), alloc: std.mem.Allocator) void {
            self.cleanups.* += 1;
            alloc.destroy(self);
        }
    };
    var count: usize = 0;
    var ctx: Requests(u32) = .init(std.testing.allocator, std.testing.io);
    for (0..4) |terminal| {
        const capture = try std.testing.allocator.create(Capture);
        capture.* = .{ .cleanups = &count };
        const id = try ctx.task().spawnOwned(capture, .{ .run = Capture.run, .failed = Capture.failed, .cleanup = Capture.cleanup });
        if (terminal == 3) {
            ctx.task().requestCancel(id);
            ctx.task().requestCancel(id);
        }
        var batch = ctx.detachTasks();
        defer batch.deinit();
        const entry = batch.next().?;
        switch (terminal) {
            0 => try std.testing.expectEqual(@as(u32, 42), try entry.run(std.testing.allocator, std.testing.io)),
            1 => try std.testing.expectEqual(@as(u32, 17), entry.failed(error.ConcurrencyUnavailable, std.testing.allocator)),
            2 => entry.discard(std.testing.allocator),
            3 => try std.testing.expectError(error.Canceled, entry.run(std.testing.allocator, std.testing.io)),
            else => unreachable,
        }
        try std.testing.expectEqual(terminal + 1, count);
        ctx.task().requestCancel(id); // consumed IDs are harmless without a registry
    }
}

test "Requests image loadPath copies queued path" {
    const TestMsg = union(enum) { loaded, failed };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

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

test "Requests image unload queues handles" {
    const TestMsg = union(enum) { done };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);

    const handle = terminal_image.TerminalImageHandle{ .id = 7, .generation = 2 };
    try ctx_val.image().unload(handle);

    const pending = ctx_val._pending_terminal_image_unloads[0..ctx_val._pending_terminal_image_unloads_len];
    try std.testing.expectEqual(@as(usize, 1), pending.len);
    try std.testing.expectEqual(handle, pending[0]);
}

test "Requests image unload returns error when queue is full" {
    const TestMsg = union(enum) { done };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);

    const handle = terminal_image.TerminalImageHandle{ .id = 7, .generation = 2 };
    for (0..8) |_| try ctx_val.image().unload(handle);

    try std.testing.expectError(error.TerminalImageUnloadLimitExceeded, ctx_val.image().unload(handle));
}

test "Requests terminal foreground command copies argv and cwd" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

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
        .cwd = .{ .path = cwd[0..] },
        .finished = finished,
    });

    try std.testing.expectEqual(@as(u64, 1), request_id.id);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_foreground_commands_len);

    arg0[0] = 'X';
    arg1[0] = 'Y';
    cwd[1] = 'z';

    const entry = ctx_val._pending_foreground_commands[0..ctx_val._pending_foreground_commands_len][0];
    try std.testing.expectEqual(@as(u64, 1), entry.request_id.id);
    try std.testing.expectEqualStrings("ed", entry.input.argv[0]);
    try std.testing.expectEqualStrings("file", entry.input.argv[1]);
    switch (entry.input.cwd) {
        .path => |path| try std.testing.expectEqualStrings("/tmp", path),
        else => return error.TestUnexpectedResult,
    }
}

test "foreground environment copies caller map and distinguishes inherit from empty replacement" {
    const TestMsg = union(enum) { finished };
    const finished = &struct {
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }
    }.done;

    var caller_map: std.process.Environ.Map = .init(std.testing.allocator);
    var caller_map_live = true;
    defer if (caller_map_live) caller_map.deinit();
    try caller_map.put("ISSUE55_FIRST", "queued-first");
    try caller_map.put("ISSUE55_SECOND", "queued-second");

    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();
    _ = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"command"},
        .environment = .{ .replace = &caller_map },
        .finished = finished,
    });

    try caller_map.put("ISSUE55_FIRST", "caller-mutated");
    try std.testing.expect(caller_map.orderedRemove("ISSUE55_SECOND"));
    try caller_map.put("ISSUE55_THIRD", "caller-only");
    caller_map.deinit();
    caller_map_live = false;

    const queued_map = ctx_val._pending_foreground_commands[0].input.childEnvironment() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), queued_map.count());
    try std.testing.expectEqualStrings("queued-first", queued_map.get("ISSUE55_FIRST").?);
    try std.testing.expectEqualStrings("queued-second", queued_map.get("ISSUE55_SECOND").?);

    ctx_val.discardPendingEffects();
    var empty_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer empty_map.deinit();
    _ = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"command"},
        .environment = .{ .replace = &empty_map },
        .finished = finished,
    });
    const queued_empty = ctx_val._pending_foreground_commands[0].input.childEnvironment() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), queued_empty.count());

    ctx_val.discardPendingEffects();
    _ = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"command"},
        .environment = .inherit,
        .finished = finished,
    });
    try std.testing.expect(ctx_val._pending_foreground_commands[0].input.childEnvironment() == null);
}

test "foreground environment acquisition follows empty and full queue rejection" {
    const TestMsg = union(enum) { finished };
    const finished = &struct {
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }
    }.done;
    var caller_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer caller_map.deinit();
    try caller_map.put("ISSUE55_ORDER", "value");
    var environment_ops: FailingForegroundCommandEnvironmentOps = .{};
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    try std.testing.expectError(error.ForegroundCommandEmptyArgv, ctx_val.terminal().runForegroundCommandWithOps(.{
        .argv = &.{},
        .environment = .{ .replace = &caller_map },
        .finished = finished,
    }, NativeForegroundCommandCwdOps{}, &environment_ops));
    try std.testing.expectEqual(@as(usize, 0), environment_ops.call_count);

    _ = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"first"},
        .finished = finished,
    });
    try std.testing.expectError(error.ForegroundCommandLimitExceeded, ctx_val.terminal().runForegroundCommandWithOps(.{
        .argv = &.{"second"},
        .environment = .{ .replace = &caller_map },
        .finished = finished,
    }, NativeForegroundCommandCwdOps{}, &environment_ops));
    try std.testing.expectEqual(@as(usize, 0), environment_ops.call_count);

    var cwd_failure_ctx: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer cwd_failure_ctx.discardPendingEffects();
    var cwd_ops: InjectedForegroundCommandCwdOps = .{ .result = .invalid };
    var later_environment_ops: FailingForegroundCommandEnvironmentOps = .{};
    try std.testing.expectError(error.ForegroundCommandInvalidCwd, cwd_failure_ctx.terminal().runForegroundCommandWithOps(.{
        .argv = &.{"command"},
        .cwd = .{ .dir = std.Io.Dir.cwd() },
        .environment = .{ .replace = &caller_map },
        .finished = finished,
    }, &cwd_ops, &later_environment_ops));
    try std.testing.expectEqual(@as(usize, 1), cwd_ops.call_count);
    try std.testing.expectEqual(@as(usize, 0), later_environment_ops.call_count);
    try std.testing.expectEqual(@as(u8, 0), cwd_failure_ctx._pending_foreground_commands_len);
    try std.testing.expectEqual(@as(u64, 1), cwd_failure_ctx._next_foreground_command_request_id);
}

test "Requests terminal foreground command rejects empty argv and overflow" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

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
    const next_request_id = ctx_val._next_foreground_command_request_id;
    try std.testing.expectError(error.ForegroundCommandEmptyArgv, ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{},
        .cwd = .{ .dir = std.Io.Dir.cwd() },
        .finished = finished,
    }));
    try std.testing.expectError(error.ForegroundCommandLimitExceeded, ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"false"},
        .cwd = .{ .dir = std.Io.Dir.cwd() },
        .finished = finished,
    }));
    try std.testing.expectEqual(next_request_id, ctx_val._next_foreground_command_request_id);
}

test "foreground command cwd target policy accepts descriptors only on Linux and macOS" {
    try std.testing.expect(targetSupportsForegroundCommandDir(.linux));
    try std.testing.expect(targetSupportsForegroundCommandDir(.macos));
    try std.testing.expect(!targetSupportsForegroundCommandDir(.windows));
    try std.testing.expect(!targetSupportsForegroundCommandDir(.wasi));
}

test "Requests terminal foreground command maps descriptor duplication failures" {
    if (!targetSupportsForegroundCommandDir(builtin.os.tag)) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    const finished = &struct {
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }
    }.done;
    const cases = [_]struct {
        injected: DuplicateForegroundCommandDirResult,
        expected: anyerror,
    }{
        .{ .injected = .invalid, .expected = error.ForegroundCommandInvalidCwd },
        .{ .injected = .process_fd_quota, .expected = error.ForegroundCommandProcessFdQuotaExceeded },
        .{ .injected = .system_fd_quota, .expected = error.ForegroundCommandSystemFdQuotaExceeded },
        .{ .injected = .failed, .expected = error.ForegroundCommandDuplicateCwdFailed },
    };

    for (cases) |case| {
        var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
        defer ctx_val.discardPendingEffects();
        var ops: InjectedForegroundCommandCwdOps = .{ .result = case.injected };

        try std.testing.expectError(case.expected, ctx_val.terminal().runForegroundCommandWithCwdOps(.{
            .argv = &.{ "tool", "arg" },
            .cwd = .{ .dir = std.Io.Dir.cwd() },
            .finished = finished,
        }, &ops));

        try std.testing.expectEqual(@as(usize, 1), ops.call_count);
        try std.testing.expectEqual(@as(?c_int, foreground_command_duplicate_min_fd), ops.minimum_fd);
        try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_foreground_commands_len);
        try std.testing.expectEqual(@as(u64, 1), ctx_val._next_foreground_command_request_id);
    }
}

test "Requests terminal foreground command retries interrupted descriptor duplication" {
    if (!targetSupportsForegroundCommandDir(builtin.os.tag)) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "caller", .default_dir);
    const caller_dir = try tmp.dir.openDir(std.testing.io, "caller", .{});
    defer caller_dir.close(std.testing.io);

    const real_duplicate = try duplicateForegroundCommandDirWith(caller_dir, NativeForegroundCommandCwdOps{});
    var ops: InjectedForegroundCommandCwdOps = .{
        .result = .{ .success = real_duplicate },
        .interrupt_once = true,
    };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    _ = try ctx_val.terminal().runForegroundCommandWithCwdOps(.{
        .argv = &.{"true"},
        .cwd = .{ .dir = caller_dir },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    }, &ops);

    try std.testing.expectEqual(@as(usize, 2), ops.call_count);
    try std.testing.expectEqual(@as(?c_int, foreground_command_duplicate_min_fd), ops.minimum_fd);
}

test "Requests terminal foreground command rejects cwd pseudo descriptor" {
    if (!targetSupportsForegroundCommandDir(builtin.os.tag)) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    try std.testing.expectError(error.ForegroundCommandInvalidCwd, ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"true"},
        .cwd = .{ .dir = std.Io.Dir.cwd() },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    }));
}

test "Requests terminal foreground command rejects an already closed cwd descriptor" {
    if (!targetSupportsForegroundCommandDir(builtin.os.tag)) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "closed", .default_dir);
    const closed_dir = try tmp.dir.openDir(std.testing.io, "closed", .{});
    closed_dir.close(std.testing.io);

    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();
    try std.testing.expectError(error.ForegroundCommandInvalidCwd, ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"true"},
        .cwd = .{ .dir = closed_dir },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    }));
    try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_foreground_commands_len);
    try std.testing.expectEqual(@as(u64, 1), ctx_val._next_foreground_command_request_id);
}

test "foreground cleanup releases pending cwd and environment owners once" {
    if (!targetSupportsForegroundCommandDir(builtin.os.tag)) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "caller", .default_dir);
    const caller_dir = try tmp.dir.openDir(std.testing.io, "caller", .{});
    defer caller_dir.close(std.testing.io);
    var caller_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer caller_map.deinit();
    try caller_map.put("ISSUE55_PENDING", "owned");

    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    _ = try ctx_val.terminal().runForegroundCommand(.{
        .argv = &.{"true"},
        .cwd = .{ .dir = caller_dir },
        .environment = .{ .replace = &caller_map },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    const duplicate_fd = switch (ctx_val._pending_foreground_commands[0].input.cwd) {
        .dir => |dir| dir.handle,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(duplicate_fd >= foreground_command_duplicate_min_fd);
    try std.testing.expect(duplicate_fd != caller_dir.handle);
    const duplicate_flags = foregroundCommandTestFdFlags(duplicate_fd) orelse return error.TestUnexpectedResult;
    try std.testing.expect(duplicate_flags & foregroundCommandTestCloexecFlag() != 0);
    try std.testing.expect(foregroundCommandTestFdFlags(caller_dir.handle) != null);
    const queued_environment = ctx_val._pending_foreground_commands[0].input.childEnvironment() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("owned", queued_environment.get("ISSUE55_PENDING").?);

    ctx_val.discardPendingEffects();
    ctx_val.discardPendingEffects();

    try std.testing.expect(foregroundCommandTestFdFlags(duplicate_fd) == null);
    try std.testing.expect(foregroundCommandTestFdFlags(caller_dir.handle) != null);
}

test "foreground command common entry cleanup invokes descriptor close once" {
    const TestMsg = union(enum) { finished };
    const argv = try std.testing.allocator.alloc([]const u8, 1);
    errdefer std.testing.allocator.free(argv);
    argv[0] = try std.testing.allocator.dupe(u8, "true");

    var entry: Requests(TestMsg).ForegroundCommandEntry = .{
        .request_id = .{ .id = 1 },
        .input = .{ .argv = argv, .cwd = .{ .dir = std.Io.Dir.cwd() }, .environment = .inherit },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    };
    var close_count: usize = 0;
    entry.input.deinitWith(
        std.testing.allocator,
        CountingForegroundCommandCwdCloseOps{ .close_count = &close_count },
    );

    try std.testing.expectEqual(@as(usize, 1), close_count);
}

test "Requests terminal foreground command construction is leak free at every allocation" {
    const Harness = struct {
        const TestMsg = union(enum) { finished };

        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }

        fn run(gpa: std.mem.Allocator) !void {
            var ctx_val: Requests(TestMsg) = .init(gpa, std.testing.io);
            defer ctx_val.discardPendingEffects();
            _ = ctx_val.terminal().runForegroundCommand(.{
                .argv = &.{ "command", "first", "second" },
                .cwd = .{ .path = "/tmp/foreground-command" },
                .finished = done,
            }) catch |err| {
                try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_foreground_commands_len);
                try std.testing.expectEqual(@as(u64, 1), ctx_val._next_foreground_command_request_id);
                return err;
            };
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "foreground environment clone failure rolls back the acquired cwd owner" {
    if (!targetSupportsForegroundCommandDir(builtin.os.tag)) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "caller", .default_dir);
    const caller_dir = try tmp.dir.openDir(std.testing.io, "caller", .{});
    defer caller_dir.close(std.testing.io);
    var caller_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer caller_map.deinit();
    try caller_map.put("ISSUE55_ROLLBACK", "value");

    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();
    var cwd_ops: TrackingNativeForegroundCommandCwdOps = .{};
    var environment_ops: FailingForegroundCommandEnvironmentOps = .{};
    try std.testing.expectError(error.OutOfMemory, ctx_val.terminal().runForegroundCommandWithOps(.{
        .argv = &.{ "command", "arg" },
        .cwd = .{ .dir = caller_dir },
        .environment = .{ .replace = &caller_map },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    }, &cwd_ops, &environment_ops));

    const duplicate_fd = cwd_ops.duplicate_fd orelse return error.TestUnexpectedResult;
    try std.testing.expect(foregroundCommandTestFdFlags(duplicate_fd) == null);
    try std.testing.expect(foregroundCommandTestFdFlags(caller_dir.handle) != null);
    try std.testing.expectEqual(@as(usize, 1), environment_ops.call_count);
    try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_foreground_commands_len);
    try std.testing.expectEqual(@as(u64, 1), ctx_val._next_foreground_command_request_id);
    try std.testing.expectEqualStrings("value", caller_map.get("ISSUE55_ROLLBACK").?);
}

test "foreground environment construction is leak free at every allocation" {
    if (!targetSupportsForegroundCommandDir(builtin.os.tag)) return error.SkipZigTest;

    const Harness = struct {
        const TestMsg = union(enum) { finished };

        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }

        fn run(gpa: std.mem.Allocator) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.createDir(std.testing.io, "caller", .default_dir);
            const caller_dir = try tmp.dir.openDir(std.testing.io, "caller", .{});
            defer caller_dir.close(std.testing.io);
            var caller_map: std.process.Environ.Map = .init(std.testing.allocator);
            defer caller_map.deinit();
            try caller_map.put("ISSUE55_FIRST", "first-value");
            try caller_map.put("ISSUE55_SECOND", "second-value");

            var ctx_val: Requests(TestMsg) = .init(gpa, std.testing.io);
            defer ctx_val.discardPendingEffects();
            var cwd_ops: TrackingNativeForegroundCommandCwdOps = .{};
            _ = ctx_val.terminal().runForegroundCommandWithCwdOps(.{
                .argv = &.{ "command", "first", "second" },
                .cwd = .{ .dir = caller_dir },
                .environment = .{ .replace = &caller_map },
                .finished = done,
            }, &cwd_ops) catch |err| {
                try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_foreground_commands_len);
                try std.testing.expectEqual(@as(u64, 1), ctx_val._next_foreground_command_request_id);
                try std.testing.expect(foregroundCommandTestFdFlags(caller_dir.handle) != null);
                try std.testing.expectEqual(@as(usize, 2), caller_map.count());
                try std.testing.expectEqualStrings("first-value", caller_map.get("ISSUE55_FIRST").?);
                try std.testing.expectEqualStrings("second-value", caller_map.get("ISSUE55_SECOND").?);
                if (cwd_ops.duplicate_fd) |duplicate_fd| {
                    try std.testing.expect(foregroundCommandTestFdFlags(duplicate_fd) == null);
                }
                return err;
            };

            const duplicate_fd = cwd_ops.duplicate_fd orelse return error.TestUnexpectedResult;
            try std.testing.expect(foregroundCommandTestFdFlags(duplicate_fd) != null);
            ctx_val.discardPendingEffects();
            try std.testing.expect(foregroundCommandTestFdFlags(duplicate_fd) == null);
            try std.testing.expect(foregroundCommandTestFdFlags(caller_dir.handle) != null);
            try std.testing.expectEqual(@as(usize, 2), caller_map.count());
            try std.testing.expectEqualStrings("first-value", caller_map.get("ISSUE55_FIRST").?);
            try std.testing.expectEqualStrings("second-value", caller_map.get("ISSUE55_SECOND").?);
        }
    };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, Harness.run, .{});
}

test "Requests terminal clipboard copy queues owned text" {
    const TestMsg = union(enum) { finished: u64 };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    const finished = &struct {
        fn done(result: Requests(TestMsg).ClipboardCopyResult) TestMsg {
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
    try std.testing.expectEqual(@as(Requests(TestMsg).ClipboardCopyFinishedFn, finished), entry.finished);
    const completion = entry.finished(.{ .request_id = entry.request_id, .outcome = .sent });
    try std.testing.expectEqual(request_id.id, completion.finished);
}

test "Requests terminal clipboard copy rejects overflow" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    const finished = &struct {
        fn done(_: Requests(TestMsg).ClipboardCopyResult) TestMsg {
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

test "Requests _redraw_suppressed defaults to false" {
    const TestMsg = union(enum) { hello };
    const ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);

    try std.testing.expectEqual(false, ctx_val._redraw_suppressed);
}

test "Requests redraw skip sets _redraw_suppressed to true" {
    const TestMsg = union(enum) { hello };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);

    ctx_val.redraw().skip();
    try std.testing.expectEqual(true, ctx_val._redraw_suppressed);
}

test "task shared admission limit and exhausted identities preserve caller ownership" {
    const Task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!u8 {
            return 1;
        }
        fn failed(_: TaskStartError) u8 {
            return 0;
        }
        fn ownedRun(_: *usize, _: std.mem.Allocator, _: std.Io) std.Io.Cancelable!u8 {
            return 2;
        }
        fn ownedFailed(_: *usize, _: TaskStartError, _: std.mem.Allocator) u8 {
            return 0;
        }
        fn cleanup(count: *usize, _: std.mem.Allocator) void {
            count.* += 1;
        }
    };
    var ctx: Requests(u8) = .init(std.testing.allocator, std.testing.io);
    var cleanups: usize = 0;
    const opts = .{ .run = Task.ownedRun, .failed = Task.ownedFailed, .cleanup = Task.cleanup };
    for (0..10) |_| _ = try ctx.task().spawn(.{ .run = Task.run, .failed = Task.failed });
    for (0..6) |_| _ = try ctx.task().spawnOwned(&cleanups, opts);
    try std.testing.expectError(error.TaskLimitExceeded, ctx.task().spawn(.{ .run = Task.run, .failed = Task.failed }));
    try std.testing.expectError(error.TaskLimitExceeded, ctx.task().spawnOwned(&cleanups, opts));
    try std.testing.expectEqual(@as(usize, 0), cleanups);
    ctx.discardPendingTasks();
    try std.testing.expectEqual(@as(usize, 6), cleanups);
    ctx._next_task_id = std.math.maxInt(u64);
    const last = try ctx.task().spawnOwned(&cleanups, opts);
    try std.testing.expectEqual(std.math.maxInt(u64), @intFromEnum(last));
    try std.testing.expectError(error.TaskIdExhausted, ctx.task().spawnOwned(&cleanups, opts));
    ctx.discardPendingTasks();
    try std.testing.expectEqual(@as(usize, 7), cleanups);
    try std.testing.expectError(error.TaskIdExhausted, ctx.task().spawn(.{ .run = Task.run, .failed = Task.failed }));
}

test "Requests take pending queues returns empty slices initially" {
    const TestMsg = union(enum) { done };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);

    try std.testing.expectEqual(@as(usize, 0), ctx_val.detachTasks().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.detachTicks().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.detachEverys().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.detachCancels().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.detachTerminalImageLoads().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.detachTerminalImageUnloads().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.detachForegroundCommands().len);
    try std.testing.expectEqual(@as(usize, 0), ctx_val.detachClipboardCopies().len);
}

test "Requests take pending ticks clears queue and allows requeue" {
    const TestMsg = union(enum) { timeout };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    try ctx_val.timer().tick("first", 1, .timeout);
    var taken = ctx_val.detachTicks();
    defer taken.deinit();

    try std.testing.expectEqual(@as(usize, 1), taken.len);
    try std.testing.expectEqualStrings("first", taken.entries[0].id);
    try std.testing.expectEqual(@as(u8, 0), ctx_val._pending_ticks_len);

    ctx_val.discardPendingEffects();
    try ctx_val.timer().tick("second", 2, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val._pending_ticks_len);
    try std.testing.expectEqualStrings("second", ctx_val._pending_ticks[0].id);
}

test "Requests taken effect copies are not cleared by runtime cleanup" {
    const TestMsg = union(enum) { timeout, loaded, failed, finished };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

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
        .cwd = .{ .path = "/tmp" },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });
    _ = try ctx_val.terminal().copyToClipboard(.{
        .text = "clipboard",
        .finished = &struct {
            fn done(_: Requests(TestMsg).ClipboardCopyResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    var ticks = ctx_val.detachTicks();
    defer ticks.deinit();
    var loads = ctx_val.detachTerminalImageLoads();
    defer loads.deinit();
    var foreground = ctx_val.detachForegroundCommands();
    defer foreground.deinit();
    var clipboard = ctx_val.detachClipboardCopies();
    defer clipboard.deinit();

    ctx_val.discardPendingEffects();

    try std.testing.expectEqualStrings("taken-tick", ticks.entries[0].id);
    try std.testing.expectEqualStrings("image.png", loads.entries[0].path);
    try std.testing.expectEqualStrings("true", foreground.entries[0].input.argv[0]);
    switch (foreground.entries[0].input.cwd) {
        .path => |path| try std.testing.expectEqualStrings("/tmp", path),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqualStrings("clipboard", clipboard.entries[0].text);
}

test "Requests foreground pending helper transitions through take" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

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

    var foreground = ctx_val.detachForegroundCommands();
    defer foreground.deinit();

    try std.testing.expectEqual(@as(usize, 1), foreground.len);
    try std.testing.expectEqual(false, ctx_val.hasPendingForegroundCommands());
}

test "Requests clipboard pending helper transitions through take" {
    const TestMsg = union(enum) { finished };
    var ctx_val: Requests(TestMsg) = .init(std.testing.allocator, std.testing.io);
    defer ctx_val.discardPendingEffects();

    try std.testing.expectEqual(false, ctx_val.hasPendingClipboardCopies());
    _ = try ctx_val.terminal().copyToClipboard(.{
        .text = "clip",
        .finished = &struct {
            fn done(_: Requests(TestMsg).ClipboardCopyResult) TestMsg {
                return .finished;
            }
        }.done,
    });
    try std.testing.expectEqual(true, ctx_val.hasPendingClipboardCopies());

    var clipboard = ctx_val.detachClipboardCopies();
    defer clipboard.deinit();

    try std.testing.expectEqual(@as(usize, 1), clipboard.len);
    try std.testing.expectEqualStrings("clip", clipboard.entries[0].text);
    try std.testing.expectEqual(false, ctx_val.hasPendingClipboardCopies());
}

test "Requests task batch abandons only its unconsumed suffix" {
    const Capture = struct {
        cleanups: *usize,
        fn run(_: *@This(), _: std.mem.Allocator, _: std.Io) std.Io.Cancelable!u8 {
            return 7;
        }
        fn failed(_: *@This(), _: TaskStartError, _: std.mem.Allocator) u8 {
            unreachable;
        }
        fn cleanup(self: *@This(), alloc: std.mem.Allocator) void {
            self.cleanups.* += 1;
            alloc.destroy(self);
        }
    };
    var requests = Requests(u8).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var cleanups: usize = 0;
    for (0..3) |_| {
        const capture = try std.testing.allocator.create(Capture);
        capture.* = .{ .cleanups = &cleanups };
        _ = try requests.task().spawnOwned(capture, .{ .run = Capture.run, .failed = Capture.failed, .cleanup = Capture.cleanup });
    }
    var batch = requests.detachTasks();
    defer batch.deinit();
    const first = batch.next().?;
    try std.testing.expectEqual(@as(u8, 7), try first.run(std.testing.allocator, std.testing.io));
    try std.testing.expectEqual(@as(usize, 1), cleanups);
    const new_capture = try std.testing.allocator.create(Capture);
    new_capture.* = .{ .cleanups = &cleanups };
    _ = try requests.task().spawnOwned(new_capture, .{ .run = Capture.run, .failed = Capture.failed, .cleanup = Capture.cleanup });
    batch.deinit();
    try std.testing.expectEqual(@as(usize, 3), cleanups);
    requests.discardPendingTasks();
    try std.testing.expectEqual(@as(usize, 4), cleanups);
}

test "Requests timer batches own unconsumed IDs separately from new pending" {
    var requests = Requests(u8).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    for ([_][]const u8{ "one", "two" }) |id| {
        try requests.timer().tick(id, 1, 1);
        try requests.timer().every(id, 2, 2);
    }
    try requests.timer().cancel("absent-one");
    try requests.timer().cancel("absent-two");
    var ticks = requests.detachTicks();
    defer ticks.deinit();
    var everys = requests.detachEverys();
    defer everys.deinit();
    var cancels = requests.detachCancels();
    defer cancels.deinit();
    const tick = ticks.next().?;
    defer std.testing.allocator.free(tick.id);
    const every = everys.next().?;
    defer std.testing.allocator.free(every.id);
    const cancel = cancels.next().?;
    defer std.testing.allocator.free(cancel);
    try requests.timer().tick("new-tick", 3, 3);
    try requests.timer().every("new-every", 4, 4);
    try requests.timer().cancel("new-cancel");
    requests.discardPendingEffects();
    try std.testing.expectEqualStrings("two", ticks.entries[ticks.cursor].id);
    try std.testing.expectEqualStrings("two", everys.entries[everys.cursor].id);
    try std.testing.expectEqualStrings("absent-two", cancels.entries[cancels.cursor]);
}
