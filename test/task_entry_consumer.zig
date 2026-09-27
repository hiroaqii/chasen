const std = @import("std");
const chasen = @import("chasen");

// This module imports the public package, as a consuming application does.
test "task public consumer transfers an entry independently of the pending slot" {
    const Msg = struct { bytes: []u8 };
    const Task = struct {
        bytes: ?[]u8,
        cleaned: *usize,

        fn run(self: *@This(), _: std.mem.Allocator, _: std.Io) std.Io.Cancelable!Msg {
            const bytes = self.bytes.?;
            self.bytes = null;
            return .{ .bytes = bytes };
        }
        fn failed(_: *@This(), _: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            unreachable;
        }
        fn cleanup(self: *@This(), allocator: std.mem.Allocator) void {
            self.cleaned.* += 1;
            if (self.bytes) |bytes| allocator.free(bytes);
            allocator.destroy(self);
        }
    };
    const Entry = chasen.Ctx(Msg).TaskEntry;
    // Reintroducing the old raw public field would reopen the consuming bypass.
    try std.testing.expect(!@hasField(Entry, "callbacks"));
    try std.testing.expect(!@hasField(Entry, "context"));

    const allocator = std.testing.allocator;
    var cleaned: usize = 0;
    var tc: chasen.testing.TestCtx(Msg) = .{};
    defer tc.resetTransient();
    const first = try allocator.create(Task);
    first.* = .{ .bytes = try allocator.dupe(u8, "moved result"), .cleaned = &cleaned };
    _ = try tc.ctx.task().spawnOwned(first, .{ .run = Task.run, .failed = Task.failed, .cleanup = Task.cleanup });
    // Move the value out before the pending slot is overwritten by another task.
    const moved = tc.ctx.takePendingTasks()[0];
    const second = try allocator.create(Task);
    second.* = .{ .bytes = try allocator.dupe(u8, "discarded context"), .cleaned = &cleaned };
    _ = try tc.ctx.task().spawnOwned(second, .{ .run = Task.run, .failed = Task.failed, .cleanup = Task.cleanup });

    const result = try moved.run(allocator, std.testing.io);
    defer allocator.free(result.bytes);
    try std.testing.expectEqualStrings("moved result", result.bytes);
    try std.testing.expectEqual(@as(usize, 1), cleaned);
    tc.resetTransient();
    try std.testing.expectEqual(@as(usize, 2), cleaned);
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTaskCount());
}
