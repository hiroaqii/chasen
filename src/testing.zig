const std = @import("std");
const vaxis = @import("vaxis");
const ctx_mod = @import("ctx.zig");
const requests_mod = @import("requests.zig");
const runtime = @import("runtime.zig");
const foreground_command = @import("foreground_command.zig");
const clipboard = @import("clipboard.zig");
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

/// One test-owned task. Keep a single owner and defer deinit after taking it.
/// run/fail consume before calling user code; a second consume is an error.
pub fn TestTask(comptime Msg: type) type {
    return struct {
        entry: ?requests_mod.Requests(Msg).TaskEntry,
        allocator: std.mem.Allocator,
        io: std.Io,

        fn consume(self: *@This()) error{AlreadyConsumed}!requests_mod.Requests(Msg).TaskEntry {
            const entry = self.entry orelse return error.AlreadyConsumed;
            self.entry = null;
            return entry;
        }

        pub fn run(self: *@This()) (error{AlreadyConsumed} || std.Io.Cancelable)!Msg {
            const entry = try self.consume();
            return entry.run(self.allocator, self.io);
        }

        pub fn fail(self: *@This(), failure: ctx_mod.TaskStartError) error{ AlreadyConsumed, Canceled }!Msg {
            const entry = try self.consume();
            if (entry.canceled) {
                entry.discard(self.allocator);
                return error.Canceled;
            }
            return entry.failed(failure, self.allocator);
        }

        pub fn deinit(self: *@This()) void {
            const entry = self.entry orelse return;
            self.entry = null;
            entry.discard(self.allocator);
        }
    };
}

/// Headless request fixture using the production owner. Initialize in final
/// storage, explicitly supplying allocator and Io; do not move after init.
///
/// ```
/// var tc: chasen.testing.TestCtx(App.Msg) = undefined;
/// tc.init(std.testing.allocator, std.testing.io);
/// defer tc.deinit();
/// try app.update(.some_msg, &tc.ctx);
/// ```
pub fn TestCtx(comptime Msg: type) type {
    const Requests = requests_mod.Requests(Msg);
    return struct {
        requests: Requests,
        ctx: ctx_mod.Ctx(Msg),

        pub const ForegroundView = struct {
            request_id: foreground_command.ForegroundCommandRequestId,
            argv: []const []const u8,
            cwd: foreground_command.ForegroundCommandCwd,
            environment: foreground_command.ForegroundCommandEnvironment,
        };
        pub const ClipboardView = struct {
            request_id: clipboard.ClipboardCopyRequestId,
            text: []const u8,
        };

        pub fn init(self: *@This(), allocator: std.mem.Allocator, io: std.Io) void {
            self.requests = Requests.init(allocator, io);
            self.ctx = ctx_mod.Ctx(Msg).init(&self.requests);
        }

        pub fn deinit(self: *@This()) void {
            self.requests.deinit();
            self.* = undefined;
        }

        pub fn discardPendingTasks(self: *@This()) void {
            self.requests.discardPendingTasks();
        }
        pub fn discardPendingEffects(self: *@This()) void {
            self.requests.discardPendingEffects();
        }

        /// Clear requests and frame/redraw state, retaining quit and ID sequences.
        pub fn resetTransient(self: *@This()) void {
            self.discardPendingTasks();
            self.discardPendingEffects();
            self.requests.resetRedrawSuppressed();
            _ = self.requests.takeFrameRequest();
        }

        pub fn shouldQuit(self: *const @This()) bool {
            return self.ctx.shouldQuit();
        }
        pub fn pendingTaskCount(self: *const @This()) usize {
            return self.requests._pending_tasks_len;
        }
        pub fn pendingTickCount(self: *const @This()) usize {
            return self.requests._pending_ticks_len;
        }
        pub fn pendingEveryCount(self: *const @This()) usize {
            return self.requests._pending_everys_len;
        }
        pub fn pendingCancelCount(self: *const @This()) usize {
            return self.requests._pending_cancels_len;
        }
        pub fn pendingClipboardCopyCount(self: *const @This()) usize {
            return self.requests._pending_clipboard_copies_len;
        }
        pub fn hasPendingForegroundCommands(self: *const @This()) bool {
            return self.requests.hasPendingForegroundCommands();
        }
        pub fn frameRequested(self: *const @This()) bool {
            return self.requests._frame_requested;
        }
        pub fn redrawSuppressed(self: *const @This()) bool {
            return self.requests.redrawWasSuppressed();
        }

        /// Observation borrows IDs and payloads until this owner next mutates.
        pub fn tickAt(self: *const @This(), index: usize) ?Requests.TickEntry {
            if (index >= self.pendingTickCount()) return null;
            return self.requests._pending_ticks[index];
        }
        pub fn everyAt(self: *const @This(), index: usize) ?Requests.EveryEntry {
            if (index >= self.pendingEveryCount()) return null;
            return self.requests._pending_everys[index];
        }
        pub fn cancelAt(self: *const @This(), index: usize) ?[]const u8 {
            if (index >= self.pendingCancelCount()) return null;
            return self.requests._pending_cancels[index];
        }
        pub fn foregroundAt(self: *const @This(), index: usize) ?ForegroundView {
            if (index >= self.requests._pending_foreground_commands_len) return null;
            const entry = &self.requests._pending_foreground_commands[index];
            return .{
                .request_id = entry.request_id,
                .argv = entry.input.argv,
                .cwd = entry.input.childCwd(),
                .environment = if (entry.input.childEnvironment()) |map| .{ .replace = map } else .inherit,
            };
        }
        pub fn clipboardAt(self: *const @This(), index: usize) ?ClipboardView {
            if (index >= self.pendingClipboardCopyCount()) return null;
            const entry = &self.requests._pending_clipboard_copies[index];
            return .{ .request_id = entry.request_id, .text = entry.text };
        }

        /// Transfer one task, preserving the relative order of the rest.
        pub fn takeTask(self: *@This(), index: usize) ?TestTask(Msg) {
            return .{
                .entry = self.requests.removeTaskAt(index) orelse return null,
                .allocator = self.requests.allocator(),
                .io = self.requests.io(),
            };
        }

        /// No child or tty is run. The returned Msg belongs to the test until
        /// passed to App.update or explicitly discarded.
        pub fn completeForeground(self: *@This(), index: usize, outcome: foreground_command.ForegroundCommandOutcome) error{IndexOutOfBounds}!Msg {
            var entry = self.requests.removeForegroundCommandAt(index) orelse return error.IndexOutOfBounds;
            defer entry.deinit(self.requests.allocator());
            return entry.message(outcome);
        }
        pub fn completeClipboard(self: *@This(), index: usize, outcome: clipboard.ClipboardCopyOutcome) error{IndexOutOfBounds}!Msg {
            var entry = self.requests.removeClipboardCopyAt(index) orelse return error.IndexOutOfBounds;
            defer entry.deinit(self.requests.allocator());
            return entry.message(outcome);
        }
        pub fn discardMessage(self: *@This(), msg: *Msg) void {
            runtime.deinitUndeliveredMessage(Msg, msg, self.requests.allocator());
        }

        /// Occupy real admission slots with discard-only tasks. Partial success
        /// stays owned by this fixture when a limit/identity error is returned.
        pub fn fillTaskSlots(self: *@This(), count: usize) error{ TaskLimitExceeded, TaskIdExhausted }!void {
            const DiscardOnly = struct {
                fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!Msg {
                    unreachable;
                }
                fn failed(_: ctx_mod.TaskStartError) Msg {
                    unreachable;
                }
            };
            for (0..count) |_| _ = try self.ctx.task().spawn(.{ .run = DiscardOnly.run, .failed = DiscardOnly.failed });
        }
    };
}

// --- Tests ---

test "TestCtx initialises with valid allocator and default state" {
    var tc: TestCtx(TestMsg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
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
    var tc: TestCtx(TestMsg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();

    // Accumulate some state
    const task = struct {
        fn run(_: std.mem.Allocator, _: std.Io) std.Io.Cancelable!TestMsg {
            return .inc;
        }
        fn failed(_: ctx_mod.TaskStartError) TestMsg {
            return .dec;
        }
    };
    _ = try tc.ctx.task().spawn(.{ .run = task.run, .failed = task.failed });
    try tc.ctx.timer().tick("t1", 1_000, .inc);
    try tc.ctx.timer().every("e1", 2_000, .dec);
    try tc.ctx.timer().cancel("x");
    _ = try tc.ctx.terminal().copyToClipboard(.{
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
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTickCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingEveryCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingCancelCount());
    try std.testing.expectEqual(@as(usize, 0), tc.pendingClipboardCopyCount());
    try std.testing.expectEqual(false, tc.redrawSuppressed());
    try std.testing.expectEqual(false, tc.frameRequested());
}

test "resetTransient preserves quit request" {
    var tc: TestCtx(TestMsg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();

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
    var tc: TestCtx(Counter.Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();

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

test "task reset and explicit discard share ownership and preserve identity" {
    const Capture = struct {
        cleanups: *usize,
        fn run(_: *@This(), _: std.mem.Allocator, _: std.Io) std.Io.Cancelable!u8 {
            unreachable;
        }
        fn failed(_: *@This(), _: ctx_mod.TaskStartError, _: std.mem.Allocator) u8 {
            unreachable;
        }
        fn cleanup(self: *@This(), alloc: std.mem.Allocator) void {
            self.cleanups.* += 1;
            alloc.destroy(self);
        }
    };
    var tc: TestCtx(u8) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    var count: usize = 0;
    var previous: u64 = 0;
    for (0..2) |i| {
        const capture = try std.testing.allocator.create(Capture);
        capture.* = .{ .cleanups = &count };
        const id = try tc.ctx.task().spawnOwned(capture, .{ .run = Capture.run, .failed = Capture.failed, .cleanup = Capture.cleanup });
        try std.testing.expect(@intFromEnum(id) > previous);
        previous = @intFromEnum(id);
        if (i == 0) tc.resetTransient() else tc.discardPendingTasks();
        try std.testing.expectEqual(i + 1, count);
    }
    tc.resetTransient();
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "TestTask consumes owned contexts once across every terminal" {
    const Capture = struct {
        cleanups: *usize,
        value: u8,
        fn run(self: *@This(), _: std.mem.Allocator, io: std.Io) std.Io.Cancelable!u8 {
            std.debug.assert(io.vtable == std.testing.io.vtable);
            std.debug.assert(io.userdata == std.testing.io.userdata);
            return self.value;
        }
        fn failed(self: *@This(), _: ctx_mod.TaskStartError, _: std.mem.Allocator) u8 {
            return self.value + 10;
        }
        fn cleanup(self: *@This(), alloc: std.mem.Allocator) void {
            self.cleanups.* += 1;
            alloc.destroy(self);
        }
    };
    var tc: TestCtx(u8) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    var cleanups: usize = 0;
    for (0..6) |i| {
        const capture = try std.testing.allocator.create(Capture);
        capture.* = .{ .cleanups = &cleanups, .value = @intCast(i) };
        const id = try tc.ctx.task().spawnOwned(capture, .{ .run = Capture.run, .failed = Capture.failed, .cleanup = Capture.cleanup });
        if (i == 2 or i == 3) tc.ctx.task().requestCancel(id);
    }
    try std.testing.expect(tc.takeTask(6) == null);
    var failed = tc.takeTask(1).?;
    defer failed.deinit();
    var run = tc.takeTask(0).?;
    defer run.deinit();
    var canceled_run = tc.takeTask(0).?;
    defer canceled_run.deinit();
    var canceled_fail = tc.takeTask(0).?;
    defer canceled_fail.deinit();
    var discarded = tc.takeTask(1).?;
    defer discarded.deinit();
    // Reset owns only the remaining fifth task, not the detached handles.
    tc.resetTransient();
    try std.testing.expectEqual(@as(usize, 1), cleanups);
    discarded.deinit();
    discarded.deinit();
    try std.testing.expectError(error.AlreadyConsumed, discarded.run());
    try std.testing.expectEqual(@as(usize, 2), cleanups);
    try std.testing.expectEqual(@as(u8, 11), try failed.fail(error.OutOfMemory));
    try std.testing.expectEqual(@as(u8, 0), try run.run());
    try std.testing.expectError(error.Canceled, canceled_run.run());
    try std.testing.expectError(error.Canceled, canceled_fail.fail(error.ConcurrencyUnavailable));
    try std.testing.expectError(error.AlreadyConsumed, run.run());
    try std.testing.expectError(error.AlreadyConsumed, failed.fail(error.OutOfMemory));
    try std.testing.expectError(error.AlreadyConsumed, canceled_fail.run());
    run.deinit();
    failed.deinit();
    try std.testing.expectEqual(@as(usize, 6), cleanups);
}

test "TestCtx observes requests and completes owned messages without a terminal" {
    const Msg = struct {
        bytes: []const u8,
        pub const undelivered_policy = .deinit;
        pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(self.bytes);
        }
        fn fromClipboard(_: clipboard.ClipboardCopyResult) @This() {
            return .{ .bytes = std.testing.allocator.dupe(u8, "clipboard result") catch unreachable };
        }
        fn fromForeground(_: foreground_command.ForegroundCommandResult) @This() {
            return .{ .bytes = std.testing.allocator.dupe(u8, "foreground result") catch unreachable };
        }
    };
    var tc: TestCtx(Msg) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    const template: Msg = .{ .bytes = "borrowed timer template" };
    try tc.ctx.timer().tick("tick", 10, template);
    try tc.ctx.timer().every("every", 20, template);
    try tc.ctx.timer().cancel("cancel");
    try std.testing.expectEqualStrings("tick", tc.tickAt(0).?.id);
    try std.testing.expectEqual(@as(u64, 10), tc.tickAt(0).?.after_ns);
    try std.testing.expectEqualStrings(template.bytes, tc.everyAt(0).?.msg.bytes);
    try std.testing.expectEqual(@as(u64, 20), tc.everyAt(0).?.interval_ns);
    try std.testing.expectEqualStrings("cancel", tc.cancelAt(0).?);
    try std.testing.expect(tc.tickAt(1) == null and tc.everyAt(1) == null and tc.cancelAt(1) == null);

    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("NAME", "before");
    const foreground_id = try tc.ctx.terminal().runForegroundCommand(.{
        .argv = &.{ "tool", "arg" },
        .cwd = .{ .path = "work" },
        .environment = .{ .replace = &env },
        .finished = Msg.fromForeground,
    });
    try env.put("NAME", "after");
    const view = tc.foregroundAt(0).?;
    try std.testing.expectEqual(foreground_id, view.request_id);
    try std.testing.expectEqualStrings("arg", view.argv[1]);
    try std.testing.expectEqualStrings("work", view.cwd.path);
    try std.testing.expectEqualStrings("before", view.environment.replace.get("NAME").?);
    var fg_msg = try tc.completeForeground(0, .{ .exited = 0 });
    defer tc.discardMessage(&fg_msg);
    try std.testing.expect(tc.foregroundAt(0) == null);
    try std.testing.expectError(error.IndexOutOfBounds, tc.completeForeground(0, .runtime_abandoned));

    _ = try tc.ctx.terminal().copyToClipboard(.{ .text = "first", .finished = Msg.fromClipboard });
    const clipboard_id = try tc.ctx.terminal().copyToClipboard(.{ .text = "second", .finished = Msg.fromClipboard });
    try std.testing.expectEqual(clipboard_id, tc.clipboardAt(1).?.request_id);
    try std.testing.expectEqualStrings("second", tc.clipboardAt(1).?.text);
    var clip_msg = try tc.completeClipboard(1, .sent);
    defer tc.discardMessage(&clip_msg);
    try std.testing.expectEqualStrings("first", tc.clipboardAt(0).?.text);
    try std.testing.expect(tc.clipboardAt(1) == null);
    try std.testing.expectError(error.IndexOutOfBounds, tc.completeClipboard(1, .sent));
    tc.resetTransient();
}

test "TestCtx real task saturation keeps accepted prefix and effect cleanup separate" {
    var tc: TestCtx(u8) = undefined;
    tc.init(std.testing.allocator, std.testing.io);
    defer tc.deinit();
    try tc.fillTaskSlots(14);
    try std.testing.expectEqual(@as(usize, 14), tc.pendingTaskCount());
    try tc.fillTaskSlots(1);
    try std.testing.expectEqual(@as(usize, 15), tc.pendingTaskCount());
    try std.testing.expectError(error.TaskLimitExceeded, tc.fillTaskSlots(2));
    try std.testing.expectEqual(@as(usize, 16), tc.pendingTaskCount());
    tc.discardPendingEffects();
    try std.testing.expectEqual(@as(usize, 16), tc.pendingTaskCount());
    tc.discardPendingTasks();
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTaskCount());
}

test "TestCtx admission uses the supplied failing allocator" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var tc: TestCtx(u8) = undefined;
    tc.init(failing.allocator(), std.testing.io);
    defer tc.deinit();
    try std.testing.expectError(error.OutOfMemory, tc.ctx.timer().tick("owned id", 1, 0));
    try std.testing.expectEqual(@as(usize, 0), tc.pendingTickCount());
    _ = tc.ctx.now();
}

test "TestCtx clock delegates to an explicitly supplied Io" {
    const Clock = struct {
        fn now(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
            return .{ .nanoseconds = 123456 };
        }
    };
    var vtable = std.testing.io.vtable.*;
    vtable.now = Clock.now;
    const io: std.Io = .{ .userdata = std.testing.io.userdata, .vtable = &vtable };
    var tc: TestCtx(u8) = undefined;
    tc.init(std.testing.allocator, io);
    defer tc.deinit();
    try std.testing.expectEqual(@as(i96, 123456), tc.ctx.now().nanoseconds);
    try std.testing.expect(tc.ctx.io().vtable == &vtable);
}
