const std = @import("std");
const ctx_mod = @import("ctx.zig");

/// Lightweight test wrapper around `Ctx(Msg)`.
///
/// Provides a properly initialised `Ctx` for unit-testing `update`
/// functions without a real terminal or event loop.
///
/// Phase A does not initialise `_io`.
/// Tests that call `ctx.now()` or `ctx.io()` require a future
/// MockIo-backed TestCtx.
///
/// Usage:
/// ```
/// var tc: chasen.testing.TestCtx(App.Msg) = .{};
/// try app.update(.some_msg, &tc.ctx);
/// try std.testing.expect(tc.ctx.should_quit);
/// ```
pub fn TestCtx(comptime Msg: type) type {
    return struct {
        ctx: ctx_mod.Ctx(Msg) = .{ ._allocator = std.testing.allocator },

        /// Reset per-update transient state so this wrapper can be
        /// reused across multiple `update` calls in one test.
        ///
        /// Clears pending side effects and `redraw_suppressed`.
        /// Preserves `should_quit` and allocator.
        pub fn resetTransient(self: *@This()) void {
            self.ctx.pending_tasks_len = 0;
            self.ctx.pending_tasks_with_len = 0;
            self.ctx.pending_ticks_len = 0;
            self.ctx.pending_everys_len = 0;
            self.ctx.pending_cancels_len = 0;
            self.ctx.redraw_suppressed = false;
            self.ctx.frame_requested = false;
        }
    };
}

// --- Tests ---

test "TestCtx initialises with valid allocator and default state" {
    var tc: TestCtx(TestMsg) = .{};
    try std.testing.expectEqual(false, tc.ctx.should_quit);
    try std.testing.expectEqual(@as(u8, 0), tc.ctx.pending_tasks_len);

    // _allocator is usable
    const ally = tc.ctx.allocator();
    const ptr = try ally.create(u32);
    defer ally.destroy(ptr);
    ptr.* = 42;
    try std.testing.expectEqual(@as(u32, 42), ptr.*);
}

test "resetTransient clears pending queues and redraw_suppressed" {
    var tc: TestCtx(TestMsg) = .{};

    // Accumulate some state
    const task = &struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .inc;
        }
    }.run;
    try tc.ctx.spawn(task);
    try tc.ctx.tick("t1", 1_000, .inc);
    try tc.ctx.every("e1", 2_000, .dec);
    tc.ctx.cancelTimer("x");
    tc.ctx.suppressRedraw();
    tc.ctx.requestFrame();

    try std.testing.expectEqual(@as(u8, 1), tc.ctx.pending_tasks_len);
    try std.testing.expectEqual(@as(u8, 1), tc.ctx.pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 1), tc.ctx.pending_everys_len);
    try std.testing.expectEqual(@as(u8, 1), tc.ctx.pending_cancels_len);
    try std.testing.expectEqual(true, tc.ctx.redraw_suppressed);
    try std.testing.expectEqual(true, tc.ctx.frame_requested);

    tc.resetTransient();

    try std.testing.expectEqual(@as(u8, 0), tc.ctx.pending_tasks_len);
    try std.testing.expectEqual(@as(u8, 0), tc.ctx.pending_tasks_with_len);
    try std.testing.expectEqual(@as(u8, 0), tc.ctx.pending_ticks_len);
    try std.testing.expectEqual(@as(u8, 0), tc.ctx.pending_everys_len);
    try std.testing.expectEqual(@as(u8, 0), tc.ctx.pending_cancels_len);
    try std.testing.expectEqual(false, tc.ctx.redraw_suppressed);
    try std.testing.expectEqual(false, tc.ctx.frame_requested);
}

test "resetTransient preserves should_quit" {
    var tc: TestCtx(TestMsg) = .{};

    tc.ctx.quit();
    try std.testing.expectEqual(true, tc.ctx.should_quit);

    tc.resetTransient();
    try std.testing.expectEqual(true, tc.ctx.should_quit);
}

test "update call pattern with a counter app" {
    // Minimal counter app to demonstrate the test pattern.
    const Counter = struct {
        count: i32 = 0,

        const Msg = union(enum) { inc, dec, quit_msg };

        fn update(self: *@This(), msg: Msg, c: *ctx_mod.Ctx(Msg)) !void {
            switch (msg) {
                .inc => self.count += 1,
                .dec => self.count -= 1,
                .quit_msg => c.quit(),
            }
        }
    };

    var app: Counter = .{};
    var tc: TestCtx(Counter.Msg) = .{};

    try app.update(.inc, &tc.ctx);
    try std.testing.expectEqual(@as(i32, 1), app.count);

    try app.update(.inc, &tc.ctx);
    try std.testing.expectEqual(@as(i32, 2), app.count);

    try app.update(.dec, &tc.ctx);
    try std.testing.expectEqual(@as(i32, 1), app.count);

    try app.update(.quit_msg, &tc.ctx);
    try std.testing.expectEqual(true, tc.ctx.should_quit);
}

const TestMsg = union(enum) { inc, dec };
