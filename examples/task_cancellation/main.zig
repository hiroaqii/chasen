const std = @import("std");
const chasen = @import("chasen");

const Counts = struct {
    created: usize = 0, // Only the runtime thread creates contexts.
    cleaned: std.atomic.Value(usize) = .init(0),
};

const SearchDemo = struct {
    counts: *Counts,
    generation: usize = 0,
    active: ?chasen.TaskId = null,
    result: ?[]u8 = null,
    requests: usize = 0,
    presses: usize = 0,
    state: enum { ready, waiting, complete, closed, failed } = .ready,

    pub const Msg = union(enum) {
        pub const undelivered_policy = .deinit;
        search,
        close,
        probe,
        quit,
        loaded: struct { generation: usize, text: []u8 },
        failed: usize,

        pub fn deinitUndelivered(self: *Msg, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .loaded => |result| allocator.free(result.text),
                else => {},
            }
            self.* = undefined;
        }
    };

    const Task = struct {
        generation: usize,
        query: ?[]u8,
        counts: *Counts,

        fn run(self: *Task, _: std.mem.Allocator, io: std.Io) std.Io.Cancelable!Msg {
            try io.sleep(.fromSeconds(3), .awake);
            // The result takes the buffer; cleanup must no longer free it.
            const text = self.query.?;
            self.query = null;
            return .{ .loaded = .{ .generation = self.generation, .text = text } };
        }

        fn failed(self: *Task, _: chasen.TaskStartError, _: std.mem.Allocator) Msg {
            return .{ .failed = self.generation };
        }

        fn cleanup(self: *Task, allocator: std.mem.Allocator) void {
            const counts = self.counts;
            if (self.query) |query| allocator.free(query);
            allocator.destroy(self);
            // Run cleanup occurs on a worker; pending/start-failure cleanup can
            // occur on runtime. Shared observation therefore uses an atomic.
            _ = counts.cleaned.fetchAdd(1, .release);
        }
    };

    pub fn handleEvent(_: *const SearchDemo, event: chasen.Event) ?Msg {
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                ' ' => .search,
                'x' => .close,
                'p' => .probe,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *SearchDemo, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .search => {
                self.cancelCurrent(ctx);
                self.generation += 1;
                self.clearResult(ctx.allocator());
                const query = try std.fmt.allocPrint(ctx.allocator(), "Result for query #{d}", .{self.generation});
                const task = ctx.allocator().create(Task) catch |err| {
                    ctx.allocator().free(query);
                    return err;
                };
                task.* = .{ .generation = self.generation, .query = query, .counts = self.counts };
                self.counts.created += 1;
                self.active = ctx.task().spawnOwned(task, .{
                    .run = Task.run,
                    .failed = Task.failed,
                    .cleanup = Task.cleanup,
                }) catch |err| {
                    // Rejected admission leaves ownership with this caller.
                    task.cleanup(ctx.allocator());
                    return err;
                };
                self.state = .waiting;
            },
            .close => {
                self.cancelCurrent(ctx);
                self.generation += 1;
                self.clearResult(ctx.allocator());
                self.state = .closed;
            },
            .probe => self.presses += 1,
            .quit => ctx.quit(), // Shutdown requests cancellation and joins.
            .loaded => |result| {
                if (result.generation != self.generation or self.active == null) {
                    ctx.allocator().free(result.text); // Delivered stale Msg is ours.
                    return;
                }
                self.clearResult(ctx.allocator());
                self.result = result.text;
                self.active = null;
                self.state = .complete;
            },
            .failed => |generation| {
                if (generation != self.generation or self.active == null) return;
                self.active = null;
                self.state = .failed;
            },
        }
    }

    fn cancelCurrent(self: *SearchDemo, ctx: *chasen.Ctx(Msg)) void {
        if (self.active) |id| {
            ctx.task().requestCancel(id);
            self.requests += 1;
            self.active = null;
        }
    }

    fn clearResult(self: *SearchDemo, allocator: std.mem.Allocator) void {
        if (self.result) |text| allocator.free(text);
        self.result = null;
    }

    pub fn deinit(self: *SearchDemo, ctx: chasen.AppDeinitContext) void {
        self.clearResult(ctx.allocator);
    }

    pub fn view(self: *const SearchDemo, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("Owned search and cooperative cancellation", .{ .bold = true });
        col.borrowText("space: search/replace   x: close   p: probe/refresh   q: quit", .{ .dim = true });
        switch (self.state) {
            .ready => col.borrowText("Press space to start a three-second search.", .{}),
            .waiting => try col.print("Waiting for query #{d}...", .{self.generation}),
            .complete => col.borrowText(self.result.?, .{}),
            .closed => col.borrowText("Search closed. A later result will be ignored.", .{}),
            .failed => col.borrowText("The runtime could not start the search.", .{ .bold = true }),
        }
        try col.print("Probe presses: {d}   Cancel requests: {d}", .{ self.presses, self.requests });
        try col.print("Contexts created: {d}   Cleaned: {d}", .{ self.counts.created, self.counts.cleaned.load(.acquire) });
        col.borrowText("A cancel request does not mean the task has already stopped.", .{ .dim = true });
        col.borrowText("Press p to observe cleanup; q also works while waiting.", .{ .dim = true });
    }
};

pub fn main(init: std.process.Init) !void {
    var counts: Counts = .{};
    defer std.debug.print("Final contexts: created={d} cleaned={d}\n", .{ counts.created, counts.cleaned.load(.acquire) });
    try chasen.run(init, SearchDemo{ .counts = &counts });
}
