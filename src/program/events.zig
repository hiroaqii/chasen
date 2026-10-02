const std = @import("std");
const vaxis = @import("vaxis");
const ctx_mod = @import("../ctx.zig");
const runtime = @import("../runtime.zig");
const types = @import("../program_types.zig");
const trace = types.trace;
const timingStart = types.timingStart;
const timingElapsed = types.timingElapsed;

/// Owns bracketed input until its synchronous app dispatch ends.
pub const Events = struct {
    allocator: std.mem.Allocator,
    paste: BracketedPasteAccumulator = .{},

    pub fn init(allocator: std.mem.Allocator) Events {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Events) void {
        self.paste.deinit(self.allocator);
    }

    pub fn startPaste(self: *Events) void {
        self.paste.start();
    }

    pub fn cancelPaste(self: *Events) void {
        self.paste.cancel();
    }

    pub fn keyPress(
        self: *Events,
        comptime App: type,
        app: *App,
        key: vaxis.Key,
        app_ctx: *ctx_mod.Ctx(App.Msg),
        io: std.Io,
        stats: *?runtime.RuntimeStats,
        opts: types.RunOptions,
    ) !bool {
        if (self.paste.active) {
            // A failed paste still swallows its tail until the end marker.
            if (stats.*) |*s| s.event_kind = .paste;
            self.paste.appendKey(self.allocator, key) catch self.paste.fail();
            return false;
        }
        return dispatchAppEvent(App, app, .{ .key_press = key }, app_ctx, io, stats, opts);
    }

    pub fn endPaste(
        self: *Events,
        comptime App: type,
        app: *App,
        app_ctx: *ctx_mod.Ctx(App.Msg),
        io: std.Io,
        stats: *?runtime.RuntimeStats,
        opts: types.RunOptions,
    ) !bool {
        if (self.paste.finish(self.allocator)) |text| {
            defer self.allocator.free(text);
            return dispatchAppEvent(App, app, .{ .paste = text }, app_ctx, io, stats, opts);
        }
        return false;
    }
};

/// Converts terminal bracketed-paste marker events into one public Event.paste.
///
/// vaxis exposes bracketed paste as `paste_start`, many ordinary `key_press`
/// events, then `paste_end`. Apps should not have to know that transport detail:
/// they should receive one paste payload and should never see the intermediate
/// key events as normal typing.
const BracketedPasteAccumulator = struct {
    active: bool = false,
    failed: bool = false,
    bytes: std.ArrayListUnmanaged(u8) = .empty,

    fn start(self: *BracketedPasteAccumulator) void {
        self.cancel();
        self.active = true;
    }

    fn appendKey(self: *BracketedPasteAccumulator, allocator: std.mem.Allocator, key: vaxis.Key) !void {
        if (!self.active) return;
        if (self.failed) return;

        // Prefer vaxis' decoded text. The slice is event-scoped, so copy it
        // before the next parser event can reuse the backing buffer.
        if (key.text) |text| {
            try self.bytes.appendSlice(allocator, text);
            return;
        }

        if (pasteControlText(key)) |text| {
            try self.bytes.appendSlice(allocator, text);
            return;
        }

        if (key.mods.ctrl) return;
        if (!isPasteTextCodepoint(key.codepoint)) return;
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(key.codepoint, &buf) catch return;
        try self.bytes.appendSlice(allocator, buf[0..len]);
    }

    fn finish(self: *BracketedPasteAccumulator, allocator: std.mem.Allocator) ?[]u8 {
        if (!self.active) return null;
        self.active = false;

        if (self.failed) {
            self.failed = false;
            self.bytes.clearRetainingCapacity();
            return null;
        }
        if (self.bytes.items.len == 0) {
            self.bytes.clearRetainingCapacity();
            return null;
        }
        if (!std.unicode.utf8ValidateSlice(self.bytes.items)) {
            self.bytes.clearRetainingCapacity();
            return null;
        }

        return self.bytes.toOwnedSlice(allocator) catch {
            self.bytes.clearRetainingCapacity();
            return null;
        };
    }

    fn fail(self: *BracketedPasteAccumulator) void {
        // Keep `active` true so the rest of this bracketed paste is swallowed
        // until `paste_end`; otherwise a failed paste tail becomes key input.
        self.active = true;
        self.failed = true;
        self.bytes.clearRetainingCapacity();
    }

    fn cancel(self: *BracketedPasteAccumulator) void {
        self.active = false;
        self.failed = false;
        self.bytes.clearRetainingCapacity();
    }

    fn deinit(self: *BracketedPasteAccumulator, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = .{};
    }
};

fn isPasteTextCodepoint(codepoint: u21) bool {
    return switch (codepoint) {
        '\n', vaxis.Key.tab, vaxis.Key.enter => true,
        0x20...0xD7FF, 0xE000...0x10FFFF => codepoint < vaxis.Key.insert or codepoint > vaxis.Key.iso_level_5_shift,
        else => false,
    };
}

fn pasteControlText(key: vaxis.Key) ?[]const u8 {
    if (!key.mods.ctrl) return null;
    if (key.mods.alt or key.mods.super or key.mods.hyper or key.mods.meta) return null;
    if (key.codepoint > std.math.maxInt(u8)) return null;

    // Some terminals report pasted LF/TAB/CR through their legacy control-key
    // encodings (Ctrl+J / Ctrl+I / Ctrl+M) without decoded `key.text`.
    // Treat only those textual controls as paste bytes; other Ctrl keys are
    // shortcuts/special input and must not become printable letters.
    return switch (std.ascii.toLower(@as(u8, @intCast(key.codepoint)))) {
        'i' => "\t",
        'j' => "\n",
        'm' => "\r",
        else => null,
    };
}

/// Route an app-facing event through optional `handleEvent`, then apply the
/// returned message if the app handled it.
///
/// This keeps the common handleEvent/update/stat timing path in one place.
/// Event-specific runtime work, such as terminal resize or frame-future
/// cleanup, stays in the switch branch before this helper is called.
pub fn dispatchAppEvent(
    comptime App: type,
    app: *App,
    event: types.Event,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    io: std.Io,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
) !bool {
    const measure = stats.* != null;
    trace(opts, .handle_event_start);
    const handle_start = timingStart(measure, io);
    const maybe_msg: ?App.Msg = if (@hasDecl(App, "handleEvent"))
        app.handleEvent(event)
    else
        null;

    if (stats.*) |*s| {
        s.handle_event_ns = timingElapsed(handle_start, io);
    }
    trace(opts, .handle_event_end);

    if (maybe_msg) |msg| {
        return try applyMsg(App, app, msg, app_ctx, io, stats, opts);
    }

    return false;
}

/// Apply one app message and return whether the app requested a redraw.
///
/// `ctx.redraw().skip()` is message-scoped, so the flag is reset immediately
/// before each app update. The helper also owns update timing and the
/// `did_update` stats flag, which avoids duplicating that bookkeeping across
/// every event kind.
pub fn applyMsg(
    comptime App: type,
    app: *App,
    msg: App.Msg,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    io: std.Io,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
) !bool {
    const measure = stats.* != null;
    app_ctx.requests.resetRedrawSuppressed();

    trace(opts, .update_start);
    const update_start = timingStart(measure, io);
    try app.update(msg, app_ctx);

    if (stats.*) |*s| {
        s.update_ns = timingElapsed(update_start, io);
        s.did_update = true;
    }
    trace(opts, .update_end);

    return !app_ctx.requests.redrawWasSuppressed();
}

pub fn eventKind(event: anytype) runtime.RuntimeEventKind {
    return switch (event) {
        .key_press => .key_press,
        .winsize => .winsize,
        .user_msg => .user_msg,
        .mouse => .mouse,
        .focus_in => .focus_in,
        .focus_out => .focus_out,
        .paste_start => .paste,
        .paste_end => .paste,
        .frame => .frame,
        .frame_canceled => .frame,
        .resize_pending => .winsize,
        .continue_effect_drain => .user_msg,
    };
}

test "BracketedPasteAccumulator combines pasted key text" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.multicodepoint, .text = "hello" });
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.enter });
    try paste.appendKey(allocator, .{ .codepoint = '世', .text = "世界" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("hello\r世界", text);
}

test "BracketedPasteAccumulator restarts nested paste" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = 'a', .text = "old" });
    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = 'n', .text = "new" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("new", text);
}

test "BracketedPasteAccumulator ignores non-text special keys" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.up });
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.left_shift });

    try std.testing.expectEqual(@as(?[]u8, null), paste.finish(allocator));
}

test "BracketedPasteAccumulator drops invalid utf8" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    var invalid = [_]u8{0xff};
    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = vaxis.Key.multicodepoint, .text = invalid[0..] });

    try std.testing.expectEqual(@as(?[]u8, null), paste.finish(allocator));
}

test "BracketedPasteAccumulator failure swallows until paste end" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
    paste.fail();
    try paste.appendKey(allocator, .{ .codepoint = 't', .text = "tail" });

    try std.testing.expect(paste.active);
    try std.testing.expect(paste.failed);
    try std.testing.expectEqual(@as(?[]u8, null), paste.finish(allocator));
    try std.testing.expect(!paste.active);
    try std.testing.expect(!paste.failed);
}

test "BracketedPasteAccumulator maps ctrl-j paste key to newline" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = 'a', .text = "aaaaa" });
    try paste.appendKey(allocator, .{ .codepoint = 'j', .mods = .{ .ctrl = true } });
    try paste.appendKey(allocator, .{ .codepoint = 'b', .text = "bbbbb" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("aaaaa\nbbbbb", text);
}

test "BracketedPasteAccumulator preserves direct line-feed codepoint" {
    const allocator = std.testing.allocator;
    var paste: BracketedPasteAccumulator = .{};
    defer paste.deinit(allocator);

    paste.start();
    try paste.appendKey(allocator, .{ .codepoint = 'a', .text = "aaaaa" });
    try paste.appendKey(allocator, .{ .codepoint = '\n' });
    try paste.appendKey(allocator, .{ .codepoint = 'b', .text = "bbbbb" });

    const text = paste.finish(allocator).?;
    defer allocator.free(text);
    try std.testing.expectEqualStrings("aaaaa\nbbbbb", text);
}

const DispatchTrace = struct {
    entries: std.ArrayList(runtime.TraceEvent) = .empty,
    clock_ns: i96 = 100,
    clock_calls: usize = 0,

    fn record(context: ?*anyopaque, event: runtime.TraceEvent) void {
        const self: *DispatchTrace = @ptrCast(@alignCast(context.?));
        self.entries.append(std.testing.allocator, event) catch unreachable;
    }

    fn now(context: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
        const self: *DispatchTrace = @ptrCast(@alignCast(context.?));
        self.clock_calls += 1;
        self.clock_ns += 10;
        return .{ .nanoseconds = self.clock_ns };
    }

    fn options(self: *DispatchTrace, io: std.Io) types.RunOptions {
        return .{ .runtime = .{
            .allocator = std.testing.allocator,
            .io = io,
            .trace_fn = record,
            .trace_context = self,
        }, .terminal = undefined };
    }
};

test "event dispatch preserves optional handling and disabled timing" {
    const NoHandler = struct {
        pub const Msg = void;
        pub fn update(_: *@This(), _: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            return error.UnexpectedUpdate;
        }
    };
    const NullHandler = struct {
        pub const Msg = void;
        pub fn handleEvent(_: *@This(), _: types.Event) ?Msg {
            return null;
        }
        pub fn update(_: *@This(), _: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            return error.UnexpectedUpdate;
        }
    };
    var recorder: DispatchTrace = .{};
    defer recorder.entries.deinit(std.testing.allocator);
    var requests = @import("../requests.zig").Requests(void).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var ctx = ctx_mod.Ctx(void).init(&requests);
    var stats: ?runtime.RuntimeStats = null;
    const opts = recorder.options(std.testing.io);
    var absent: NoHandler = .{};
    var ignored: NullHandler = .{};
    try std.testing.expect(!try dispatchAppEvent(NoHandler, &absent, .focus_in, &ctx, undefined, &stats, opts));
    try std.testing.expect(!try dispatchAppEvent(NullHandler, &ignored, .focus_out, &ctx, undefined, &stats, opts));
    try std.testing.expectEqualSlices(runtime.TraceEvent, &.{ .handle_event_start, .handle_event_end, .handle_event_start, .handle_event_end }, recorder.entries.items);
    try std.testing.expect(stats == null);
}

test "event dispatch resets redraw per message and overwrites timings without changing counters" {
    const App = struct {
        calls: usize = 0,
        recorder: *DispatchTrace,
        pub const Msg = enum { skip, draw };
        pub fn handleEvent(self: *@This(), _: types.Event) ?Msg {
            std.debug.assert(self.recorder.entries.getLast() == .handle_event_start);
            return .skip;
        }
        pub fn update(self: *@This(), msg: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            try std.testing.expectEqual(runtime.TraceEvent.update_start, self.recorder.entries.getLast());
            self.calls += 1;
            if (msg == .skip) ctx.redraw().skip();
        }
    };
    var recorder: DispatchTrace = .{};
    defer recorder.entries.deinit(std.testing.allocator);
    var vtable = std.testing.io.vtable.*;
    vtable.now = DispatchTrace.now;
    const io: std.Io = .{ .userdata = &recorder, .vtable = &vtable };
    var requests = @import("../requests.zig").Requests(App.Msg).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var ctx = ctx_mod.Ctx(App.Msg).init(&requests);
    var app: App = .{ .recorder = &recorder };
    var stats: ?runtime.RuntimeStats = .{ .event_kind = .frame, .event_count = 7, .frame_count = 3 };
    const opts = recorder.options(io);
    try std.testing.expect(!try dispatchAppEvent(App, &app, .focus_in, &ctx, io, &stats, opts));
    try std.testing.expect(try applyMsg(App, &app, .draw, &ctx, io, &stats, opts));
    try std.testing.expectEqualSlices(runtime.TraceEvent, &.{ .handle_event_start, .handle_event_end, .update_start, .update_end, .update_start, .update_end }, recorder.entries.items);
    try std.testing.expectEqual(@as(u64, 10), stats.?.handle_event_ns);
    try std.testing.expectEqual(@as(u64, 10), stats.?.update_ns);
    try std.testing.expectEqual(@as(u64, 7), stats.?.event_count);
    try std.testing.expectEqual(@as(u64, 3), stats.?.frame_count);
    try std.testing.expectEqual(runtime.RuntimeEventKind.frame, stats.?.event_kind);
    try std.testing.expect(stats.?.did_update);
    try std.testing.expect(!stats.?.did_render);
    try std.testing.expectEqual(@as(usize, 6), recorder.clock_calls);
    stats = null;
    try std.testing.expect(try applyMsg(App, &app, .draw, &ctx, io, &stats, opts));
    try std.testing.expectEqual(@as(usize, 6), recorder.clock_calls);
    try std.testing.expectEqual(@as(usize, 3), app.calls);
}

test "event paste allocation failure swallows tail and cancellation restores key dispatch" {
    const App = struct {
        keys: usize = 0,
        pub const Msg = void;
        pub fn handleEvent(self: *@This(), event: types.Event) ?Msg {
            std.debug.assert(event == .key_press);
            self.keys += 1;
            return null;
        }
        pub fn update(_: *@This(), _: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            unreachable;
        }
    };
    var events = Events.init(std.testing.failing_allocator);
    defer events.deinit();
    var requests = @import("../requests.zig").Requests(void).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var ctx = ctx_mod.Ctx(void).init(&requests);
    var app: App = .{};
    var stats: ?runtime.RuntimeStats = .{ .event_kind = .key_press, .event_count = 1, .frame_count = 0 };
    const opts: types.RunOptions = .{ .runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io }, .terminal = undefined };
    events.startPaste();
    for (0..2) |_| try std.testing.expect(!try events.keyPress(App, &app, .{ .codepoint = 'a', .text = "payload" }, &ctx, std.testing.io, &stats, opts));
    try std.testing.expectEqual(runtime.RuntimeEventKind.paste, stats.?.event_kind);
    try std.testing.expect(!try events.endPaste(App, &app, &ctx, std.testing.io, &stats, opts));
    try std.testing.expectEqual(@as(usize, 0), app.keys);
    events.startPaste();
    events.cancelPaste();
    try std.testing.expect(!try events.keyPress(App, &app, .{ .codepoint = 'a' }, &ctx, std.testing.io, &stats, opts));
    try std.testing.expectEqual(@as(usize, 1), app.keys);
}

test "event paste lives through update and is released on success null and error" {
    const App = struct {
        mode: enum { success, ignore, fail },
        updates: usize = 0,
        pub const Msg = []const u8;
        pub fn handleEvent(self: *@This(), event: types.Event) ?Msg {
            std.debug.assert(std.mem.eql(u8, event.paste, "borrowed paste"));
            return if (self.mode == .ignore) null else event.paste;
        }
        pub fn update(self: *@This(), msg: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            try std.testing.expectEqualStrings("borrowed paste", msg);
            self.updates += 1;
            if (self.mode == .fail) return error.UpdateFailed;
        }
    };
    var events = Events.init(std.testing.allocator);
    defer events.deinit();
    var requests = @import("../requests.zig").Requests(App.Msg).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var ctx = ctx_mod.Ctx(App.Msg).init(&requests);
    var recorder: DispatchTrace = .{};
    defer recorder.entries.deinit(std.testing.allocator);
    const opts = recorder.options(std.testing.io);
    for ([_]@FieldType(App, "mode"){ .success, .ignore, .fail }) |mode| {
        var app: App = .{ .mode = mode };
        var stats: ?runtime.RuntimeStats = .{ .event_kind = .paste, .event_count = 1, .frame_count = 0 };
        events.startPaste();
        _ = try events.keyPress(App, &app, .{ .codepoint = 'b', .text = "borrowed paste" }, &ctx, std.testing.io, &stats, opts);
        const result = events.endPaste(App, &app, &ctx, std.testing.io, &stats, opts);
        if (mode == .fail) {
            try std.testing.expectError(error.UpdateFailed, result);
            try std.testing.expectEqual(runtime.TraceEvent.update_start, recorder.entries.getLast());
            try std.testing.expect(!stats.?.did_update);
            try std.testing.expectEqual(@as(u64, 0), stats.?.update_ns);
        } else try std.testing.expectEqual(mode == .success, try result);
        try std.testing.expectEqual(@as(usize, if (mode == .ignore) 0 else 1), app.updates);
        try std.testing.expect(!try events.endPaste(App, &app, &ctx, std.testing.io, &stats, opts));
    }
}
