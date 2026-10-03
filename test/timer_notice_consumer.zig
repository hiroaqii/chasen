const std = @import("std");
const chasen = @import("chasen");

test "timer public Borrowed preserves explicit reference types and identity" {
    inline for (.{ []const u8, [:0]const u8, *const u64, *u64, *const [4:0]u8 }) |Ref| {
        const B = chasen.Borrowed(Ref);
        try std.testing.expect(B == chasen.runtime.Borrowed(Ref));
        try std.testing.expectEqual(@sizeOf(Ref), @sizeOf(B));
        try std.testing.expectEqual(@alignOf(Ref), @alignOf(B));
    }
    const text = chasen.Borrowed([]const u8).init("text");
    const sentinel = chasen.Borrowed([:0]const u8).init("text");
    try std.testing.expectEqualStrings("text", text.value);
    try std.testing.expectEqual(@as(u8, 0), sentinel.value[sentinel.value.len]);
    var count: u64 = 1;
    const borrow = chasen.Borrowed(*u64).init(&count);
    const copied = borrow;
    copied.value.* += 1;
    try std.testing.expectEqual(@as(u64, 2), count);
    try std.testing.expect(borrow.value == copied.value);
}

test "timer public vocabulary coexists with owned root messages" {
    const Msg = union(enum) {
        owned: []u8,
        unavailable: chasen.TimerStartError,

        pub const TimerNotice = struct { generation: u64, label: chasen.Borrowed([]const u8) };
        pub const undelivered_policy = .deinit;

        pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .owned => |bytes| allocator.free(bytes),
                .unavailable => {},
            }
        }
    };
    comptime chasen.runtime.validateUndeliveredPolicy(Msg);
    try std.testing.expect(chasen.TimerOutcome == chasen.runtime.TimerOutcome);
    try std.testing.expect(chasen.TimerStartError == chasen.runtime.TimerStartError);
    const notice: Msg.TimerNotice = .{ .generation = 7, .label = chasen.Borrowed([]const u8).init("tick") };
    try std.testing.expectEqualStrings("tick", notice.label.value);
    const fired: chasen.TimerOutcome = .fired;
    try std.testing.expect(fired == .fired);
    inline for (.{ error.OutOfMemory, error.ConcurrencyUnavailable }) |err| {
        const outcome: chasen.TimerOutcome = .{ .failed = err };
        try std.testing.expectEqual(err, outcome.failed);
    }
    var msg: Msg = .{ .owned = try std.testing.allocator.dupe(u8, "owned result") };
    chasen.runtime.deinitUndeliveredMessage(Msg, &msg, std.testing.allocator);
}
