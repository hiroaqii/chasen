const std = @import("std");
const chasen = @import("chasen");

// A small selectable menu. This is intentionally simple, but it demonstrates
// the full Chasen app shape: Event -> Msg -> update -> Surface drawing.
const Selection = struct {
    selected: usize = 0,

    const items = [_][]const u8{
        "zig",
        "go",
        "rust",
    };

    pub const Msg = union(enum) {
        move_up,
        move_down,
        quit,
    };

    pub fn handleEvent(self: *const Selection, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| keyToMsg(key),
            else => null,
        };
    }

    pub fn update(self: *Selection, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .move_up => {
                if (self.selected > 0) self.selected -= 1;
            },
            .move_down => {
                if (self.selected + 1 < items.len) self.selected += 1;
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const Selection, surface: *chasen.Surface) !void {
        surface.clearAll();

        _ = surface.borrowTextAt(0, 0, "Select a language", .{ .bold = true });

        for (items, 0..) |label, index| {
            const marker = if (index == self.selected) "> " else "  ";
            const style: chasen.TextStyle = if (index == self.selected)
                .{ .bold = true }
            else
                .{};

            _ = try surface.printAt(0, @intCast(index + 2), style, "{s}{s}", .{ marker, label });
        }

        _ = try surface.printAt(0, 6, .{ .fg = .gray }, "selected: {s}", .{items[self.selected]});
        _ = surface.borrowTextAt(0, 8, "↑/↓/j/k: move  q: quit", .{ .fg = .gray });
    }
};

fn keyToMsg(key: chasen.Key) ?Selection.Msg {
    if (key.matches(chasen.Key.down, .{}) or key.matches('j', .{})) return .move_down;
    if (key.matches(chasen.Key.up, .{}) or key.matches('k', .{})) return .move_up;
    if (key.matches('q', .{})) return .quit;
    return null;
}

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, Selection{});
}
