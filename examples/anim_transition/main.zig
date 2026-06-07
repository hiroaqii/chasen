const std = @import("std");
const chasen = @import("chasen");
const anim = @import("chasen_anim");

// This example demonstrates app-owned integration between Chasen frame events
// and chasen-anim transition state.
//
// chasen-anim owns transition progress math, but it does not request frames or
// draw to a Surface. The app advances the transition on Event.frame and asks
// Chasen for exactly one more frame only while the transition is still active.
const transition_max_frame = 48;

const AnimTransition = struct {
    transition: anim.Transition = anim.Transition.init(.sweep, transition_max_frame),
    frame_index: u64 = 0,
    completed_count: u64 = 0,

    pub const Msg = union(enum) {
        frame: chasen.Frame,
        restart,
        quit,
    };

    pub fn init(self: *AnimTransition, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        ctx.frame().request();
    }

    pub fn update(self: *AnimTransition, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .frame => |frame| {
                self.frame_index = frame.index;
                _ = self.transition.step();
                if (self.transition.done()) {
                    self.completed_count += 1;
                } else {
                    ctx.frame().request();
                }
            },
            .restart => {
                self.transition = anim.Transition.init(.sweep, transition_max_frame);
                ctx.frame().request();
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const AnimTransition, sfc: *chasen.Surface) !void {
        sfc.clearAll();
        sfc.hideCursor();

        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("chasen-anim Transition Integration", .{ .bold = true });
        col.borrowText("r: restart  q: quit", .{ .fg = .gray });

        const progress = self.transition.progress();
        const state = if (self.transition.done()) "done; idle until restart" else "running";
        try col.print("frame event: {d}  transition frame: {d}/{d}", .{
            self.frame_index,
            self.transition.frame,
            self.transition.max_frame,
        });
        try col.print("kind: {s}  progress: {d}%  {s}", .{
            @tagName(self.transition.kind),
            percent(progress),
            state,
        });
        try col.print("completed transitions: {d}", .{self.completed_count});

        col.borrowText("", .{});
        drawProgressBar(sfc, 0, 7, sfc.size().width, progress);

        col.borrowText("", .{});
        col.borrowText("The app requests the next frame only while transition.done() is false.", .{ .dim = true });
        col.borrowText("When progress reaches 100%, no frame loop remains in flight.", .{ .dim = true });
    }

    pub fn handleEvent(self: *const AnimTransition, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .frame => |frame| .{ .frame = frame },
            .key_press => |key| switch (key.codepoint) {
                'r' => .restart,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }
};

fn drawProgressBar(sfc: *chasen.Surface, col: u16, row: u16, width: u16, progress: f32) void {
    if (width == 0) return;

    const label = "transition";
    _ = sfc.borrowTextAt(col, row, label, .{ .bold = true });
    if (row + 1 >= sfc.size().height) return;

    const bar_width = width -| 2;
    if (bar_width == 0) return;

    const filled: u16 = @intFromFloat(@round(progress * @as(f32, @floatFromInt(bar_width))));
    var i: u16 = 0;
    while (i < bar_width) : (i += 1) {
        const is_filled = i < filled;
        sfc.writeCell(col + i, row + 1, .{
            .char = .{ .grapheme = if (is_filled) "#" else "-", .width = 1 },
            .style = if (is_filled) .{ .fg = .{ .index = 2 }, .bold = true } else .{ .dim = true },
        });
    }
}

fn percent(progress: f32) u8 {
    return @intFromFloat(@round(progress * 100.0));
}

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, AnimTransition{});
}
