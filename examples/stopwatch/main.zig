const std = @import("std");
const chasen = @import("chasen");

// Refresh the display at roughly 60 frames per second. The stopwatch measures
// elapsed time from the monotonic clock, so this interval only controls how
// often the UI is redrawn.
const target_fps: u64 = 60;
const refresh_interval_ns: u64 = std.time.ns_per_s / target_fps;

// std.Io.Timestamp stores nanoseconds as i96, so keep stopwatch durations in
// the same type to avoid lossy casts during elapsed-time calculations.
const Nanoseconds = i96;

const Stopwatch = struct {
    running: bool = false,
    started_at_ns: Nanoseconds = 0,
    accumulated_ns: Nanoseconds = 0,
    display_ns: Nanoseconds = 0,
    refresh_unavailable: bool = false,

    pub const Msg = union(enum) {
        pub const undelivered_policy = .plain;

        tick,
        refresh_failed,
        toggle,
        reset,
        quit,
    };

    pub fn init(self: *Stopwatch, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        try ctx.timer().every("refresh", refresh_interval_ns, {}, refreshNotice);
    }

    fn refreshNotice(_: void, outcome: chasen.TimerOutcome, _: std.mem.Allocator) ?Msg {
        return switch (outcome) {
            .fired => .tick,
            .failed => .refresh_failed,
        };
    }

    pub fn handleEvent(self: *const Stopwatch, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                ' ' => .toggle,
                'r' => .reset,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *Stopwatch, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .refresh_failed => self.refresh_unavailable = true,
            .tick => if (self.running) {
                const now = ctx.now().nanoseconds;
                self.display_ns = self.accumulated_ns + (now - self.started_at_ns);
            },
            .toggle => {
                const now = ctx.now().nanoseconds;
                if (self.running) {
                    self.accumulated_ns += now - self.started_at_ns;
                    self.display_ns = self.accumulated_ns;
                } else {
                    self.started_at_ns = now;
                    self.display_ns = self.accumulated_ns;
                }
                self.running = !self.running;
            },
            .reset => {
                self.running = false;
                self.started_at_ns = 0;
                self.accumulated_ns = 0;
                self.display_ns = 0;
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const Stopwatch, sfc: *chasen.Surface) !void {
        const total_ms: u64 = @intCast(@divFloor(self.display_ns, 1_000_000));
        const minutes = total_ms / 60_000;
        const seconds = (total_ms / 1_000) % 60;
        const millis = total_ms % 1_000;

        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("Stopwatch", .{ .bold = true });
        try col.print("{d:0>2}:{d:0>2}.{d:0>3}", .{ minutes, seconds, millis });

        const status: []const u8 = if (self.running) "Running" else "Stopped";
        col.borrowText(status, .{ .fg = .gray });
        if (self.refresh_unavailable) col.borrowText("Automatic refresh unavailable; key presses still update the display.", .{ .fg = .gray });
        col.borrowText("space: start/stop  r: reset  q: quit", .{ .dim = true });
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, Stopwatch{});
}
