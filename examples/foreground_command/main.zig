const std = @import("std");
const chasen = @import("chasen");

// Demonstrates running a foreground child process on /dev/tty while Chasen
// temporarily leaves the alternate screen.
const ForegroundCommandDemo = struct {
    env_map: *std.process.Environ.Map,
    last_result_buf: [128]u8 = undefined,
    last_result: []const u8 = "Press t/f/r/e to run a foreground command.",
    last_request_id: u64 = 0,
    input_events: usize = 0,
    paste_bytes: usize = 0,

    pub const Msg = union(enum) {
        pub const undelivered_policy = .plain;

        run_true,
        run_false,
        run_editor,
        run_read,
        input_seen,
        pasted: usize,
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
                'r' => .run_read,
                'q' => .quit,
                else => null,
            },
            .mouse, .winsize, .focus_in, .focus_out => .input_seen,
            .paste => |bytes| .{ .pasted = bytes.len },
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
            .run_read => {
                if (self.env_map.get("CHASEN_FOREGROUND_HELPER")) |helper| {
                    try self.runForeground(ctx, &.{ helper, "--child", "exit" }, "Type text then Enter, or Ctrl-C / Ctrl-Z.");
                } else try self.runForeground(ctx, &.{ "sleep", "600" }, "Interrupt sleep with Ctrl-C / Ctrl-Z.");
            },
            .run_editor => {
                const editor = self.env_map.get("VISUAL") orelse
                    self.env_map.get("EDITOR") orelse
                    "vi";
                if (self.env_map.get("CHASEN_FOREGROUND_FILE")) |file| {
                    try self.runForeground(ctx, &.{ editor, file }, "Running editor...");
                } else try self.runForeground(ctx, &.{editor}, "Running editor...");
            },
            .foreground_done => |result| {
                self.last_request_id = result.request_id.id;
                switch (result.outcome) {
                    .exited => |code| self.setLastResult("exited: {d}", .{code}),
                    .signaled => |signal| self.setLastResult("terminated by signal: {d}", .{signal}),
                    .stopped => |sig| self.setLastResult("stopped and terminated: {d}", .{sig}),
                    .failed => |f| self.setLastResult("{s} failed: {s}", .{ @tagName(f.stage), f.error_name }),
                    .runtime_abandoned => {},
                }
            },
            .input_seen => self.input_events += 1,
            .pasted => |count| self.paste_bytes = count,
            .quit => ctx.quit(),
        }
    }

    pub fn view(self: *const ForegroundCommandDemo, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("Foreground Command Example", .{ .bold = true });
        col.borrowText("t: true  f: false  r: read/interrupt  e: $VISUAL/$EDITOR/vi  q: quit", .{ .fg = .gray });
        try col.print("last request id: {d}", .{self.last_request_id});
        col.borrowText(self.last_result, .{ .dim = true });
        try col.print("mouse/resize/focus events: {d}  last paste bytes: {d}", .{ self.input_events, self.paste_bytes });
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
            .cwd = .inherit,
            .environment = .inherit,
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
    try chasen.runWith(.{
        .runtime = .{ .allocator = init.gpa, .io = init.io },
        .terminal = .{ .env_map = init.environ_map, .mouse = true, .keyboard_protocol = if (init.environ_map.get("CHASEN_FOREGROUND_KITTY") != null) .kitty else .legacy },
    }, ForegroundCommandDemo{ .env_map = init.environ_map });
}
