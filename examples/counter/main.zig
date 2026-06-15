const std = @import("std");
const chasen = @import("chasen");

// Minimal Event -> Msg -> update -> Surface drawing example.
const Counter = struct {
    count: i32 = 0,

    pub const Msg = union(enum) {
        increment,
        decrement,
        quit,
    };

    pub fn handleEvent(self: *const Counter, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                '+', '=' => .increment,
                '-' => .decrement,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *Counter, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .increment => self.count += 1,
            .decrement => self.count -= 1,
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const Counter, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("Counter Example", .{ .bold = true });
        try col.print("Count: {d}", .{self.count});
        col.borrowText("Press +/- to change, q to quit", .{ .fg = .gray });
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, Counter{});
}
