const std = @import("std");
const chasen = @import("chasen");

// This example demonstrates the Surface drawing rules that component packages
// rely on: borrowed text lifetimes, frame-owned formatted text, child clipping,
// and cursor coordinates inside a child surface.
const SurfaceBasics = struct {
    pub const Msg = union(enum) {
        quit,
    };

    pub fn view(self: *const SurfaceBasics, sfc: *chasen.Surface) !void {
        _ = self;
        sfc.clearAll();

        _ = sfc.textAt(0, 0, "Surface Basics", .{ .bold = true });
        _ = sfc.textAt(0, 1, "q: quit", .{ .fg = .gray });

        // Static strings and app/component-owned buffers are valid borrowed
        // text for textAt because they outlive the current render frame.
        _ = sfc.textAt(0, 3, "textAt: borrowed static text", .{});

        // Formatted text created during view should use printAt. It stores the
        // formatted bytes in the frame allocator before drawing.
        _ = try sfc.printAt(0, 4, .{}, "printAt: frame-owned number {d}", .{42});

        // If a temporary string must be passed through a borrowed API or view
        // option, copy it into the frame allocator first.
        var tmp: [64]u8 = undefined;
        const temp_title = try std.fmt.bufPrint(&tmp, "copyText: {s}", .{"safe option text"});
        const copied_title = try sfc.copyText(temp_title);
        drawBorrowedLabel(sfc, 0, 5, copied_title);

        // Do not pass a stack-backed bufPrint slice directly to textAt:
        //
        //   const text = try std.fmt.bufPrint(&tmp, "bad: {d}", .{42});
        //   _ = sfc.textAt(0, 6, text, .{}); // invalid lifetime

        const panel = chasen.Rect{ .col = 0, .row = 8, .width = 30, .height = 6 };
        sfc.fill(panel, .{ .char = .{ .grapheme = ".", .width = 1 }, .style = .{ .dim = true } });

        var child = sfc.child(.{
            .col = panel.col + 2,
            .row = panel.row + 1,
            .width = 18,
            .height = 3,
        });

        // Child coordinates are local to the child rectangle. This text is
        // clipped by the child width; it does not draw over the parent.
        _ = child.textAt(0, 0, "child surface clips this long line", .{ .fg = .{ .index = 6 } });
        _ = child.textAt(0, 1, "local row 1", .{});

        // showCursor also uses local child coordinates. This places the
        // terminal cursor at parent (panel.col + 2 + 4, panel.row + 1 + 2).
        child.showCursor(4, 2);

        _ = sfc.textAt(0, 15, "child.showCursor(4, 2) is relative to the child", .{ .dim = true });
    }

    pub fn handleEvent(self: *const SurfaceBasics, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *SurfaceBasics, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        switch (msg) {
            .quit => ctx.quit(),
        }
    }
};

fn drawBorrowedLabel(surface: *chasen.Surface, col: u16, row: u16, label: []const u8) void {
    _ = surface.textAt(col, row, label, .{ .fg = .{ .index = 2 } });
}

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, SurfaceBasics{});
}
