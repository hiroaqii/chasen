const std = @import("std");
const chasen = @import("chasen");

// This example demonstrates RunOptions.runtime.trace_fn.
//
// The trace callback runs on the runtime path, so it should do only cheap work.
// This example counts lifecycle boundary events in caller-owned storage. The
// app then reads that collector during view.
const trace_event_count = @typeInfo(chasen.TraceEvent).@"enum".fields.len;

const TraceCollector = struct {
    counts: [trace_event_count]u64 = [_]u64{0} ** trace_event_count,
    total: u64 = 0,
    last: ?chasen.TraceEvent = null,

    fn count(self: *const TraceCollector, event: chasen.TraceEvent) u64 {
        return self.counts[@intFromEnum(event)];
    }
};

fn onTrace(context: ?*anyopaque, event: chasen.TraceEvent) void {
    // trace_context is caller-owned and type-erased by RunOptions. The callback
    // casts it back to the concrete collector type it expects.
    const collector: *TraceCollector = @ptrCast(@alignCast(context.?));
    collector.counts[@intFromEnum(event)] += 1;
    collector.total += 1;
    collector.last = event;
}

const RuntimeTraceDemo = struct {
    // The app reads the collector but does not own it. main() owns the storage
    // and passes the same pointer to both runWith() and the app model.
    trace: *const TraceCollector,
    running: bool = true,
    frame_index: u64 = 0,

    pub const Msg = union(enum) {
        frame: chasen.Frame,
        toggle,
        quit,
    };

    pub fn init(self: *RuntimeTraceDemo, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        ctx.frame().request();
    }

    pub fn handleEvent(self: *const RuntimeTraceDemo, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .frame => |frame| .{ .frame = frame },
            .key_press => |key| switch (key.codepoint) {
                ' ' => .toggle,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *RuntimeTraceDemo, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .frame => |frame| {
                self.frame_index = frame.index;
                if (self.running) ctx.frame().request();
            },
            .toggle => {
                self.running = !self.running;
                if (self.running) ctx.frame().request();
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const RuntimeTraceDemo, sfc: *chasen.Surface) !void {
        sfc.clearAll();
        sfc.hideCursor();

        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("RuntimeTrace Example", .{ .bold = true });
        col.borrowText("space: pause/resume  q: quit", .{ .fg = .gray });

        const status = if (self.running) "running" else "paused";
        try col.print("frame: {d}  {s}", .{ self.frame_index, status });

        col.borrowText("", .{});
        col.borrowText("Collected trace events:", .{ .bold = true });
        try col.print("total: {d}", .{self.trace.total});
        if (self.trace.last) |last| {
            try col.print("last: {s}", .{@tagName(last)});
        } else {
            col.borrowText("last: none", .{ .dim = true });
        }

        col.borrowText("", .{});
        try drawTraceCount(&col, self.trace, .startup);
        try drawTraceCount(&col, self.trace, .event_received);
        try drawTraceCount(&col, self.trace, .handle_event_start);
        try drawTraceCount(&col, self.trace, .handle_event_end);
        try drawTraceCount(&col, self.trace, .update_start);
        try drawTraceCount(&col, self.trace, .update_end);
        try drawTraceCount(&col, self.trace, .effect_drain_start);
        try drawTraceCount(&col, self.trace, .effect_drain_end);
        try drawTraceCount(&col, self.trace, .view_start);
        try drawTraceCount(&col, self.trace, .view_end);
        try drawTraceCount(&col, self.trace, .render_start);
        try drawTraceCount(&col, self.trace, .render_end);

        col.borrowText("", .{});
        col.borrowText("The trace callback only counts lifecycle boundaries.", .{ .dim = true });
        col.borrowText("Use chasen.run(...) instead of runWith(... trace_fn ...) to disable it.", .{ .dim = true });
    }
};

fn drawTraceCount(col: *chasen.Column, collector: *const TraceCollector, event: chasen.TraceEvent) !void {
    try col.print("{s}: {d}", .{ @tagName(event), collector.count(event) });
}

pub fn main(init: std.process.Init) !void {
    var collector = TraceCollector{};

    try chasen.runWith(.{
        .runtime = .{
            .allocator = init.gpa,
            .io = init.io,
            .trace_fn = onTrace,
            .trace_context = &collector,
        },
        .terminal = .{
            .env_map = init.environ_map,
        },
    }, RuntimeTraceDemo{ .trace = &collector });
}
