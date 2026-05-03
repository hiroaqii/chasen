const std = @import("std");

/// Context object passed to `update`, providing side-effect methods.
///
/// Provides `quit()` to exit the application and `spawn()` to launch
/// async tasks whose results are delivered back as messages.
pub fn Ctx(comptime Msg: type) type {
    const TaskFn = *const fn (std.mem.Allocator, std.Io) Msg;
    const max_tasks = 16;
    const max_ticks = 8;
    const max_everys = 8;

    return struct {
        pub const TickEntry = struct {
            after_ns: u64,
            msg: Msg,
        };

        pub const EveryEntry = struct {
            interval_ns: u64,
            msg: Msg,
        };

        should_quit: bool = false,
        pending_tasks: [max_tasks]TaskFn = undefined,
        pending_tasks_len: u8 = 0,
        pending_ticks: [max_ticks]TickEntry = undefined,
        pending_ticks_len: u8 = 0,
        pending_everys: [max_everys]EveryEntry = undefined,
        pending_everys_len: u8 = 0,

        /// Request the application to exit.
        pub fn quit(self: *@This()) void {
            self.should_quit = true;
        }

        /// Spawn an async task. The task function will be called concurrently
        /// and its return value delivered as a message to `update`.
        /// The task is queued here and started by the runtime after `update` returns.
        pub fn spawn(self: *@This(), task: TaskFn) void {
            std.debug.assert(self.pending_tasks_len < max_tasks);
            if (self.pending_tasks_len >= max_tasks) return;
            self.pending_tasks[self.pending_tasks_len] = task;
            self.pending_tasks_len += 1;
        }

        /// Return a slice of pending tasks.
        pub fn pendingSlice(self: *@This()) []const TaskFn {
            return self.pending_tasks[0..self.pending_tasks_len];
        }

        /// Schedule a one-shot delayed message.
        /// The message will be delivered once after `after_ns` nanoseconds.
        pub fn tick(self: *@This(), after_ns: u64, msg: Msg) void {
            std.debug.assert(self.pending_ticks_len < max_ticks);
            if (self.pending_ticks_len >= max_ticks) return;
            self.pending_ticks[self.pending_ticks_len] = .{ .after_ns = after_ns, .msg = msg };
            self.pending_ticks_len += 1;
        }

        /// Return a slice of pending tick entries.
        pub fn pendingTickSlice(self: *@This()) []const TickEntry {
            return self.pending_ticks[0..self.pending_ticks_len];
        }

        /// Schedule a repeating timer.
        /// The message will be delivered every `interval_ns` nanoseconds
        /// until the future is cancelled.
        /// Each call starts a new repeating timer; call this from `init` or guard it
        /// so repeated `update` calls do not create duplicate timers.
        pub fn every(self: *@This(), interval_ns: u64, msg: Msg) void {
            std.debug.assert(self.pending_everys_len < max_everys);
            if (self.pending_everys_len >= max_everys) return;
            self.pending_everys[self.pending_everys_len] = .{ .interval_ns = interval_ns, .msg = msg };
            self.pending_everys_len += 1;
        }

        /// Return a slice of pending every entries.
        pub fn pendingEverySlice(self: *@This()) []const EveryEntry {
            return self.pending_everys[0..self.pending_everys_len];
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

    ctx_val.spawn(task1);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_tasks_len);

    ctx_val.spawn(task1);
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_tasks_len);

    const slice = ctx_val.pendingSlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
}

test "Ctx tick accumulates entries" {
    const TestMsg = union(enum) { timeout, ping };
    var ctx_val: Ctx(TestMsg) = .{};

    ctx_val.tick(1_000_000_000, .timeout);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_ticks_len);

    ctx_val.tick(500_000_000, .ping);
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_ticks_len);

    const slice = ctx_val.pendingTickSlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), slice[0].after_ns);
    try std.testing.expect(slice[0].msg == .timeout);
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[1].after_ns);
    try std.testing.expect(slice[1].msg == .ping);
}

test "Ctx every accumulates entries" {
    const TestMsg = union(enum) { tick_msg, heartbeat };
    var ctx_val: Ctx(TestMsg) = .{};

    ctx_val.every(1_000_000_000, .tick_msg);
    try std.testing.expectEqual(@as(u8, 1), ctx_val.pending_everys_len);

    ctx_val.every(500_000_000, .heartbeat);
    try std.testing.expectEqual(@as(u8, 2), ctx_val.pending_everys_len);

    const slice = ctx_val.pendingEverySlice();
    try std.testing.expectEqual(@as(usize, 2), slice.len);
    try std.testing.expectEqual(@as(u64, 1_000_000_000), slice[0].interval_ns);
    try std.testing.expect(slice[0].msg == .tick_msg);
    try std.testing.expectEqual(@as(u64, 500_000_000), slice[1].interval_ns);
    try std.testing.expect(slice[1].msg == .heartbeat);
}
