const std = @import("std");
const vaxis = @import("vaxis");
const surface_mod = @import("surface.zig");
const Surface = surface_mod.Surface;
const ctx_mod = @import("ctx.zig");
const root = @import("root.zig");

fn InternalEvent(comptime Msg: type) type {
    return union(enum) {
        key_press: vaxis.Key,
        winsize: vaxis.Winsize,
        mouse: vaxis.Mouse,
        focus_in,
        focus_out,

        /// Async task result injected via postEvent.
        user_msg: Msg,
    };
}

pub fn run(comptime App: type, opts: root.RunOptions, initial_app: App) !void {
    const Msg = App.Msg;
    const Event = InternalEvent(Msg);
    const allocator = opts.allocator;
    const io = opts.io;

    // --- Terminal setup ---
    var tty_buf: [4096]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &tty_buf);
    defer tty.deinit();

    var vx = try vaxis.Vaxis.init(io, allocator, opts.env_map, .{});
    defer vx.deinit(allocator, tty.writer());

    // --- Event loop setup ---
    // Start the loop before querying the terminal. queryTerminal waits for
    // terminal capability responses, which are read and processed by the loop.
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);
    try loop.start();
    defer loop.stop();

    try vx.enterAltScreen(tty.writer());
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    if (!vx.state.in_band_resize) try loop.installResizeHandler();

    // --- Frame arena ---
    var frame_arena: std.heap.ArenaAllocator = .init(allocator);
    defer frame_arena.deinit();

    // --- App state ---
    var app = initial_app;
    var app_ctx: ctx_mod.Ctx(Msg) = .{};

    if (@hasDecl(App, "init")) {
        app.init(&app_ctx);
    }

    // Initial render
    try render(App, &vx, &frame_arena, &app, tty.writer());

    // --- Main loop ---
    while (!app_ctx.should_quit) {
        const event = try loop.nextEvent();
        var needs_render = false;

        switch (event) {
            .key_press => |key| {
                if (App.handleKey(key)) |msg| {
                    app.update(msg, &app_ctx);
                    needs_render = true;
                }
            },
            .winsize => |ws| {
                try vx.resize(allocator, tty.writer(), ws);
                needs_render = true;
            },
            .user_msg => |msg| {
                app.update(msg, &app_ctx);
                needs_render = true;
            },
            .mouse => {},
            .focus_in => {},
            .focus_out => {},
        }

        if (needs_render) {
            try render(App, &vx, &frame_arena, &app, tty.writer());
        }
    }
}

fn render(
    comptime App: type,
    vx: *vaxis.Vaxis,
    frame_arena: *std.heap.ArenaAllocator,
    app: *const App,
    writer: *std.Io.Writer,
) !void {
    _ = frame_arena.reset(.retain_capacity);
    const win = vx.window();
    win.clear();
    var sfc: Surface = .{
        .window = win,
        .arena = frame_arena.allocator(),
    };
    app.view(&sfc);
    try vx.render(writer);
}

test "InternalEvent instantiation" {
    const TestMsg = union(enum) { hello, value: u32 };
    const Event = InternalEvent(TestMsg);

    const ev: Event = .{ .user_msg = .hello };
    try std.testing.expect(ev == .user_msg);

    const key_ev: Event = .{ .key_press = .{ .codepoint = 'a' } };
    try std.testing.expect(key_ev == .key_press);
}
