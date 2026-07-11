const std = @import("std");
const chasen = @import("chasen");

// Demonstrates using Rect values to split the root Surface into app-owned
// regions. Chasen does not provide a layout engine here; the app computes the
// rectangles it needs and draws each region through a child Surface.
//
// NOTE:
//   This example hand-writes Rect values to show the low-level Surface API.
//   For more complex layouts, use chasen-ui.layout helpers to compute these
//   Rect values, then pass the resulting regions to Surface.child as shown
//   below.
const SurfaceLayout = struct {
    pub const Msg = union(enum) {
        pub const undelivered_policy = .plain;

        quit,
    };

    pub fn handleEvent(self: *const SurfaceLayout, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *SurfaceLayout, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        switch (msg) {
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const SurfaceLayout, surface: *chasen.Surface) !void {
        _ = self;
        surface.clearAll();

        const size = surface.size();
        if (size.width < 36 or size.height < 12) {
            _ = surface.borrowTextAt(0, 0, "Surface Layout", .{ .bold = true });
            _ = surface.borrowTextAt(0, 2, "Please enlarge the terminal.", .{ .fg = .gray });
            return;
        }

        const header = chasen.Rect{ .col = 0, .row = 0, .width = size.width, .height = 3 };
        const footer = chasen.Rect{ .col = 0, .row = size.height - 2, .width = size.width, .height = 2 };
        const sidebar_width: u16 = if (size.width > 70) 22 else 16;
        const body_height = size.height - header.height - footer.height;
        const sidebar = chasen.Rect{ .col = 0, .row = header.height, .width = sidebar_width, .height = body_height };
        const content = chasen.Rect{
            .col = sidebar.width + 1,
            .row = header.height,
            .width = size.width - sidebar.width - 1,
            .height = body_height,
        };

        drawRegion(surface, header, "header", .{ .index = 4 });
        drawRegion(surface, sidebar, "sidebar", .{ .index = 6 });
        drawRegion(surface, content, "content", .{ .index = 2 });
        drawRegion(surface, footer, "footer", .{ .index = 8 });

        var header_surface = surface.child(header);
        _ = header_surface.borrowTextAt(1, 1, "Surface Layout", .{ .bold = true });

        var sidebar_surface = surface.child(sidebar);
        _ = sidebar_surface.borrowTextAt(1, 1, "Menu", .{ .bold = true });
        _ = sidebar_surface.borrowTextAt(1, 3, "- Home", .{});
        _ = sidebar_surface.borrowTextAt(1, 4, "- Settings", .{});
        _ = sidebar_surface.borrowTextAt(1, 5, "- Help", .{});

        var content_surface = surface.child(content);
        _ = content_surface.borrowTextAt(1, 1, "Content", .{ .bold = true });
        _ = content_surface.borrowTextAt(1, 3, "This text is drawn at child-local (1, 3).", .{});
        _ = content_surface.borrowTextAt(1, 5, "Long text is clipped by the content Rect instead of leaking into other regions.", .{ .fg = .gray });

        var footer_surface = surface.child(footer);
        _ = footer_surface.borrowTextAt(1, 0, "q: quit", .{ .fg = .gray });
    }
};

fn drawRegion(surface: *chasen.Surface, rect: chasen.Rect, label: []const u8, color: chasen.Color) void {
    surface.fill(rect, .{
        .char = .{ .grapheme = " ", .width = 1 },
        .style = .{ .bg = color },
    });

    var child = surface.child(rect);
    _ = child.borrowTextAt(1, 0, label, .{ .fg = .{ .index = 0 }, .bold = true });
}

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, SurfaceLayout{});
}
