const std = @import("std");
const timer = @import("timer.zig");

/// One allocation for a typed stable node and its copied ID. Requests owns it
/// until detachment; a running node must be joined before destruction.
pub fn TimerEntry(comptime Msg: type) type {
    return struct {
        const Self = @This();
        id: []const u8,
        duration_ns: u64,
        notification: timer.Notification(Msg),
        future: std.Io.Future(void) = undefined,
        completed: std.atomic.Value(bool) = .init(false),

        pub fn create(allocator: std.mem.Allocator, id: []const u8, duration_ns: u64, notice: timer.Notice(Msg), notify: timer.Notify(Msg)) !*Self {
            const size = std.math.add(usize, @sizeOf(Self), id.len) catch return error.OutOfMemory;
            const bytes = try allocator.alignedAlloc(u8, .of(Self), size);
            const node: *Self = @ptrCast(bytes.ptr);
            const owned_id = bytes[@sizeOf(Self)..];
            @memcpy(owned_id, id);
            node.* = .{
                .id = owned_id,
                .duration_ns = duration_ns,
                .notification = .{ .notice = notice, .notify = notify },
            };
            return node;
        }

        pub fn destroy(self: *Self, allocator: std.mem.Allocator) void {
            // The successful create checked this addition. No callback/drop is
            // involved: only node/ID storage belongs to the timer.
            const size = @sizeOf(Self) + self.id.len;
            const bytes: [*]align(@alignOf(Self)) u8 = @ptrCast(self);
            allocator.free(bytes[0..size]);
        }
    };
}

test "timer node checks ID size overflow before allocation or copying" {
    const Msg = enum { unused };
    const Callback = struct {
        fn notify(_: void, _: timer.TimerOutcome, _: std.mem.Allocator) ?Msg {
            return null;
        }
    };
    const byte: u8 = 0;
    const id = @as([*]const u8, @ptrCast(&byte))[0..std.math.maxInt(usize)];
    try std.testing.expectError(error.OutOfMemory, TimerEntry(Msg).create(std.testing.failing_allocator, id, 0, {}, Callback.notify));
}

test "timer node stores large aligned notices and ID in one allocation" {
    const Msg = enum {
        unused,
        pub const TimerNotice = struct { bytes: [513]u8, stamp: u64 align(64) };
        fn notify(_: TimerNotice, _: timer.TimerOutcome, _: std.mem.Allocator) ?@This() {
            return null;
        }
    };
    var counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const Entry = TimerEntry(Msg);
    var id = "temporary".*;
    const entry = try Entry.create(counter.allocator(), &id, std.math.maxInt(u64), .{ .bytes = @splat(7), .stamp = 9 }, Msg.notify);
    try std.testing.expectEqual(@as(usize, 1), counter.allocations);
    try std.testing.expectEqual(@sizeOf(Entry) + id.len, counter.allocated_bytes);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(entry) % @alignOf(Entry));
    id[0] = 'x';
    try std.testing.expectEqualStrings("temporary", entry.id);
    try std.testing.expectEqual(@as(u8, 7), entry.notification.notice.bytes[512]);
    entry.destroy(counter.allocator());
    try std.testing.expectEqual(counter.allocated_bytes, counter.freed_bytes);
}
