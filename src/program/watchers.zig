const std = @import("std");
const vaxis = @import("vaxis");
const watch = @import("../watch.zig");
const requests_mod = @import("../requests.zig");
const types = @import("../program_types.zig");
const state = @import("watch_state.zig");
const max_watches = @import("../runtime_limits.zig").max_watches;

pub const Unsupported = struct {
    pub fn start(_: *@This(), _: std.mem.Allocator, _: std.Io, _: *const watch.OwnedInput, _: *state.Mailbox) ?watch.WatchFailure {
        return .unsupported;
    }
    pub fn requestStop(_: *@This()) void {}
    pub fn join(_: *@This()) void {}
};

pub const NativeBackend = Unsupported;

/// Internal compile-time seam: native and deterministic producers share this
/// exact owner and the production effect drain. Not a public runner option.
pub fn WatchRuntime(comptime Msg: type, comptime Backend: type) type {
    const Requests = requests_mod.Requests(Msg);
    const Notify = *const fn (watch.WatchNotice, std.mem.Allocator) ?Msg;
    const Delivery = struct { notice: watch.WatchNotice, notify: Notify };
    const Node = struct {
        id: u64,
        request_id: watch.WatchRequestId,
        notify: Notify,
        input: watch.OwnedInput,
        mailbox: state.Mailbox,
        backend: Backend = .{},
    };
    return struct {
        const Self = @This();
        allocator: std.mem.Allocator,
        nodes: [max_watches]?*Node = @splat(null),
        failures: [max_watches]?Delivery = @splat(null),
        wake: state.Wake = .{},
        next_slot: usize = 0,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        fn postWake(context: *anyopaque) bool {
            const loop: *vaxis.Loop(types.InternalEvent(Msg)) = @ptrCast(@alignCast(context));
            return loop.tryPostEvent(.watches_pending) catch false;
        }

        fn current(requests: *const Requests, index: usize, request_id: watch.WatchRequestId) bool {
            const desired = requests._watches[index] orelse return false;
            return desired.request_id == request_id;
        }

        pub fn reconcile(self: *Self, requests: *Requests, loop: *vaxis.Loop(types.InternalEvent(Msg))) void {
            // This is written once before any producer receives the pointer.
            if (self.wake.context == null) {
                self.wake.context = loop;
                self.wake.post = postWake;
            } else std.debug.assert(self.wake.context.? == @as(*anyopaque, @ptrCast(loop)));
            if (requests.shouldQuit()) {
                self.shutdown();
                requests.discardWatches();
                return;
            }
            // Broadcast every stale stop before the first stale join.
            for (self.nodes, 0..) |maybe_node, i| if (maybe_node) |node| {
                if (!current(requests, i, node.request_id)) node.backend.requestStop();
            };
            for (&self.nodes, 0..) |*maybe_node, i| if (maybe_node.*) |node| {
                if (!current(requests, i, node.request_id)) self.release(i);
            };
            for (&self.failures, 0..) |*failure, i| if (failure.*) |value| {
                if (!current(requests, i, value.notice.request_id)) failure.* = null;
            };

            for (&requests._watches, 0..) |*maybe_desired, i| {
                const desired = if (maybe_desired.*) |*value| value else continue;
                const input = desired.pending orelse continue;
                desired.pending = null;
                std.debug.assert(self.nodes[i] == null and self.failures[i] == null);
                const node = self.allocator.create(Node) catch {
                    var owned = input;
                    owned.deinit(self.allocator);
                    self.failures[i] = .{
                        .notice = .{ .id = desired.id, .request_id = desired.request_id, .outcome = .{ .failed = .out_of_memory } },
                        .notify = desired.notify,
                    };
                    self.wake.request();
                    continue;
                };
                node.* = .{
                    .id = desired.id,
                    .request_id = desired.request_id,
                    .notify = desired.notify,
                    .input = input,
                    .mailbox = .{ .io = requests.io(), .wake = &self.wake },
                };
                self.nodes[i] = node;
                if (node.backend.start(self.allocator, requests.io(), &node.input, &node.mailbox)) |failure|
                    node.mailbox.publish(.{ .failed = failure });
            }
        }

        /// Revalidate before constructing a Msg. Terminal delivery relinquishes
        /// the old generation first, so its update can safely start the same id.
        pub fn take(self: *Self, requests: *Requests) ?Delivery {
            if (requests.shouldQuit()) return null;
            for (0..max_watches) |offset| {
                const i = (self.next_slot + offset) % max_watches;
                const delivery: Delivery = if (self.failures[i]) |failure| failure else blk: {
                    const node = self.nodes[i] orelse continue;
                    if (!current(requests, i, node.request_id)) continue;
                    const outcome = node.mailbox.take() orelse continue;
                    break :blk .{
                        .notice = .{ .id = node.id, .request_id = node.request_id, .outcome = outcome },
                        .notify = node.notify,
                    };
                };
                if (!current(requests, i, delivery.notice.request_id)) continue;
                self.next_slot = (i + 1) % max_watches;
                if (delivery.notice.outcome == .failed) {
                    if (self.nodes[i]) |node| node.backend.requestStop();
                    self.release(i);
                    self.failures[i] = null;
                    requests.watch().cancel(delivery.notice.id);
                }
                return delivery;
            }
            return null;
        }

        pub fn hasPending(self: *Self) bool {
            for (self.failures) |failure| if (failure != null) return true;
            for (self.nodes) |maybe_node| if (maybe_node) |node| {
                if (node.mailbox.hasPending()) return true;
            };
            return false;
        }

        pub fn rearm(self: *Self) void {
            if (self.hasPending()) self.wake.request();
        }

        pub fn requestStop(self: *Self) void {
            for (self.nodes) |maybe_node| if (maybe_node) |node| node.backend.requestStop();
        }

        pub fn shutdown(self: *Self) void {
            self.requestStop();
            for (0..max_watches) |i| self.release(i);
            self.failures = @splat(null);
        }

        fn release(self: *Self, index: usize) void {
            const node = self.nodes[index] orelse return;
            node.backend.join();
            node.input.deinit(self.allocator);
            self.allocator.destroy(node);
            self.nodes[index] = null;
        }
    };
}

/// Test-only producer; held at the existing private backend seam.
pub const TestBackend = struct {
    mailbox: ?*state.Mailbox = null,
    stopped: bool = false,
    pub var live: [max_watches]?*TestBackend = @splat(null);
    pub var starts: usize = 0;
    pub var stops: usize = 0;
    pub var joins: usize = 0;
    pub var on_stop: ?watch.WatchOutcome = null;
    pub var require_all_stopped: bool = false;
    pub var stopped_event: ?*std.Io.Event = null;
    pub var start_failure: ?watch.WatchFailure = null;

    pub fn reset() void {
        for (live) |node| std.debug.assert(node == null);
        starts = 0;
        stops = 0;
        joins = 0;
        on_stop = null;
        require_all_stopped = false;
        stopped_event = null;
        start_failure = null;
    }

    pub fn start(self: *TestBackend, _: std.mem.Allocator, _: std.Io, _: *const watch.OwnedInput, mailbox: *state.Mailbox) ?watch.WatchFailure {
        self.mailbox = mailbox;
        for (&live) |*node| if (node.* == null) {
            node.* = self;
            starts += 1;
            if (start_failure) |failure| return failure;
            mailbox.publish(.ready);
            return null;
        };
        unreachable;
    }

    pub fn requestStop(self: *TestBackend) void {
        if (self.stopped) return;
        self.stopped = true;
        stops += 1;
        if (stopped_event) |event| event.set(self.mailbox.?.io);
        if (on_stop) |outcome| self.mailbox.?.publish(outcome);
    }

    pub fn join(self: *TestBackend) void {
        std.debug.assert(self.stopped);
        if (require_all_stopped) for (live) |node| {
            if (node) |value| std.debug.assert(value.stopped);
        };
        for (&live) |*node| if (node.* == self) {
            node.* = null;
            joins += 1;
            return;
        };
        unreachable;
    }
};

test "watch unused owner allocates nothing and starts no producer or wake" {
    const Msg = enum {
        value,
        pub const undelivered_policy = .plain;
    };
    TestBackend.reset();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var requests = requests_mod.Requests(Msg).init(failing.allocator(), std.testing.io);
    defer requests.deinit();
    var owner = WatchRuntime(Msg, TestBackend).init(failing.allocator());
    defer owner.shutdown();
    var loop = vaxis.Loop(types.InternalEvent(Msg)).init(std.testing.io, undefined, undefined);
    owner.reconcile(&requests, &loop);
    try std.testing.expect(owner.take(&requests) == null);
    try std.testing.expect((try loop.tryEvent()) == null);
    try std.testing.expectEqual(@as(usize, 0), TestBackend.starts);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}
