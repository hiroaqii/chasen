const std = @import("std");
const chasen = @import("chasen");

// This example demonstrates frame-driven rendering.
//
// `ctx.frame().request()` does not start a permanent timer. It asks Chasen to
// deliver one future `Event.frame`. If the app wants continuous animation, it
// must request the next frame after handling the current one.
const Animation = struct {
    running: bool = true,
    frame_index: u64 = 0,
    last_delta_ms: u64 = 0,

    pub const Msg = union(enum) {
        frame: chasen.Frame,
        toggle,
        quit,
    };

    pub fn init(self: *Animation, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        // Kick off the first frame. Without this, the app stays idle until
        // terminal input arrives.
        ctx.frame().request();
    }

    pub fn update(self: *Animation, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .frame => |frame| {
                self.frame_index = frame.index;
                self.last_delta_ms = frame.delta_ns / std.time.ns_per_ms;
                // Request exactly one more frame while running. When this is
                // skipped, the runtime returns to event-driven idle mode.
                if (self.running) ctx.frame().request();
            },
            .toggle => {
                self.running = !self.running;
                // Resuming from pause needs a fresh frame request because no
                // frame future is kept alive while paused.
                if (self.running) ctx.frame().request();
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const Animation, sfc: *chasen.Surface) !void {
        sfc.clearAll();
        sfc.hideCursor();

        const size = sfc.size();
        _ = sfc.borrowTextAt(0, 0, "requestFrame animation", .{ .bold = true });

        const status = if (self.running) "running" else "paused";
        // Formatted text created during view should use printAt so the
        // temporary string is stored in the frame arena.
        _ = try sfc.printAt(
            0,
            1,
            .{ .fg = .gray },
            "frame: {d}  delta: {d}ms  {s}",
            .{ self.frame_index, self.last_delta_ms, status },
        );
        _ = sfc.borrowTextAt(0, 2, "space: pause/resume  q: quit", .{ .dim = true });

        if (size.width == 0 or size.height < 4) return;

        // Draw a simple one-row track and move the marker by frame index.
        const track_row: u16 = 3;
        var col: u16 = 0;
        while (col < size.width) : (col += 1) {
            sfc.writeCell(col, track_row, .{
                .char = .{ .grapheme = "-", .width = 1 },
                .style = .{ .dim = true },
            });
        }

        const span: u64 = @intCast(size.width);
        const marker_col: u16 = @intCast(self.frame_index % span);
        sfc.writeCell(marker_col, track_row, .{
            .char = .{ .grapheme = "o", .width = 1 },
            .style = .{ .bold = true, .fg = .{ .index = 2 } },
        });
    }

    pub fn handleEvent(self: *const Animation, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            // The runtime delivers requested frames as terminal events. The
            // app maps that event into its own Msg, then update owns the state
            // transition and decides whether to request another frame.
            .frame => |frame| .{ .frame = frame },
            .key_press => |key| switch (key.codepoint) {
                ' ' => .toggle,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, Animation{});
}
