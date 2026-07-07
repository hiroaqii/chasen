const std = @import("std");
const vaxis = @import("vaxis");
const ctx_mod = @import("ctx.zig");
const surface_mod = @import("surface.zig");

/// Headless `Surface` test fixture backed by a libvaxis `Screen`.
///
/// Use this from core and component tests that need to verify rendered cells
/// without starting a terminal runtime.
///
/// `TestSurface` must be initialized in its final storage location. It owns a
/// backing screen, and `surface` stores a window that points into that screen.
/// Declare the value first, then call `init` on it; do not treat `init` as a
/// value-returning factory.
///
/// Usage:
/// ```
/// var ts: chasen.testing.TestSurface = undefined;
/// try ts.init(20, 4);
/// defer ts.deinit();
///
/// _ = ts.surface.borrowTextAt(0, 0, "ok", .{});
/// try ts.expectSnapshot("ok                  \n                    \n                    \n                    ");
/// ```
pub const TestSurface = struct {
    allocator: std.mem.Allocator,
    screen: vaxis.Screen,
    arena: std.heap.ArenaAllocator,
    surface: surface_mod.Surface,

    /// Initialize this fixture in its final memory location.
    ///
    /// `Surface` stores a window that points at `screen`, so `TestSurface`
    /// should not be moved after `init`.
    pub fn init(self: *TestSurface, width: u16, height: u16) !void {
        try self.initWithAllocator(width, height, std.testing.allocator);
    }

    /// Initialize this fixture with an explicit allocator.
    ///
    /// This is useful for executable benchmarks that want the same headless
    /// surface fixture without depending on `std.testing.allocator`.
    pub fn initWithAllocator(self: *TestSurface, width: u16, height: u16, allocator: std.mem.Allocator) !void {
        const screen = try vaxis.Screen.init(allocator, .{
            .cols = width,
            .rows = height,
            .x_pixel = 0,
            .y_pixel = 0,
        });

        self.* = .{
            .allocator = allocator,
            .screen = screen,
            .arena = .init(allocator),
            .surface = surface_mod.Surface.initVaxis(
                .{
                    .x_off = 0,
                    .y_off = 0,
                    .parent_x_off = 0,
                    .parent_y_off = 0,
                    .width = width,
                    .height = height,
                    .screen = undefined,
                },
                undefined,
                null,
            ),
        };
        self.screen.width_method = .unicode;
        self.bind();
    }

    /// Release resources owned by this fixture.
    pub fn deinit(self: *TestSurface) void {
        const allocator = self.allocator;
        self.arena.deinit();
        self.screen.deinit(allocator);
        self.* = undefined;
    }

    fn bind(self: *TestSurface) void {
        self.surface.bindVaxisScreenForTesting(&self.screen);
        self.surface.arena = self.arena.allocator();
    }

    /// Return the grapheme stored at one cell, or a space for an empty/default
    /// cell.
    pub fn cellText(self: *const TestSurface, col: u16, row: u16) []const u8 {
        const cell = self.surface.readCell(col, row) orelse return " ";
        if (cell.char.grapheme.len == 0) return " ";
        return cell.char.grapheme;
    }

    /// Assert that one cell contains `expected`.
    pub fn expectCellText(self: *const TestSurface, col: u16, row: u16, expected: []const u8) !void {
        try std.testing.expectEqualStrings(expected, self.cellText(col, row));
    }

    /// Create a row-major text snapshot of the current surface contents.
    ///
    /// Rows are separated with `\n`. The final row has no trailing newline.
    /// This helper is intended for compact ASCII-focused render tests; use
    /// `readCell` directly when style or wide-character cell layout matters.
    pub fn snapshot(self: *const TestSurface, allocator: std.mem.Allocator) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        const size = self.surface.size();

        var row: u16 = 0;
        while (row < size.height) : (row += 1) {
            var col: u16 = 0;
            while (col < size.width) : (col += 1) {
                try out.appendSlice(allocator, self.cellText(col, row));
            }
            if (row + 1 < size.height) {
                try out.append(allocator, '\n');
            }
        }

        return out.toOwnedSlice(allocator);
    }

    /// Assert the row-major text snapshot.
    pub fn expectSnapshot(self: *const TestSurface, expected: []const u8) !void {
        const actual = try self.snapshot(std.testing.allocator);
        defer std.testing.allocator.free(actual);
        try std.testing.expectEqualStrings(expected, actual);
    }
};

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
/// try std.testing.expect(tc.shouldQuit());
/// ```
pub fn TestCtx(comptime Msg: type) type {
    return struct {
        ctx: ctx_mod.Ctx(Msg) = .{ ._allocator = std.testing.allocator },

        /// Reset per-update transient state so this wrapper can be
        /// reused across multiple `update` calls in one test.
        ///
        /// Clears pending side effects and redraw suppression.
        /// Preserves the quit request and allocator.
        pub fn resetTransient(self: *@This()) void {
            self.ctx.runtimeClearPendingEffectCopies();
            _ = self.ctx.takePendingTasks();
            _ = self.ctx.takePendingTasksWith();
            self.ctx.resetRedrawSuppressed();
            _ = self.ctx.takeFrameRequest();
        }

        pub fn shouldQuit(self: *const @This()) bool {
            return self.ctx.shouldQuit();
        }

        pub fn pendingTaskCount(self: *const @This()) usize {
            return self.ctx._pending_tasks_len;
        }

        pub fn pendingTaskWithCount(self: *const @This()) usize {
            return self.ctx._pending_tasks_with_len;
        }

        pub fn pendingTickCount(self: *const @This()) usize {
            return self.ctx._pending_ticks_len;
        }

        pub fn pendingEveryCount(self: *const @This()) usize {
            return self.ctx._pending_everys_len;
        }

        pub fn pendingCancelCount(self: *const @This()) usize {
            return self.ctx._pending_cancels_len;
        }

        pub fn pendingClipboardCopyCount(self: *const @This()) usize {
            return self.ctx._pending_clipboard_copies_len;
        }

        pub fn hasPendingForegroundCommands(self: *const @This()) bool {
            return self.ctx.hasPendingForegroundCommands();
        }

        pub fn frameRequested(self: *const @This()) bool {
            return self.ctx._frame_requested;
        }

        pub fn redrawSuppressed(self: *const @This()) bool {
            return self.ctx.redrawWasSuppressed();
        }
    };
}

// --- Tests ---

test "TestCtx initialises with valid allocator and default state" {
    var tc: TestCtx(TestMsg) = .{};
    try std.testing.expectEqual(false, tc.shouldQuit());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTaskCount());

    // _allocator is usable
    const ally = tc.ctx.allocator();
    const ptr = try ally.create(u32);
    defer ally.destroy(ptr);
    ptr.* = 42;
    try std.testing.expectEqual(@as(u32, 42), ptr.*);
}

test "resetTransient clears pending queues and redraw suppression" {
    var tc: TestCtx(TestMsg) = .{};

    // Accumulate some state
    const task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) TestMsg {
            return .inc;
        }
        fn failed(_: ctx_mod.TaskFailure) TestMsg {
            return .dec;
        }
    };
    try tc.ctx.task().spawn(.{ .run = task.run, .failed = task.failed });
    try tc.ctx.timer().tick("t1", 1_000, .inc);
    try tc.ctx.timer().every("e1", 2_000, .dec);
    try tc.ctx.timer().cancel("x");
    try tc.ctx.terminal().copyToClipboard(.{
        .text = "clip",
        .finished = &struct {
            fn done(_: ctx_mod.Ctx(TestMsg).ClipboardCopyResult) TestMsg {
                return .inc;
            }
        }.done,
    });
    tc.ctx.redraw().skip();
    tc.ctx.frame().request();

    try std.testing.expectEqual(@as(usize, 1), tc.pendingTaskCount());
    try std.testing.expectEqual(@as(usize, 1), tc.pendingTickCount());
    try std.testing.expectEqual(@as(usize, 1), tc.pendingEveryCount());
    try std.testing.expectEqual(@as(usize, 1), tc.pendingCancelCount());
    try std.testing.expectEqual(@as(usize, 1), tc.pendingClipboardCopyCount());
    try std.testing.expectEqual(true, tc.redrawSuppressed());
    try std.testing.expectEqual(true, tc.frameRequested());

    tc.resetTransient();

    try std.testing.expectEqual(@as(usize, 0), tc.pendingTaskCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTaskWithCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTickCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingEveryCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingCancelCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingClipboardCopyCount());
    try std.testing.expectEqual(false, tc.redrawSuppressed());
    try std.testing.expectEqual(false, tc.frameRequested());
}

test "resetTransient preserves quit request" {
    var tc: TestCtx(TestMsg) = .{};

    tc.ctx.quit();
    try std.testing.expectEqual(true, tc.shouldQuit());

    tc.resetTransient();
    try std.testing.expectEqual(true, tc.shouldQuit());
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
    try std.testing.expectEqual(true, tc.shouldQuit());
}

const TestMsg = union(enum) { inc, dec };

test "TestSurface exposes a drawable headless surface" {
    // Keep TestSurface in stable storage: the embedded Surface points at the
    // backing screen initialized by ts.init.
    var ts: TestSurface = undefined;
    try ts.init(6, 2);
    defer ts.deinit();

    _ = ts.surface.borrowTextAt(1, 0, "ok", .{});

    try ts.expectCellText(1, 0, "o");
    try ts.expectCellText(2, 0, "k");
    try ts.expectSnapshot(" ok   \n      ");
}

test "TestSurface snapshot captures child clipping" {
    var ts: TestSurface = undefined;
    try ts.init(5, 2);
    defer ts.deinit();

    var child = ts.surface.child(.{ .col = 1, .row = 0, .width = 3, .height = 1 });
    _ = child.borrowTextAt(0, 0, "abcd", .{});

    try ts.expectSnapshot(" abc \n     ");
}
