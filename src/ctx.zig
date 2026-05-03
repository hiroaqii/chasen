const std = @import("std");

/// Context object passed to `update`, providing side-effect methods.
///
/// Provides `quit()` to exit the application and `spawn()` to launch
/// async tasks whose results are delivered back as messages.
pub fn Ctx(comptime Msg: type) type {
    const TaskFn = *const fn (std.mem.Allocator, std.Io) Msg;
    const max_tasks = 16;

    return struct {
        should_quit: bool = false,
        pending_tasks: [max_tasks]TaskFn = undefined,
        pending_tasks_len: u8 = 0,

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
