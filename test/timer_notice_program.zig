const std = @import("std");
const chasen = @import("chasen");

// A finite nested value exercises recursive notice validation in a real Program,
// including an explicit borrow and an independently owned root message.
fn Value(comptime depth: usize) type {
    if (depth == 0) return struct {
        numbers: [32]u64 = @splat(0),
        label: chasen.Borrowed([]const u8) = .init("timer"),
    };
    return struct {
        generation: u64 = 0,
        child: Value(depth - 1) = .{},
    };
}

const App = struct {
    pub const Msg = union(enum) {
        done,
        owned: []u8,

        pub const TimerNotice = union(enum) { idle, value: Value(32) };
        pub const undelivered_policy = .deinit;

        pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
            switch (self.*) {
                .owned => |bytes| allocator.free(bytes),
                .done => {},
            }
        }
    };

    pub fn init(_: *App, ctx: *chasen.Ctx(Msg)) !void {
        try ctx.timer().tick("composite", 0, .{ .value = .{} }, notify);
    }

    fn notify(_: Msg.TimerNotice, outcome: chasen.TimerOutcome, _: std.mem.Allocator) ?Msg {
        return switch (outcome) {
            .fired, .failed => .done,
        };
    }

    pub fn update(_: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        var delivered = msg;
        delivered.deinitUndelivered(ctx.allocator());
        ctx.quit();
    }

    pub fn view(_: *const App, _: *chasen.Surface) !void {}
};

// This executable is compiled but never run by the test gate, so it uses the
// production terminal types without opening a terminal during automated tests.
pub fn main(init: std.process.Init) !void {
    try chasen.run(init, App{});
}
