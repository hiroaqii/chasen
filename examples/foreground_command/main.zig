const std = @import("std");
const chasen = @import("chasen");

// Demonstrates running a foreground child process on /dev/tty while Chasen
// temporarily leaves the alternate screen.
const ForegroundCommandDemo = struct {
    env_map: *std.process.Environ.Map,
    last_result_buf: [128]u8 = undefined,
    last_result: []const u8 = "Press t/f/e to run a foreground command.",
    last_request_id: u64 = 0,

    pub const Msg = union(enum) {
        run_true,
        run_false,
        run_editor,
        foreground_done: chasen.ForegroundCommandResult,
        quit,
    };

    pub fn handleEvent(self: *const ForegroundCommandDemo, event: chasen.Event) ?Msg {
        _ = self;
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                't' => .run_true,
                'f' => .run_false,
                'e' => .run_editor,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *ForegroundCommandDemo, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .run_true => {
                try self.runForeground(ctx, &.{"true"}, "Running true...");
            },
            .run_false => {
                try self.runForeground(ctx, &.{"false"}, "Running false...");
            },
            .run_editor => {
                const editor = self.env_map.get("VISUAL") orelse
                    self.env_map.get("EDITOR") orelse
                    "vi";
                try self.runForeground(ctx, &.{editor}, "Running editor...");
            },
            .foreground_done => |result| {
                self.last_request_id = result.request_id.id;
                switch (result.outcome) {
                    .exited => |code| self.setLastResult("exited: {d}", .{code}),
                    .signaled => |signal| self.setLastResult("terminated by signal: {d}", .{signal}),
                    .spawn_failed => |err| self.setLastResult("spawn failed: {s}", .{err}),
                    .wait_failed => |err| self.setLastResult("wait failed: {s}", .{err}),
                }
            },
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const ForegroundCommandDemo, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("Foreground Command Example", .{ .bold = true });
        col.borrowText("t: true  f: false  e: $VISUAL/$EDITOR/vi  q: quit", .{ .fg = .gray });
        try col.print("last request id: {d}", .{self.last_request_id});
        col.borrowText(self.last_result, .{ .dim = true });
        col.borrowText("", .{});
        col.borrowText("The child runs on /dev/tty while Chasen temporarily leaves the alternate screen.", .{});
    }

    fn done(result: chasen.ForegroundCommandResult) Msg {
        return .{ .foreground_done = result };
    }

    fn runForeground(
        self: *ForegroundCommandDemo,
        ctx: *chasen.Ctx(Msg),
        argv: []const []const u8,
        running_text: []const u8,
    ) !void {
        const id = ctx.terminal().runForegroundCommand(.{
            .argv = argv,
            .finished = done,
        }) catch |err| switch (err) {
            error.ForegroundCommandLimitExceeded => {
                self.last_result = "foreground command already queued";
                return;
            },
            else => return err,
        };
        self.last_request_id = id.id;
        self.last_result = running_text;
    }

    fn setLastResult(self: *ForegroundCommandDemo, comptime fmt: []const u8, args: anytype) void {
        self.last_result = std.fmt.bufPrint(&self.last_result_buf, fmt, args) catch "result formatting failed";
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, ForegroundCommandDemo{ .env_map = init.environ_map });
}
