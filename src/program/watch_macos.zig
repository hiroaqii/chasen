const std = @import("std");
const builtin = @import("builtin");
const watch = @import("../watch.zig");
const state = @import("watch_state.zig");

// The small ABI surface is confined here; the portable runtime needs no SDK
// headers. Signatures and flags follow CoreFoundation/FSEvents/dispatch headers.
const native = struct {
    const Ref = *opaque {};
    const Context = extern struct {
        version: isize = 0,
        info: ?*anyopaque,
        retain: ?*const fn (?*const anyopaque) callconv(.c) ?*const anyopaque = null,
        release: ?*const fn (?*const anyopaque) callconv(.c) void = null,
        copy_description: ?*const fn (?*const anyopaque) callconv(.c) ?Ref = null,
    };
    const ArrayCallbacks = extern struct {
        version: isize,
        retain: ?*const anyopaque,
        release: ?*const anyopaque,
        copy_description: ?*const anyopaque,
        equal: ?*const anyopaque,
    };
    const Callback = *const fn (Ref, ?*anyopaque, usize, ?*anyopaque, [*]const u32, [*]const u64) callconv(.c) void;
    extern const kCFTypeArrayCallBacks: ArrayCallbacks;
    extern fn CFStringCreateWithFileSystemRepresentation(?Ref, [*:0]const u8) ?Ref;
    extern fn CFArrayCreate(?Ref, [*]const Ref, isize, *const ArrayCallbacks) ?Ref;
    extern fn CFRelease(Ref) void;
    extern fn FSEventStreamCreate(?Ref, Callback, *Context, Ref, u64, f64, u32) ?Ref;
    extern fn FSEventStreamSetDispatchQueue(Ref, Ref) void;
    extern fn FSEventStreamStart(Ref) u8;
    extern fn FSEventStreamStop(Ref) void;
    extern fn FSEventStreamInvalidate(Ref) void;
    extern fn FSEventStreamRelease(Ref) void;
    extern fn FSEventStreamFlushSync(Ref) void;
    extern fn dispatch_queue_create([*:0]const u8, ?Ref) ?Ref;
    extern fn dispatch_sync_f(Ref, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
    extern fn dispatch_release(Ref) void;
};

const must_scan: u32 = 0x1;
const dropped: u32 = 0x2 | 0x4;
const wrapped: u32 = 0x8;
const history_done: u32 = 0x10;
const root_changed: u32 = 0x20;
const mount_changed: u32 = 0x40 | 0x80;
const is_file: u32 = 0x10000;
const is_dir: u32 = 0x20000;
const is_symlink: u32 = 0x40000;
const known_flags: u32 = 0x7fffff;
const max_events = 65536;
const max_batch_bytes = 1024 * 1024;
const Identity = struct { dev: i32, ino: u64 };
const Ancestor = struct { end: usize, identity: Identity };

/// Stable inside the runtime's live Node. Only the serial queue touches failed;
/// only the runtime touches stream/queue lifecycle. stopping crosses the boundary.
pub const Backend = struct {
    io: std.Io = undefined,
    input: *const watch.OwnedInput = undefined,
    mailbox: *state.Mailbox = undefined,
    stream: ?native.Ref = null,
    queue: ?native.Ref = null,
    started: bool = false,
    scheduled: bool = false,
    stopping: std.atomic.Value(bool) = .init(false),
    failed: bool = false,
    root: [watch.max_path_bytes + 1]u8 = undefined,
    root_len: usize = 0,
    ancestors: [watch.max_depth + 1]Ancestor = undefined,
    ancestors_len: usize = 0,
    hooks: if (builtin.is_test) ?*TestHooks else void = if (builtin.is_test) null else {},

    pub fn start(self: *Backend, _: std.mem.Allocator, io: std.Io, input: *const watch.OwnedInput, mailbox: *state.Mailbox) ?watch.WatchFailure {
        self.io = io;
        self.input = input;
        self.mailbox = mailbox;
        if (!std.unicode.utf8ValidateSlice(input.path)) return .unsupported;
        if (input.select) |selection| if (!std.unicode.utf8ValidateSlice(selection)) return .unsupported;
        for (input.exclusions[0..input.exclusions_len]) |rule| {
            const path = switch (rule) {
                inline else => |p| p,
            };
            if (!std.unicode.utf8ValidateSlice(path)) return .unsupported;
        }
        const opened = std.Io.Dir.cwd().openDir(io, input.path, .{}) catch |err| return ioFailure(err);
        self.acquired(.root);
        defer {
            opened.close(io);
            self.released(.root);
        }
        var info: std.c.Stat = undefined;
        if (std.c.fstat(opened.handle, &info) != 0) return systemFailure();
        const opened_identity = identity(info);
        self.root_len = opened.realPath(io, self.root[0..watch.max_path_bytes]) catch |err| return ioFailure(err);
        self.root[self.root_len] = 0;
        if (!boundedPath(self.rootPath())) return .resource_limit;
        if (!std.unicode.utf8ValidateSlice(self.rootPath())) return .unsupported;
        // Snapshot every canonical ancestor before enabling WatchRoot. No fd is
        // retained in the Backend, and no path can grow past the fixed buffer.
        if (self.captureAncestor(1)) |failure| return failure;
        for (self.rootPath()[1..], 1..) |byte, i| if (byte == '/') {
            if (self.captureAncestor(i)) |failure| return failure;
        };
        if (self.root_len > 1) if (self.captureAncestor(self.root_len)) |failure| return failure;
        if (!std.meta.eql(opened_identity, self.ancestors[self.ancestors_len - 1].identity)) return .root_lost;

        if (self.inject(.root)) return .out_of_memory;
        const string = native.CFStringCreateWithFileSystemRepresentation(null, self.rootPath()) orelse return .out_of_memory;
        self.acquired(.string);
        defer {
            native.CFRelease(string);
            self.released(.string);
        }
        if (self.inject(.string)) return .out_of_memory;
        const array = native.CFArrayCreate(null, &.{string}, 1, &native.kCFTypeArrayCallBacks) orelse return .out_of_memory;
        self.acquired(.array);
        defer {
            native.CFRelease(array);
            self.released(.array);
        }
        if (self.inject(.array)) return .out_of_memory;
        var context: native.Context = .{ .info = self };
        self.stream = native.FSEventStreamCreate(null, callback, &context, array, std.math.maxInt(u64), 0.05, 0x4 | 0x10 | 0x2) orelse return .io_failure;
        self.acquired(.stream);
        if (self.inject(.stream)) return .worker_unavailable;
        self.queue = native.dispatch_queue_create("chasen.filesystem-watch", null) orelse return .worker_unavailable;
        self.acquired(.queue);
        if (self.inject(.queue)) return .worker_unavailable;
        native.FSEventStreamSetDispatchQueue(self.stream.?, self.queue.?);
        self.scheduled = true;
        // The scheduled-but-not-started state also covers Start returning false.
        if (self.inject(.scheduled) or native.FSEventStreamStart(self.stream.?) == 0) return .io_failure;
        self.started = true;
        if (self.inject(.started)) return .io_failure;
        if (!self.validRoot()) return .root_lost;
        mailbox.publish(.ready);
        return null;
    }

    pub fn requestStop(self: *Backend) void {
        if (self.stopping.swap(true, .acq_rel)) return;
        if (self.started) {
            native.FSEventStreamStop(self.stream.?);
            self.started = false;
        }
        if (self.scheduled) {
            native.FSEventStreamInvalidate(self.stream.?);
            self.scheduled = false;
        }
    }

    pub fn join(self: *Backend) void {
        if (self.queue) |queue| native.dispatch_sync_f(queue, null, noop);
        if (self.stream) |stream| {
            native.FSEventStreamRelease(stream);
            self.stream = null;
            self.released(.stream);
        }
        if (self.queue) |queue| {
            native.dispatch_sync_f(queue, null, noop);
            native.dispatch_release(queue);
            self.queue = null;
            self.released(.queue);
        }
    }

    fn rootPath(self: *const Backend) [:0]const u8 {
        return self.root[0..self.root_len :0];
    }

    fn captureAncestor(self: *Backend, end: usize) ?watch.WatchFailure {
        if (self.ancestors_len == self.ancestors.len) return .resource_limit;
        const old = self.root[end];
        self.root[end] = 0;
        defer self.root[end] = old;
        var info: std.c.Stat = undefined;
        if (std.c.fstatat(std.c.AT.FDCWD, self.root[0..end :0], &info, std.c.AT.SYMLINK_NOFOLLOW) != 0) return systemFailure();
        if (info.mode & std.c.S.IFMT != std.c.S.IFDIR) return .root_lost;
        self.ancestors[self.ancestors_len] = .{ .end = end, .identity = identity(info) };
        self.ancestors_len += 1;
        return null;
    }

    fn validRoot(self: *const Backend) bool {
        var path: [watch.max_path_bytes + 1]u8 = undefined;
        @memcpy(path[0..self.root_len], self.rootPath());
        path[self.root_len] = 0;
        for (self.ancestors[0..self.ancestors_len]) |ancestor| {
            const old = path[ancestor.end];
            path[ancestor.end] = 0;
            var info: std.c.Stat = undefined;
            const rc = std.c.fstatat(std.c.AT.FDCWD, path[0..ancestor.end :0], &info, std.c.AT.SYMLINK_NOFOLLOW);
            path[ancestor.end] = old;
            if (rc != 0 or info.mode & std.c.S.IFMT != std.c.S.IFDIR or !std.meta.eql(identity(info), ancestor.identity)) return false;
        }
        return true;
    }

    fn callback(_: native.Ref, context: ?*anyopaque, count: usize, raw_paths: ?*anyopaque, flags: [*]const u32, _: [*]const u64) callconv(.c) void {
        const self: *Backend = @ptrCast(@alignCast(context.?));
        if (self.stopping.load(.acquire) or self.failed) return;
        if (builtin.is_test) if (self.hooks) |hooks| {
            if (hooks.hold.swap(false, .acq_rel)) {
                hooks.entered.set(self.io);
                hooks.release.waitUncancelable(self.io);
                hooks.exited.set(self.io);
            }
        };
        if (self.stopping.load(.acquire)) return;
        if (count > max_events) return self.fail(.resource_limit);
        if (!self.validRoot()) return self.fail(.root_lost);
        if (count == 0) return;
        const paths: [*]const [*:0]const u8 = @ptrCast(@alignCast(raw_paths orelse return self.fail(.coverage_lost)));
        var bytes: usize = 0;
        for (0..count) |i| {
            if (self.stopping.load(.acquire)) return;
            // Fault/health flags take precedence even when the path is absent,
            // excluded, oversized, or a HistoryDone sentinel.
            if (flagFailure(flags[i])) |failure| return self.fail(failure);
            if (flags[i] == history_done) continue;
            var len: usize = 0;
            while (len <= watch.max_path_bytes and paths[i][len] != 0) : (len += 1) {}
            bytes += len;
            if (len > watch.max_path_bytes or bytes > max_batch_bytes or !boundedPath(paths[i][0..len])) return self.fail(.resource_limit);
            if (self.classify(paths[i][0..len], flags[i])) |outcome| self.mailbox.publish(outcome);
        }
    }

    fn fail(self: *Backend, failure: watch.WatchFailure) void {
        self.failed = true;
        self.mailbox.publish(.{ .failed = failure });
    }

    fn classify(self: *const Backend, path: []const u8, flags: u32) ?watch.WatchOutcome {
        if (flagFailure(flags)) |failure| return .{ .failed = failure };
        if (flags == history_done) return null;
        if (flags & must_scan != 0 or flags & (is_file | is_symlink) == 0 or flags & is_dir != 0) return .rescan;
        const root = self.rootPath();
        const relative = if (root.len == 1 and std.mem.startsWith(u8, path, "/")) path[1..] else blk: {
            if (!watch.within(path, root) or path.len <= root.len) return .rescan;
            break :blk path[root.len + 1 ..];
        };
        if (!ascii(path)) return .rescan;
        if (self.input.select) |selection| {
            if (!ascii(selection)) return .rescan;
            if (!std.mem.eql(u8, relative, selection) and std.ascii.eqlIgnoreCase(relative, selection)) return .rescan;
        }
        for (self.input.exclusions[0..self.input.exclusions_len]) |rule| {
            const excluded = switch (rule) {
                inline else => |p| p,
            };
            if (!ascii(excluded)) return .rescan;
            const candidate = if (rule == .subtree and relative.len > excluded.len and relative[excluded.len] == '/') relative[0..excluded.len] else relative;
            if (!std.mem.eql(u8, candidate, excluded) and std.ascii.eqlIgnoreCase(candidate, excluded)) return .rescan;
        }
        if (!self.input.recursive and std.mem.indexOfScalar(u8, relative, '/') != null) return null;
        if (!self.input.selected(relative)) return null;
        return .changed;
    }

    fn acquired(self: *Backend, resource: Resource) void {
        if (builtin.is_test) if (self.hooks) |hooks| {
            hooks.acquired[@intFromEnum(resource)] += 1;
        };
    }
    fn released(self: *Backend, resource: Resource) void {
        if (builtin.is_test) if (self.hooks) |hooks| {
            hooks.released[@intFromEnum(resource)] += 1;
        };
    }
    fn inject(self: *Backend, stage: Stage) bool {
        return if (builtin.is_test) if (self.hooks) |hooks| hooks.failure == stage else false else false;
    }
};

fn noop(_: ?*anyopaque) callconv(.c) void {}
fn identity(info: std.c.Stat) Identity {
    return .{ .dev = info.dev, .ino = info.ino };
}
fn ascii(path: []const u8) bool {
    for (path) |byte| if (byte >= 128) return false;
    return true;
}
fn boundedPath(path: []const u8) bool {
    if (path.len == 0 or path.len > watch.max_path_bytes) return false;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    var depth: usize = 0;
    while (parts.next() != null) {
        depth += 1;
        if (depth > watch.max_depth) return false;
    }
    return true;
}
fn flagFailure(flags: u32) ?watch.WatchFailure {
    if (flags & root_changed != 0) return .root_lost;
    if (flags & dropped != 0) return .overflow;
    if (flags & (wrapped | mount_changed | ~known_flags) != 0) return .coverage_lost;
    return null;
}
fn systemFailure() watch.WatchFailure {
    return switch (std.c.errno(@as(c_int, -1))) {
        .NOENT => .path_not_found,
        .NOTDIR => .not_directory,
        .ACCES, .PERM => .access_denied,
        .NOMEM => .out_of_memory,
        .MFILE, .NFILE, .NOSPC, .NAMETOOLONG => .resource_limit,
        else => .io_failure,
    };
}
fn ioFailure(err: anyerror) watch.WatchFailure {
    return switch (err) {
        error.FileNotFound => .path_not_found,
        error.NotDir => .not_directory,
        error.AccessDenied => .access_denied,
        error.OutOfMemory => .out_of_memory,
        error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources, error.NameTooLong => .resource_limit,
        else => .io_failure,
    };
}

// Test-only stage faults and one callback barrier; no alternative backend or
// public injection interface. Counters track only references Chasen owns.
const Resource = enum { root, string, array, stream, queue };
const Stage = enum { root, string, array, stream, queue, scheduled, started };
const TestHooks = struct {
    failure: ?Stage = null,
    acquired: [5]usize = @splat(0),
    released: [5]usize = @splat(0),
    hold: std.atomic.Value(bool) = .init(false),
    entered: std.Io.Event = .unset,
    release: std.Io.Event = .unset,
    exited: std.Io.Event = .unset,
};

pub const TestDirectory = struct {
    parent: std.Io.Dir,
    dir: std.Io.Dir,
    name: [32]u8,
    path: [:0]u8,

    pub fn init() !TestDirectory {
        const io = std.testing.io;
        const parent = try std.Io.Dir.cwd().createDirPathOpen(io, std.testing.environ.getPosix("TMPDIR") orelse ".zig-cache/tmp", .{});
        errdefer parent.close(io);
        var random: [16]u8 = undefined;
        io.random(&random);
        const name = std.fmt.bytesToHex(random, .lower);
        try parent.createDir(io, &name, .default_dir);
        errdefer parent.deleteTree(io, &name) catch {};
        const dir = try parent.openDir(io, &name, .{});
        errdefer dir.close(io);
        const path = try parent.realPathFileAlloc(io, &name, std.testing.allocator);
        return .{ .parent = parent, .dir = dir, .name = name, .path = path };
    }
    pub fn deinit(self: *TestDirectory) void {
        self.dir.close(std.testing.io);
        self.parent.deleteTree(std.testing.io, &self.name) catch unreachable;
        self.parent.close(std.testing.io);
        std.testing.allocator.free(self.path);
    }
};

const TestWatch = struct {
    input: watch.OwnedInput = undefined,
    wake: state.Wake = .{},
    mailbox: state.Mailbox = undefined,
    backend: Backend = .{},

    fn init(self: *TestWatch, options: watch.WatchOptions, hooks: ?*TestHooks) !void {
        self.input = try .init(std.testing.allocator, options);
        self.mailbox = .{ .io = std.testing.io, .wake = &self.wake };
        self.backend = .{ .hooks = hooks };
        if (self.backend.start(std.testing.allocator, std.testing.io, &self.input, &self.mailbox)) |failure|
            self.mailbox.publish(.{ .failed = failure });
    }
    fn deinit(self: *TestWatch) void {
        if (self.backend.hooks) |hooks| hooks.release.set(std.testing.io);
        self.backend.requestStop();
        self.backend.join();
        self.input.deinit(std.testing.allocator);
    }
    fn ready(self: *TestWatch) !void {
        try std.testing.expect(self.mailbox.take().? == .ready);
        self.flush();
        while (self.mailbox.take()) |outcome| try std.testing.expect(outcome != .failed);
    }
    fn flush(self: *TestWatch) void {
        if (self.backend.started) native.FSEventStreamFlushSync(self.backend.stream.?);
        if (self.backend.queue) |queue| native.dispatch_sync_f(queue, null, noop);
    }
    fn changed(self: *TestWatch) !watch.WatchOutcome {
        // Flush is a test barrier, never a production readiness/shutdown rule.
        for (0..500) |_| {
            self.flush();
            if (self.mailbox.take()) |outcome| {
                try std.testing.expect(outcome == .changed or outcome == .rescan);
                return outcome;
            }
            try std.Io.sleep(std.testing.io, .fromMilliseconds(10), .awake);
        }
        return error.WatchNoticeTimedOut;
    }
};

test "watch macos native changes cover initial read atomic replacement and subtree moves" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    try fixture.dir.createDirPath(io, "root/existing/deep");
    try fixture.dir.createDirPath(io, "incoming/deep");
    try fixture.dir.writeFile(io, .{ .sub_path = "root/config", .data = "before" });
    const root = try fixture.dir.realPathFileAlloc(io, "root", std.testing.allocator);
    defer std.testing.allocator.free(root);
    var live: TestWatch = .{};
    try live.init(.{ .path = root }, null);
    defer live.deinit();
    try live.ready();
    // The first authoritative read is stale after this write. The successor
    // notification must survive independently of the already consumed ready.
    const before = try fixture.dir.readFileAlloc(io, "root/config", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(before);
    try fixture.dir.writeFile(io, .{ .sub_path = "root/config", .data = "after" });
    _ = try live.changed();
    const after = try fixture.dir.readFileAlloc(io, "root/config", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(after);
    try std.testing.expectEqualStrings("before", before);
    try std.testing.expectEqualStrings("after", after);
    for ([_][]const u8{ "root/existing/deep/file", "root/created" }) |path| {
        try fixture.dir.writeFile(io, .{ .sub_path = path, .data = "create" });
        _ = try live.changed();
        try fixture.dir.writeFile(io, .{ .sub_path = path, .data = "write" });
        _ = try live.changed();
        try fixture.dir.deleteFile(io, path);
        _ = try live.changed();
    }
    try fixture.dir.writeFile(io, .{ .sub_path = "root/temporary", .data = "replace" });
    _ = try live.changed();
    try fixture.dir.rename("root/temporary", fixture.dir, "root/config", io);
    _ = try live.changed();
    try fixture.dir.createDirPath(io, "root/new/deep");
    try fixture.dir.writeFile(io, .{ .sub_path = "root/new/deep/file", .data = "new" });
    try std.testing.expect((try live.changed()) == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "root/new/deep/file", .data = "followup" });
    _ = try live.changed();
    try fixture.dir.rename("incoming", fixture.dir, "root/imported", io);
    try std.testing.expect((try live.changed()) == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "root/imported/deep/file", .data = "imported" });
    _ = try live.changed();
    try fixture.dir.rename("root/imported", fixture.dir, "outside", io);
    try std.testing.expect((try live.changed()) == .rescan);
    live.flush();
    while (live.mailbox.take() != null) {}
    try fixture.dir.writeFile(io, .{ .sub_path = "outside/deep/file", .data = "outside" });
    live.flush();
    try std.testing.expect(live.mailbox.take() == null);
}

test "watch macos selection case unicode symlink alias and root identity" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    try fixture.dir.createDirPath(io, "ancestor/root");
    try fixture.dir.createDir(io, "other", .default_dir);
    try fixture.dir.symLink(io, "ancestor/root", "alias", .{ .is_directory = true });
    const alias = try std.fmt.allocPrint(std.testing.allocator, "{s}/alias", .{fixture.path});
    defer std.testing.allocator.free(alias);
    var live: TestWatch = .{};
    try live.init(.{ .path = alias, .select = "case.txt", .exclude = &.{.{ .subtree = "ignored" }} }, null);
    defer live.deinit();
    try live.ready();
    try fixture.dir.writeFile(io, .{ .sub_path = "ancestor/root/Case.txt", .data = "case" });
    try std.testing.expect((try live.changed()) == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "ancestor/root/temporary", .data = "atomic" });
    live.flush();
    try std.testing.expect(live.mailbox.take() == null);
    try fixture.dir.rename("ancestor/root/temporary", fixture.dir, "ancestor/root/Case.txt", io);
    try std.testing.expect((try live.changed()) == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "ancestor/root/unrelated", .data = "ignored" });
    live.flush();
    try std.testing.expect(live.mailbox.take() == null);
    try fixture.dir.writeFile(io, .{ .sub_path = "ancestor/root/cafe\u{301}.txt", .data = "unicode" });
    try std.testing.expect((try live.changed()) == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "ancestor/root/日本語", .data = "unicode" });
    try std.testing.expect((try live.changed()) == .rescan);
    try fixture.dir.deleteFile(io, "alias");
    try fixture.dir.symLink(io, "other", "alias", .{ .is_directory = true });
    try fixture.dir.writeFile(io, .{ .sub_path = "ancestor/root/Case.txt", .data = "still pinned" });
    _ = try live.changed();
    try fixture.dir.rename("ancestor", fixture.dir, "moved", io);
    try fixture.dir.createDirPath(io, "ancestor/root");
    for (0..500) |_| {
        live.flush();
        if (live.mailbox.take()) |outcome| {
            try std.testing.expectEqual(watch.WatchFailure.root_lost, outcome.failed);
            return;
        }
        try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    }
    return error.WatchNoticeTimedOut;
}

test "watch macos classifier keeps coarse and terminal events ahead of filters" {
    var input = try watch.OwnedInput.init(std.testing.allocator, .{ .path = "/root", .recursive = false, .select = "config", .exclude = &.{.{ .subtree = "ignored" }} });
    defer input.deinit(std.testing.allocator);
    var backend: Backend = .{ .input = &input, .root_len = 5 };
    @memcpy(backend.root[0..6], "/root\x00");
    try std.testing.expect(backend.classify("/root/config", is_file).? == .changed);
    try std.testing.expect(backend.classify("/root/CONFIG", is_file).? == .rescan);
    try std.testing.expect(backend.classify("/root/ignored/file", is_file) == null);
    try std.testing.expect(backend.classify("/root/nested/config", is_file) == null);
    try std.testing.expect(backend.classify("/root/ignored", is_dir | 0x800).? == .rescan);
    try std.testing.expect(backend.classify("/root/ignored", must_scan).? == .rescan);
    try std.testing.expect(backend.classify("/ROOT/config", is_file).? == .rescan);
    try std.testing.expect(backend.classify("/root/café", is_file).? == .rescan);
    for ([_]u32{ 2, 4 }) |flags| try std.testing.expectEqual(watch.WatchFailure.overflow, backend.classify("/root/ignored", flags | must_scan).?.failed);
    for ([_]u32{ wrapped, 0x40, 0x80, 0x80000000 }) |flags| try std.testing.expectEqual(watch.WatchFailure.coverage_lost, backend.classify("/root/ignored", flags).?.failed);
    try std.testing.expectEqual(watch.WatchFailure.root_lost, backend.classify("/root/ignored", root_changed | dropped).?.failed);
    try std.testing.expect(backend.classify("", history_done) == null);
}

test "watch macos startup stages release every owned reference exactly once" {
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    const stages = [_]?Stage{ .root, .string, .array, .stream, .queue, .scheduled, .started, null };
    for (stages) |stage| {
        var hooks: TestHooks = .{ .failure = stage };
        var live: TestWatch = .{};
        try live.init(.{ .path = fixture.path }, &hooks);
        defer live.input.deinit(std.testing.allocator);
        defer {
            live.backend.requestStop();
            live.backend.join();
        }
        const outcome = live.mailbox.take().?;
        try std.testing.expect(if (stage == null) outcome == .ready else outcome == .failed);
        for (0..3) |i| try std.testing.expectEqual(hooks.acquired[i], hooks.released[i]);
        live.backend.requestStop();
        live.backend.join();
        live.backend.requestStop();
        live.backend.join();
        try std.testing.expectEqual(hooks.acquired, hooks.released);
        try std.testing.expectEqual(@as(usize, 1), hooks.acquired[0]);
        try std.testing.expect(live.backend.stream == null and live.backend.queue == null);
    }
    var missing: TestWatch = .{};
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/absent", .{fixture.path});
    defer std.testing.allocator.free(path);
    try missing.init(.{ .path = path }, null);
    defer missing.deinit();
    try std.testing.expectEqual(watch.WatchFailure.path_not_found, missing.mailbox.take().?.failed);
    var invalid: TestWatch = .{};
    try invalid.init(.{ .path = fixture.path, .select = "\xff" }, null);
    defer invalid.deinit();
    try std.testing.expectEqual(watch.WatchFailure.unsupported, invalid.mailbox.take().?.failed);
}

test "watch macos stop drains an active callback before releasing its context" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    var hooks: TestHooks = .{};
    var live: TestWatch = .{};
    try live.init(.{ .path = fixture.path }, &hooks);
    defer live.deinit();
    try live.ready();
    hooks.hold.store(true, .release);
    try fixture.dir.writeFile(io, .{ .sub_path = "active", .data = "callback" });
    for (0..5000) |_| {
        if (hooks.entered.isSet()) break;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(hooks.entered.isSet());
    live.backend.requestStop();
    try std.testing.expect(!hooks.exited.isSet());
    try std.testing.expectEqual(@as(usize, 0), hooks.released[@intFromEnum(Resource.stream)]);
    const Joiner = struct {
        backend: *Backend,
        entered: std.Io.Event = .unset,
        finished: std.Io.Event = .unset,
        fn run(self: *@This()) void {
            self.entered.set(std.testing.io);
            self.backend.join();
            self.finished.set(std.testing.io);
        }
    };
    var joiner: Joiner = .{ .backend = &live.backend };
    const thread = try std.Thread.spawn(.{}, Joiner.run, .{&joiner});
    defer {
        hooks.release.set(io);
        thread.join();
    }
    joiner.entered.waitUncancelable(io);
    try std.Io.sleep(io, .fromMilliseconds(10), .awake);
    try std.testing.expect(!joiner.finished.isSet());
    hooks.release.set(io);
    joiner.finished.waitUncancelable(io);
    try std.testing.expect(hooks.exited.isSet());
    try std.testing.expectEqual(hooks.acquired, hooks.released);
    try std.testing.expect(live.mailbox.take() == null);
}

test "watch macos callback bounds and dropped events terminate the production mailbox" {
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    for (0..3) |fault| {
        var live: TestWatch = .{};
        try live.init(.{ .path = fixture.path, .exclude = &.{.{ .subtree = "ignored" }} }, null);
        defer live.deinit();
        try live.ready();
        // Stop native delivery before injecting a batch into the exact callback.
        native.FSEventStreamStop(live.backend.stream.?);
        live.backend.started = false;
        native.dispatch_sync_f(live.backend.queue.?, null, noop);
        var path: [watch.max_path_bytes + 1]u8 = @splat('x');
        path[path.len - 1] = 0;
        var paths: [257][*:0]const u8 = @splat(path[0..watch.max_path_bytes :0]);
        const flags: [257]u32 = @splat(if (fault == 2) dropped else is_file);
        const count: usize = if (fault == 0) max_events + 1 else if (fault == 1) paths.len else 1;
        Backend.callback(live.backend.stream.?, &live.backend, count, &paths, &flags, &.{});
        try std.testing.expectEqual(if (fault == 2) watch.WatchFailure.overflow else watch.WatchFailure.resource_limit, live.mailbox.take().?.failed);
        live.mailbox.publish(.changed);
        try std.testing.expect(live.mailbox.take() == null);
    }
    try std.testing.expect(!boundedPath(&(@as([watch.max_path_bytes + 1]u8, @splat('x')))));
    var deep: [watch.max_depth * 2 + 1]u8 = undefined;
    for (&deep, 0..) |*byte, i| byte.* = if (i % 2 == 0) 'x' else '/';
    try std.testing.expect(!boundedPath(&deep));
}

test "watch macos nonrecursive native filtering and repeated stop retain no watch fds" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    try fixture.dir.createDirPath(io, "nested/deep");
    const Fds = struct {
        extern "c" fn proc_pidinfo(c_int, c_int, u64, ?*anyopaque, c_int) c_int;
        fn count() !usize {
            var buffer: [1024]extern struct { fd: i32, kind: u32 } = undefined;
            const bytes = proc_pidinfo(std.c.getpid(), 1, 0, &buffer, @sizeOf(@TypeOf(buffer)));
            if (bytes <= 0 or bytes >= @sizeOf(@TypeOf(buffer))) return error.FdInventoryFailed;
            return @as(usize, @intCast(bytes)) / @sizeOf(@TypeOf(buffer[0]));
        }
    };
    var baseline: ?usize = null;
    for (0..9) |iteration| {
        var live: TestWatch = .{};
        try live.init(.{ .path = fixture.path, .recursive = false }, null);
        defer live.input.deinit(std.testing.allocator);
        defer {
            live.backend.requestStop();
            live.backend.join();
        }
        try live.ready();
        if (iteration == 0) {
            try fixture.dir.writeFile(io, .{ .sub_path = "nested/deep/file", .data = "outside nonrecursive scope" });
            live.flush();
            try std.testing.expect(live.mailbox.take() == null);
            try fixture.dir.writeFile(io, .{ .sub_path = "direct", .data = "selected" });
            _ = try live.changed();
        }
        live.backend.requestStop();
        live.backend.join();
        // Measure against a warmed framework, not the cold process: dispatch
        // and FSEvents may retain their own process-wide pools after first use.
        if (baseline) |expected| try std.testing.expectEqual(expected, try Fds.count()) else baseline = try Fds.count();
    }
}
