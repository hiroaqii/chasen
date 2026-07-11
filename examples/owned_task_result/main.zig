const std = @import("std");
const chasen = @import("chasen");

/// Shows the ownership contract for an allocator-backed async task result.
const OwnedTaskResult = struct {
    text: ?[]u8 = null,
    loading: bool = false,
    failure: ?Failure = null,

    const Failure = enum {
        allocation_failed,
        task_start_failed,
        runtime_abandoned,
    };

    pub const Msg = union(enum) {
        // Chasen validates this declaration at compile time. Unlike `.plain`,
        // `.deinit` requires the exact deinitUndelivered hook below.
        pub const undelivered_policy = .deinit;

        load,
        loaded: []u8,
        failed: Failure,
        quit,

        /// Releases a message that shutdown prevents from reaching update.
        /// Once update receives `.loaded`, the application owns the bytes and
        /// this hook is no longer called for that message.
        pub fn deinitUndelivered(self: *Msg, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .loaded => |bytes| allocator.free(bytes),
                .load, .failed, .quit => {},
            }
            self.* = undefined;
        }
    };

    pub fn handleEvent(_: *const OwnedTaskResult, event: chasen.Event) ?Msg {
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                ' ' => .load,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *OwnedTaskResult, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .load => {
                if (self.loading) return;
                self.loading = true;
                self.failure = null;
                try ctx.task().spawn(.{ .run = loadText, .failed = loadFailed });
            },
            .loaded => |bytes| {
                if (self.text) |old| ctx.allocator().free(old);
                self.text = bytes;
                self.loading = false;
            },
            .failed => |failure| {
                self.loading = false;
                self.failure = failure;
            },
            .quit => ctx.quit(),
        }
    }

    pub fn deinit(self: *OwnedTaskResult, ctx: chasen.AppDeinitContext) void {
        if (self.text) |bytes| ctx.allocator.free(bytes);
        self.* = undefined;
    }

    pub fn view(self: *const OwnedTaskResult, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("Owned Task Result", .{ .bold = true });

        if (self.loading) {
            col.borrowText("Loading allocator-owned text...", .{ .fg = .gray });
        } else if (self.text) |text| {
            col.borrowText(text, .{});
        } else if (self.failure) |failure| {
            try col.print("Task failed: {s}", .{@tagName(failure)});
        } else {
            col.borrowText("Press space to start the task.", .{ .fg = .gray });
        }

        col.borrowText("space: load  q: quit", .{ .dim = true });
    }

    fn loadText(allocator: std.mem.Allocator, io: std.Io) Msg {
        io.sleep(.fromMilliseconds(250), .awake) catch {};
        const text = allocator.dupe(u8, "This text is owned by the task result.") catch {
            return .{ .failed = .allocation_failed };
        };
        return .{ .loaded = text };
    }

    fn loadFailed(failure: chasen.TaskFailure) Msg {
        return .{
            .failed = switch (failure) {
                .start_failed => .task_start_failed,
                // A queued task can be abandoned during runtime unwind. Chasen
                // immediately passes this result to deinitUndelivered.
                .runtime_abandoned => .runtime_abandoned,
            },
        };
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, OwnedTaskResult{});
}
