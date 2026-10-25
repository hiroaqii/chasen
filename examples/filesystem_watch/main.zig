const std = @import("std");
const chasen = @import("chasen");

const watch_id: u64 = 1;
const root = "watch-demo";
const file = root ++ "/message.txt";

const WatchDemo = struct {
    watch_status: []const u8 = "not started",
    read_status: []const u8 = "waiting for ready",
    bytes: [4096]u8 = undefined,
    bytes_read: usize = 0,
    reads: usize = 0,

    pub const Msg = union(enum) {
        pub const undelivered_policy = .plain;
        watch: chasen.WatchNotice,
        start,
        cancel,
        refresh,
        quit,
    };

    pub fn init(self: *WatchDemo, ctx: *chasen.Ctx(Msg)) !void {
        self.start(ctx);
    }

    fn start(self: *WatchDemo, ctx: *chasen.Ctx(Msg)) void {
        _ = ctx.watch().start(watch_id, .{
            .path = root,
            .select = "message.txt",
            // Remove select to observe all entries except this subtree.
            // Exclusions do not prune registrations or hide coarse rescan.
            .exclude = &.{.{ .subtree = "ignored" }},
        }, watchNotice) catch |err| {
            self.watch_status = @errorName(err); // A rejected start preserves the old watch.
            return;
        };
        self.watch_status = "starting (accepted, not yet ready)";
    }

    fn watchNotice(notice: chasen.WatchNotice, _: std.mem.Allocator) ?Msg {
        return .{ .watch = notice };
    }

    pub fn handleEvent(_: *const WatchDemo, event: chasen.Event) ?Msg {
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                's' => .start,
                'c' => .cancel,
                'r' => .refresh,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }

    pub fn update(self: *WatchDemo, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        switch (msg) {
            .watch => |notice| switch (notice.outcome) {
                .ready, .changed, .rescan => {
                    self.watch_status = @tagName(notice.outcome);
                    // Read after coverage is ready. A later dirty notice prompts another read.
                    self.refresh(ctx);
                },
                .failed => |reason| {
                    self.watch_status = @tagName(reason);
                    // This generation has ended. The user chooses s (new start) or r (manual read).
                },
            },
            .start => self.start(ctx),
            .cancel => {
                ctx.watch().cancel(watch_id);
                self.watch_status = "cancelled";
            },
            .refresh => self.refresh(ctx),
            .quit => ctx.quit(),
        }
    }

    fn refresh(self: *WatchDemo, ctx: *chasen.Ctx(Msg)) void {
        self.reads += 1;
        self.bytes_read = 0;
        // A bounded local-file read keeps this demo small. Use a task for slow I/O;
        // the app must retain dirty notices arriving while that read is in flight.
        const contents = std.Io.Dir.cwd().readFile(ctx.io(), file, &self.bytes) catch |err| {
            self.read_status = @errorName(err);
            return;
        };
        self.bytes_read = contents.len;
        self.read_status = if (contents.len == self.bytes.len) "read prefix (file may be larger)" else "read complete";
    }

    pub fn view(self: *const WatchDemo, sfc: *chasen.Surface) !void {
        var col = sfc.column(.{ .gap = 1 });
        col.borrowText("Filesystem watch (Linux)", .{ .bold = true });
        col.borrowText("s: start/replace  c: cancel  r: manual read  q: quit", .{ .fg = .gray });
        col.borrowText("Edit watch-demo/message.txt from another terminal.", .{});
        try col.print("watch: {s} | read: {s}", .{ self.watch_status, self.read_status });
        try col.print("read attempts: {d} | last bytes read: {d}", .{ self.reads, self.bytes_read });
        col.borrowText("After failure, choose s to retry or r to read without watching.", .{ .dim = true });
    }
};

pub fn main(init: std.process.Init) !void {
    try chasen.run(init, WatchDemo{});
}
