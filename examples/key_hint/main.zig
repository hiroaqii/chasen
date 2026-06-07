const std = @import("std");
const chasen = @import("chasen");

// This example demonstrates the low-level key hint drawing helper. It is not
// tied to footers: the same item list can be drawn in a panel, overlay, status
// row, or the bottom of the screen.
const KeyHintExample = struct {
    pub const Msg = union(enum) {
        quit,
    };

    pub fn view(self: *const KeyHintExample, sfc: *chasen.Surface) !void {
        _ = self;
        sfc.clearAll();

        _ = sfc.borrowTextAt(0, 0, "Key Hint Example", .{ .bold = true });
        _ = sfc.borrowTextAt(0, 2, "One-line hints use item-boundary ellipsis when they do not fit:", .{});

        _ = chasen.key_hint.draw(sfc, 0, 4, &.{
            chasen.key_hint.item("Up/Down/j/k", "move"),
            chasen.key_hint.item("Enter", "open"),
            chasen.key_hint.item("/", "filter"),
            chasen.key_hint.item("Esc/q", "quit"),
        }, .{
            .style = .{ .dim = true },
            .key_style = .{ .bold = true },
        });

        _ = sfc.borrowTextAt(0, 7, "Two-line hints wrap at item boundaries:", .{});

        _ = chasen.key_hint.draw(sfc, 0, 9, &.{
            chasen.key_hint.item("Up/Down/j/k", "move"),
            chasen.key_hint.item("Enter", "detail"),
            chasen.key_hint.item("/", "filter"),
            chasen.key_hint.item("s", "sort"),
            chasen.key_hint.item("r", "refresh"),
            chasen.key_hint.item("q", "quit"),
        }, .{
            .style = .{ .dim = true },
            .key_style = .{ .bold = true },
            .max_lines = 2,
            .overflow = .wrap,
        });

        _ = sfc.borrowTextAt(0, 13, "q: quit", .{ .fg = .gray });
    }

    pub fn handleEvent(self: *const KeyHintExample, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *KeyHintExample, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        switch (msg) {
            .quit => ctx.quit(),
        }
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, KeyHintExample{});
}
