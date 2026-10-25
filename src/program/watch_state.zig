const std = @import("std");
const watch = @import("../watch.zig");

/// One payload-free reservation shared by all watches. Bound once, after the
/// owning Effects has reached stable storage. Queue full/Closed never loses state.
pub const Wake = struct {
    pending: std.atomic.Value(bool) = .init(false),
    context: ?*anyopaque = null,
    post: ?*const fn (*anyopaque) bool = null,

    pub fn request(self: *Wake) void {
        const post = self.post orelse return;
        if (self.pending.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
        if (!post(self.context.?)) self.pending.store(false, .release);
    }

    pub fn receive(self: *Wake) void {
        self.pending.store(false, .release);
    }
};

/// Native producers publish values here; only the runtime creates app messages.
/// The same lock covers publish and take/clear, including terminal health state.
pub const Mailbox = struct {
    io: std.Io,
    wake: *Wake,
    mutex: std.Io.Mutex = .init,
    ready: bool = false,
    ready_seen: bool = false,
    ready_delivered: bool = false,
    dirty: bool = false,
    rescan: bool = false,
    terminal: bool = false,
    failure: ?watch.WatchFailure = null,

    pub fn publish(self: *Mailbox, outcome: watch.WatchOutcome) void {
        self.mutex.lockUncancelable(self.io);
        var changed = false;
        if (!self.terminal) switch (outcome) {
            .ready => if (!self.ready_seen) {
                self.ready_seen = true;
                self.ready = true;
                changed = true;
            },
            .changed => if (!self.dirty) {
                self.dirty = true;
                changed = true;
            },
            .rescan => if (!self.rescan) {
                self.rescan = true;
                changed = true;
            },
            .failed => |failure| {
                self.terminal = true;
                self.failure = failure;
                self.ready = false;
                self.dirty = false;
                self.rescan = false;
                changed = true;
            },
        };
        self.mutex.unlock(self.io);
        if (changed) self.wake.request();
    }

    pub fn take(self: *Mailbox) ?watch.WatchOutcome {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.failure) |failure| {
            self.failure = null;
            return .{ .failed = failure };
        }
        if (self.ready) {
            self.ready = false;
            self.ready_delivered = true;
            return .ready;
        }
        if (!self.ready_delivered) return null;
        if (self.rescan) {
            self.rescan = false;
            self.dirty = false;
            return .rescan;
        }
        if (self.dirty) {
            self.dirty = false;
            return .changed;
        }
        return null;
    }

    pub fn hasPending(self: *Mailbox) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.failure != null or self.ready or (self.ready_delivered and (self.dirty or self.rescan));
    }
};

test "watch mailbox preserves ready and dirty and prioritizes terminal failure" {
    const Post = struct {
        fn post(ctx: *anyopaque) bool {
            const calls: *usize = @ptrCast(@alignCast(ctx));
            calls.* += 1;
            return true;
        }
    };
    var calls: usize = 0;
    var wake: Wake = .{ .context = &calls, .post = Post.post };
    var mailbox: Mailbox = .{ .io = std.testing.io, .wake = &wake };
    mailbox.publish(.changed);
    try std.testing.expect(mailbox.take() == null);
    mailbox.publish(.ready);
    for (0..1000) |_| mailbox.publish(.changed);
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expect(mailbox.take().? == .ready);
    try std.testing.expect(mailbox.take().? == .changed);
    wake.receive();
    mailbox.publish(.rescan);
    mailbox.publish(.{ .failed = .overflow });
    mailbox.publish(.changed);
    try std.testing.expectEqual(watch.WatchFailure.overflow, mailbox.take().?.failed);
    try std.testing.expect(mailbox.take() == null);
    try std.testing.expect(!mailbox.hasPending());
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "watch publish after take survives the clear" {
    const Producer = struct {
        mailbox: *Mailbox,
        ready: std.Io.Event = .unset,
        release: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            self.ready.set(std.testing.io);
            self.release.waitUncancelable(std.testing.io);
            self.mailbox.publish(.changed);
        }
    };
    var wake: Wake = .{};
    var mailbox: Mailbox = .{ .io = std.testing.io, .wake = &wake };
    mailbox.publish(.ready);
    _ = mailbox.take();
    mailbox.publish(.changed);
    var producer: Producer = .{ .mailbox = &mailbox };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    var joined = false;
    defer {
        producer.release.set(std.testing.io);
        if (!joined) thread.join();
    }
    producer.ready.waitUncancelable(std.testing.io);
    try std.testing.expect(mailbox.take().? == .changed);
    producer.release.set(std.testing.io);
    // join below establishes publication before the final assertion.
    thread.join();
    joined = true;
    try std.testing.expect(mailbox.take().? == .changed);
}
