const std = @import("std");
const chasen = @import("chasen");

const Stopwatch = struct {
    elapsed_ds: u64 = 0, // deciseconds (1/10 sec)
    running: bool = false,

    pub const Msg = union(enum) {
        tick,
        toggle,
        reset,
        quit,
    };

    pub fn init(self: *Stopwatch, ctx: *chasen.Ctx(Msg)) void {
        _ = self;
        ctx.every(100_000_000, .tick); // 100ms
    }

    pub fn update(self: *Stopwatch, msg: Msg, ctx: *chasen.Ctx(Msg)) void {
        switch (msg) {
            .tick => if (self.running) {
                self.elapsed_ds += 1;
            },
            .toggle => self.running = !self.running,
            .reset => {
                self.elapsed_ds = 0;
                self.running = false;
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const Stopwatch, sfc: *chasen.Surface) void {
        const total_ds = self.elapsed_ds;
        const minutes = total_ds / 600;
        const seconds = (total_ds / 10) % 60;
        const tenths = total_ds % 10;

        var col = sfc.column(.{ .gap = 1 });
        col.text("Stopwatch", .{ .bold = true });
        col.textf("{d:0>2}:{d:0>2}.{d}", .{ minutes, seconds, tenths });

        const status: []const u8 = if (self.running) "Running" else "Stopped";
        col.text(status, .{ .fg = .gray });
        col.text("space: start/stop  r: reset  q: quit", .{ .dim = true });
    }

    pub fn handleKey(key: chasen.Key) ?Msg {
        return switch (key.codepoint) {
            ' ' => .toggle,
            'r' => .reset,
            'q' => .quit,
            else => null,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, Stopwatch{});
}
