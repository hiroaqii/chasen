const std = @import("std");
const chasen = @import("chasen");

const Counter = struct {
    count: i32 = 0,

    pub const Msg = union(enum) {
        increment,
        decrement,
        quit,
    };

    pub fn update(self: *Counter, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .increment => self.count += 1,
            .decrement => self.count -= 1,
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const Counter, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.text("Counter Example", .{ .bold = true });
        try col.textf("Count: {d}", .{self.count});
        col.text("Press +/- to change, q to quit", .{ .fg = .gray });
    }

    pub fn handleKey(key: chasen.Key) ?Msg {
        return switch (key.codepoint) {
            '+', '=' => .increment,
            '-' => .decrement,
            'q' => .quit,
            else => null,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, Counter{});
}
