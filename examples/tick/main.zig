const std = @import("std");
const chasen = @import("chasen");

const reminder_id = "reminder";
const reminder_delay_ns: u64 = 2 * std.time.ns_per_s;

// This example demonstrates `ctx.timer().tick`: a one-shot timer that sends one future
// app message. Re-scheduling with the same id replaces the pending/running
// timer, and `ctx.timer().cancel` stops it before it fires.
const TickDemo = struct {
    scheduled: bool = false,
    scheduled_count: u32 = 0,
    fired_count: u32 = 0,
    cancelled_count: u32 = 0,
    last_event: []const u8 = "Press s to schedule a one-shot tick.",

    pub const Msg = union(enum) {
        pub const undelivered_policy = .plain;

        schedule,
        fired,
        cancel,
        quit,
    };

    pub fn handleEvent(self: *const TickDemo, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                's' => .schedule,
                'c' => .cancel,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *TickDemo, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .schedule => {
                self.scheduled = true;
                self.scheduled_count += 1;
                self.last_event = "Scheduled. Press s again to replace it.";
                try ctx.timer().tick(reminder_id, reminder_delay_ns, .fired);
            },
            .fired => {
                self.scheduled = false;
                self.fired_count += 1;
                self.last_event = "Tick fired once.";
            },
            .cancel => {
                if (self.scheduled) {
                    self.cancelled_count += 1;
                    self.last_event = "Cancelled the scheduled tick.";
                } else {
                    self.last_event = "No scheduled tick to cancel.";
                }
                self.scheduled = false;
                try ctx.timer().cancel(reminder_id);
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const TickDemo, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("Tick Example", .{ .bold = true });
        col.borrowText("s: schedule/replace  c: cancel  q: quit", .{ .fg = .gray });

        const status = if (self.scheduled)
            "scheduled: one message will arrive in about 2 seconds"
        else
            "scheduled: none";
        col.borrowText(status, .{});

        try col.print("scheduled: {d}  fired: {d}  cancelled: {d}", .{
            self.scheduled_count,
            self.fired_count,
            self.cancelled_count,
        });
        col.borrowText(self.last_event, .{ .dim = true });
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, TickDemo{});
}
