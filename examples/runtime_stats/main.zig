const std = @import("std");
const chasen = @import("chasen");

// This example demonstrates RunOptions.runtime.stats_fn.
//
// The stats callback runs on the runtime path, so it should do only cheap work.
// This example stores the latest timings and maximum observed timings in a
// caller-owned StatsCollector. The app then reads that collector during view.
const StatsCollector = struct {
    // The most recent RuntimeStats delivered by stats_fn. It is null until the
    // first event loop iteration completes.
    last: ?chasen.RuntimeStats = null,
    // These max fields show one common use of stats_fn: keep a cheap summary
    // instead of logging every iteration.
    max_handle_event_ns: u64 = 0,
    max_update_ns: u64 = 0,
    max_effect_drain_ns: u64 = 0,
    max_view_ns: u64 = 0,
    max_render_ns: u64 = 0,
    slow_view_count: u64 = 0,
};

fn onStats(context: ?*anyopaque, stats: chasen.RuntimeStats) void {
    // stats_context is caller-owned and type-erased by RunOptions. The callback
    // casts it back to the concrete collector type it expects.
    const collector: *StatsCollector = @ptrCast(@alignCast(context.?));

    collector.last = stats;
    collector.max_handle_event_ns = @max(collector.max_handle_event_ns, stats.handle_event_ns);
    collector.max_update_ns = @max(collector.max_update_ns, stats.update_ns);
    collector.max_effect_drain_ns = @max(collector.max_effect_drain_ns, stats.effect_drain_ns);
    collector.max_view_ns = @max(collector.max_view_ns, stats.view_ns);
    collector.max_render_ns = @max(collector.max_render_ns, stats.render_ns);

    // Keep callback work cheap. In a real app, prefer counting or buffering
    // here, then render or flush the summary somewhere else.
    if (stats.view_ns > 2 * std.time.ns_per_ms) {
        collector.slow_view_count += 1;
    }
}

const RuntimeStatsDemo = struct {
    // The app reads the collector but does not own it. main() owns the storage
    // and passes the same pointer to both runWith() and the app model.
    stats: *const StatsCollector,
    running: bool = true,
    frame_index: u64 = 0,

    pub const Msg = union(enum) {
        pub const undelivered_policy = .plain;

        frame: chasen.Frame,
        toggle,
        quit,
    };

    pub fn init(self: *RuntimeStatsDemo, ctx: *chasen.Ctx(Msg)) !void {
        _ = self;
        // Drive continuous runtime iterations so the stats callback has values
        // to collect. Without frame requests, stats update only when input or
        // other events arrive.
        ctx.frame().request();
    }

    pub fn handleEvent(self: *const RuntimeStatsDemo, event: chasen.Event) ?Msg {
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

    pub fn update(self: *RuntimeStatsDemo, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .frame => |frame| {
                self.frame_index = frame.index;
                // Request one more frame only while running. This keeps the
                // example close to how an app would opt in to repeated redraws.
                if (self.running) ctx.frame().request();
            },
            .toggle => {
                self.running = !self.running;
                // Resuming needs a new frame request because paused mode leaves
                // no frame future in flight.
                if (self.running) ctx.frame().request();
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const RuntimeStatsDemo, sfc: *chasen.Surface) !void {
        sfc.clearAll();
        sfc.hideCursor();

        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("RuntimeStats Example", .{ .bold = true });
        col.borrowText("space: pause/resume  q: quit", .{ .fg = .gray });

        const status = if (self.running) "running" else "paused";
        try col.print("frame: {d}  {s}", .{ self.frame_index, status });

        col.borrowText("", .{});
        col.borrowText("Latest completed runtime iteration:", .{ .bold = true });
        // stats_fn is called after an event loop iteration finishes. Since view
        // runs before that callback for the current iteration, the screen shows
        // the latest summary already stored by a previous callback.
        if (self.stats.last) |stats| {
            try col.print("event: {s}  events: {d}  frames: {d}", .{
                @tagName(stats.event_kind),
                stats.event_count,
                stats.frame_count,
            });
            try col.print("did_update: {}  did_render: {}", .{
                stats.did_update,
                stats.did_render,
            });
            try col.print("handleEvent: {d}us", .{nsToUs(stats.handle_event_ns)});
            try col.print("update:      {d}us", .{nsToUs(stats.update_ns)});
            try col.print("effects:     {d}us", .{nsToUs(stats.effect_drain_ns)});
            try col.print("view:        {d}us", .{nsToUs(stats.view_ns)});
            try col.print("render:      {d}us", .{nsToUs(stats.render_ns)});
        } else {
            col.borrowText("waiting for first runtime stats callback", .{ .dim = true });
        }

        col.borrowText("", .{});
        col.borrowText("Maximum observed durations:", .{ .bold = true });
        // These values are accumulated by onStats. Chasen core does not store
        // or aggregate stats; the app chooses what summary it wants.
        try col.print("handleEvent: {d}us", .{nsToUs(self.stats.max_handle_event_ns)});
        try col.print("update:      {d}us", .{nsToUs(self.stats.max_update_ns)});
        try col.print("effects:     {d}us", .{nsToUs(self.stats.max_effect_drain_ns)});
        try col.print("view:        {d}us", .{nsToUs(self.stats.max_view_ns)});
        try col.print("render:      {d}us", .{nsToUs(self.stats.max_render_ns)});
        try col.print("slow views over 2ms: {d}", .{self.stats.slow_view_count});

        col.borrowText("", .{});
        col.borrowText("The stats callback updates this summary after each event loop iteration.", .{ .dim = true });
        col.borrowText("Use chasen.run(...) instead of runWith(... stats_fn ...) to disable it.", .{ .dim = true });
    }
};

fn nsToUs(ns: u64) u64 {
    return ns / std.time.ns_per_us;
}

pub fn main(init: std.process.Init) !void {
    var collector = StatsCollector{};

    // runWith exposes the low-level RunOptions. runtime.stats_fn enables
    // measurement; leaving it null, or using chasen.run(...), keeps the default
    // path free of RuntimeStats construction and timing clock reads.
    try chasen.runWith(.{
        .runtime = .{
            .allocator = init.gpa,
            .io = init.io,
            .stats_fn = onStats,
            .stats_context = &collector,
        },
        .terminal = .{
            .env_map = init.environ_map,
        },
    }, RuntimeStatsDemo{ .stats = &collector });
}
