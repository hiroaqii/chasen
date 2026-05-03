const std = @import("std");

/// Side-effect descriptor used by Ctx methods and composable by components.
/// Cmd values describe effects only; they do not execute work by themselves.
///
/// Users typically call Ctx methods (spawn, tick, every) rather than
/// constructing Cmd values directly. Components may return Cmd for
/// composition via batch/sequence.
pub fn Cmd(comptime Msg: type) type {
    return union(enum) {
        /// No operation.
        none,

        /// Request the application to exit.
        quit,

        /// Run multiple commands concurrently.
        batch: []const Cmd(Msg),

        /// Run commands in order, each waiting for the previous to complete.
        sequence: []const Cmd(Msg),

        /// Send `msg` once after `after_ns` nanoseconds.
        tick: Tick(Msg),

        /// Send `msg` repeatedly every `interval_ns` nanoseconds.
        every: Every(Msg),

        /// Spawn an async task that produces a Msg.
        task: *const fn (allocator: std.mem.Allocator, io: std.Io) Msg,

        /// Spawn an async task with captured context.
        ///
        /// The caller must ensure `ctx` remains valid until the task finishes
        /// or is cancelled.
        task_with: TaskWith(Msg),
    };
}

fn Tick(comptime Msg: type) type {
    return struct {
        after_ns: u64,
        msg: Msg,
    };
}

fn Every(comptime Msg: type) type {
    return struct {
        interval_ns: u64,
        msg: Msg,
    };
}

fn TaskWith(comptime Msg: type) type {
    return struct {
        ctx: *anyopaque,
        run: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, io: std.Io) Msg,
    };
}

test "Cmd instantiation" {
    const TestMsg = union(enum) {
        hello,
        value: u32,
    };

    const C = Cmd(TestMsg);

    // Verify none
    const none: C = .none;
    try std.testing.expect(none == .none);

    // Verify quit
    const quit_cmd: C = .quit;
    try std.testing.expect(quit_cmd == .quit);

    // Verify tick
    const tick_cmd: C = .{ .tick = .{ .after_ns = 1_000_000, .msg = .hello } };
    try std.testing.expectEqual(@as(u64, 1_000_000), tick_cmd.tick.after_ns);

    // Verify every
    const every_cmd: C = .{ .every = .{ .interval_ns = 100_000_000, .msg = .{ .value = 42 } } };
    try std.testing.expectEqual(@as(u64, 100_000_000), every_cmd.every.interval_ns);
    try std.testing.expectEqual(@as(u32, 42), every_cmd.every.msg.value);

    // Verify batch
    const cmds = [_]C{ .none, .quit };
    const batch_cmd: C = .{ .batch = &cmds };
    try std.testing.expectEqual(@as(usize, 2), batch_cmd.batch.len);

    // Verify sequence
    const seq_cmd: C = .{ .sequence = &cmds };
    try std.testing.expectEqual(@as(usize, 2), seq_cmd.sequence.len);

    // Verify task — holds function pointer without invoking
    const task_cmd: C = .{ .task = &struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .hello;
        }
    }.run };
    try std.testing.expect(task_cmd == .task);

    // Verify task_with — holds ctx and run without invoking
    var state: u32 = 7;
    const tw_cmd: C = .{ .task_with = .{
        .ctx = @ptrCast(&state),
        .run = &struct {
            fn run(_: *anyopaque, _: std.mem.Allocator, _: std.Io) TestMsg {
                return .hello;
            }
        }.run,
    } };
    try std.testing.expect(tw_cmd == .task_with);
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(&state)), tw_cmd.task_with.ctx);
}
