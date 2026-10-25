const std = @import("std");
const linux = std.os.linux;
const watch = @import("../watch.zig");
const state = @import("watch_state.zig");
const max_directories = 4096;
const max_path_storage = 1024 * 1024;
const max_work = 65536;
const max_registrations = 65536;
const Error = error{ Stopped, PathNotFound, NotDirectory, AccessDenied, OutOfMemory, ResourceLimit, IoFailure, RootLost, Overflow, CoverageLost };
const Identity = struct {
    inode: u64,
    device_major: u32,
    device_minor: u32,
    mount: u64,
};
const Directory = struct {
    wd: i32,
    path: [:0]u8,
    identity: Identity,
    guard: bool,
};

/// One producer per accepted watch. Only this thread mutates directory state;
/// the runtime signals stop, joins, then releases all storage and descriptors.
pub const Backend = struct {
    allocator: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    input: *const watch.OwnedInput = undefined,
    mailbox: *state.Mailbox = undefined,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    inotify_fd: i32 = -1,
    stop_fd: i32 = -1,
    directories: std.ArrayList(Directory) = .empty,
    path_bytes: usize = 0,
    registrations: usize = 0,
    highest_wd: i32 = 0,
    root_buffer: [watch.max_path_bytes + 1]u8 = undefined,
    root_len: usize = 0,
    root_identity: Identity = undefined,
    dirty: bool = false,
    rescan: bool = false,

    pub fn start(self: *Backend, allocator: std.mem.Allocator, io: std.Io, input: *const watch.OwnedInput, mailbox: *state.Mailbox) ?watch.WatchFailure {
        self.allocator = allocator;
        self.io = io;
        self.input = input;
        self.mailbox = mailbox;
        const notify_fd = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
        self.inotify_fd = fdResult(notify_fd) catch |err| return failure(err);
        const stop_fd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        self.stop_fd = fdResult(stop_fd) catch |err| return failure(err);
        self.thread = std.Thread.spawn(.{}, run, .{self}) catch return .worker_unavailable;
        return null;
    }

    pub fn requestStop(self: *Backend) void {
        if (self.stopping.swap(true, .acq_rel) or self.stop_fd < 0) return;
        const one: u64 = 1;
        while (true) switch (linux.errno(linux.write(self.stop_fd, std.mem.asBytes(&one).ptr, @sizeOf(u64)))) {
            .INTR => continue,
            // EAGAIN means an earlier signal already made the fd readable.
            .SUCCESS, .AGAIN => return,
            else => unreachable, // fd is retained until this producer is joined.
        };
    }

    pub fn join(self: *Backend) void {
        if (self.thread) |thread| thread.join();
        self.thread = null;
        if (self.inotify_fd >= 0) _ = linux.close(self.inotify_fd);
        if (self.stop_fd >= 0) _ = linux.close(self.stop_fd);
        self.inotify_fd = -1;
        self.stop_fd = -1;
        for (self.directories.items) |dir| self.allocator.free(dir.path);
        self.directories.deinit(self.allocator);
        self.directories = .empty;
        self.path_bytes = 0;
    }

    fn run(self: *Backend) void {
        self.collect() catch |err| {
            if (err != error.Stopped and !self.stopping.load(.acquire))
                self.mailbox.publish(.{ .failed = failure(err) });
        };
    }

    fn prepare(self: *Backend) Error!void {
        try self.checkStop();
        // Resolve once using the opened directory, including a caller's symlink
        // alias. Later namespace checks use only this pinned canonical target.
        const opened = std.Io.Dir.cwd().openDir(self.io, self.input.path, .{}) catch |err| return ioError(err);
        errdefer opened.close(self.io);
        self.root_identity = try identityAt(opened.handle, "", linux.AT.EMPTY_PATH);
        self.root_len = opened.realPath(self.io, self.root_buffer[0..watch.max_path_bytes]) catch |err| return ioError(err);
        self.root_buffer[self.root_len] = 0;
        const root = self.rootPath();
        try checkPath(root);
        // Register each namespace ancestor before its child. A queued change to
        // the child name invalidates coverage even if a rename later undid it.
        if (root.len > 1) {
            _ = try self.addDirectory("/", true);
            for (root[1..], 1..) |byte, index| if (byte == '/') {
                _ = try self.addDirectory(root[0..index], true);
            };
        }
        var budget: usize = max_work;
        try self.walk(root, &budget);
        try self.catchUp(&budget);
        try self.validateRoot();
        opened.close(self.io);
        self.mailbox.publish(.ready);
        self.publishChanges();
    }

    fn collect(self: *Backend) Error!void {
        try self.prepare();
        while (true) {
            try self.checkStop();
            var fds = [_]linux.pollfd{
                .{ .fd = self.inotify_fd, .events = linux.POLL.IN, .revents = 0 },
                .{ .fd = self.stop_fd, .events = linux.POLL.IN, .revents = 0 },
            };
            const result = linux.poll(&fds, fds.len, -1);
            try self.checkStop();
            switch (linux.errno(result)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.IoFailure,
            }
            for (fds) |fd| if (fd.revents & (linux.POLL.ERR | linux.POLL.HUP | linux.POLL.NVAL) != 0)
                return error.IoFailure;
            var budget: usize = max_work;
            try self.catchUp(&budget);
            self.publishChanges();
        }
    }

    fn rootPath(self: *const Backend) [:0]const u8 {
        return self.root_buffer[0..self.root_len :0];
    }

    fn checkStop(self: *const Backend) Error!void {
        if (self.stopping.load(.acquire)) return error.Stopped;
    }

    fn spend(self: *const Backend, budget: *usize) Error!void {
        try self.checkStop();
        if (budget.* == 0) return error.ResourceLimit;
        budget.* -= 1;
    }

    fn validateRoot(self: *Backend) Error!void {
        for (self.directories.items) |dir| {
            if (!dir.guard) continue;
            const now = identityAt(linux.AT.FDCWD, dir.path, linux.AT.SYMLINK_NOFOLLOW) catch return error.RootLost;
            if (!std.meta.eql(now, dir.identity)) return error.RootLost;
        }
        const now = identityAt(linux.AT.FDCWD, self.rootPath(), linux.AT.SYMLINK_NOFOLLOW) catch return error.RootLost;
        if (!std.meta.eql(now, self.root_identity)) return error.RootLost;
    }

    fn addDirectory(self: *Backend, path: []const u8, guard: bool) Error!bool {
        try self.checkStop();
        try checkPath(path);
        var path_buffer: [watch.max_path_bytes + 1]u8 = undefined;
        const path_z = terminated(&path_buffer, path);
        const root_or_guard = guard or std.mem.eql(u8, path, self.rootPath());
        const before = identityAt(linux.AT.FDCWD, path_z, linux.AT.SYMLINK_NOFOLLOW) catch |err| {
            if (root_or_guard and (err == error.PathNotFound or err == error.NotDirectory)) return error.RootLost;
            return err;
        };
        if (!guard and std.mem.eql(u8, path, self.rootPath()) and !std.meta.eql(before, self.root_identity))
            return error.RootLost;
        for (self.directories.items) |dir| if (std.mem.eql(u8, dir.path, path)) {
            if (!std.meta.eql(before, dir.identity)) return error.CoverageLost;
            return false;
        };
        if (self.directories.items.len == max_directories or self.path_bytes + path.len + 1 > max_path_storage or
            self.registrations == max_registrations) return error.ResourceLimit;
        const copy = self.allocator.dupeSentinel(u8, path, 0) catch return error.OutOfMemory;
        errdefer self.allocator.free(copy);
        self.directories.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
        const structural = linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO |
            linux.IN.ATTRIB | linux.IN.DELETE_SELF | linux.IN.MOVE_SELF;
        const mask = structural | linux.IN.ONLYDIR | linux.IN.DONT_FOLLOW | linux.IN.MASK_CREATE |
            (if (guard) @as(u32, 0) else linux.IN.MODIFY | linux.IN.CLOSE_WRITE);
        const wd = try fdResult(linux.inotify_add_watch(self.inotify_fd, copy, mask));
        self.registrations += 1;
        // Linux allocates cyclic, increasing descriptors. Bound operations well
        // before wrap and reject reuse, so retired events cannot target a new dir.
        if (wd <= self.highest_wd) return error.CoverageLost;
        self.highest_wd = wd;
        const after = identityAt(linux.AT.FDCWD, copy, linux.AT.SYMLINK_NOFOLLOW) catch
            return if (root_or_guard) error.RootLost else error.CoverageLost;
        if (!std.meta.eql(before, after)) return if (root_or_guard) error.RootLost else error.CoverageLost;
        self.directories.appendAssumeCapacity(.{ .wd = wd, .path = copy, .identity = after, .guard = guard });
        self.path_bytes += copy.len + 1;
        return true;
    }

    /// Breadth-first traversal uses the bounded registration list as its work
    /// list. Each directory is watched before enumeration; symlinks stay entries.
    fn walk(self: *Backend, path: []const u8, budget: *usize) Error!void {
        const first = self.directories.items.len;
        if (!try self.addDirectory(path, false)) return;
        try self.scanFrom(first, budget);
    }

    fn scanFrom(self: *Backend, first: usize, budget: *usize) Error!void {
        if (!self.input.recursive) return;
        var index = first;
        while (index < self.directories.items.len) : (index += 1) {
            try self.checkStop();
            const directory = self.directories.items[index];
            const opened = std.Io.Dir.openDirAbsolute(self.io, directory.path, .{ .iterate = true, .follow_symlinks = false }) catch |err| return ioError(err);
            defer opened.close(self.io);
            if (!std.meta.eql(try identityAt(opened.handle, "", linux.AT.EMPTY_PATH), directory.identity)) return error.CoverageLost;
            var iterator = opened.iterate();
            while (iterator.next(self.io) catch |err| return ioError(err)) |entry| {
                try self.spend(budget);
                if (entry.kind != .directory and entry.kind != .unknown) continue;
                var child_buffer: [watch.max_path_bytes + 1]u8 = undefined;
                const child = try childPath(&child_buffer, directory.path, entry.name);
                _ = self.addDirectory(child, false) catch |err| switch (err) {
                    // A name removed during enumeration is covered by its parent
                    // watch. Non-directories (including symlinks) are not followed.
                    error.PathNotFound, error.NotDirectory => {
                        self.rescan = true;
                        continue;
                    },
                    else => return err,
                };
            }
        }
    }

    fn removeTree(self: *Backend, path: []const u8) Error!void {
        var index: usize = 0;
        while (index < self.directories.items.len) {
            try self.checkStop();
            const dir = self.directories.items[index];
            if (dir.guard or !watch.within(dir.path, path)) {
                index += 1;
                continue;
            }
            switch (linux.errno(linux.inotify_rm_watch(self.inotify_fd, dir.wd))) {
                .SUCCESS, .INVAL => {}, // already removed by the kernel on deletion
                else => return error.IoFailure,
            }
            self.path_bytes -= dir.path.len + 1;
            self.allocator.free(dir.path);
            _ = self.directories.swapRemove(index);
        }
    }

    fn catchUp(self: *Backend, budget: *usize) Error!void {
        var buffer: [16 * 1024]u8 = undefined;
        while (true) {
            try self.checkStop();
            const size = linux.read(self.inotify_fd, &buffer, buffer.len);
            switch (linux.errno(size)) {
                .SUCCESS => if (size == 0) return error.IoFailure,
                .INTR => continue,
                .AGAIN => break,
                else => return error.IoFailure,
            }
            try self.parse(buffer[0..size], budget);
        }
        try self.validateRoot();
    }

    fn parse(self: *Backend, bytes: []const u8, budget: *usize) Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            try self.spend(budget);
            if (bytes.len - offset < @sizeOf(linux.inotify_event)) return error.CoverageLost;
            const event: *align(1) const linux.inotify_event = @ptrCast(bytes[offset..].ptr);
            offset += @sizeOf(linux.inotify_event);
            if (event.len > bytes.len - offset) return error.CoverageLost;
            const raw_name = bytes[offset..][0..event.len];
            offset += event.len;
            const name = if (raw_name.len == 0) "" else raw_name[0..(std.mem.indexOfScalar(u8, raw_name, 0) orelse return error.CoverageLost)];
            if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.CoverageLost;
            try self.handleEvent(event.wd, event.mask, name, budget);
        }
    }

    fn handleEvent(self: *Backend, wd: i32, mask: u32, name: []const u8, budget: *usize) Error!void {
        if (mask & linux.IN.Q_OVERFLOW != 0) return error.Overflow;
        const dir = for (self.directories.items) |dir| {
            if (dir.wd == wd) break dir;
        } else {
            if (wd > 0 and wd <= self.highest_wd) return; // explicitly retired descriptor
            return error.CoverageLost;
        };
        const is_root = std.mem.eql(u8, dir.path, self.rootPath());
        if (mask & (linux.IN.UNMOUNT | linux.IN.IGNORED) != 0)
            return if (dir.guard or is_root) error.RootLost else error.CoverageLost;
        if (dir.guard) {
            if (mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) return error.RootLost;
            const child_start: usize = if (dir.path.len == 1) 1 else dir.path.len + 1;
            const suffix = self.rootPath()[child_start..];
            const child = suffix[0..(std.mem.indexOfScalar(u8, suffix, '/') orelse suffix.len)];
            if (std.mem.eql(u8, name, child) and mask & (linux.IN.CREATE | linux.IN.DELETE | linux.IN.MOVED_FROM | linux.IN.MOVED_TO) != 0)
                return error.RootLost;
            return;
        }
        if (mask & (linux.IN.DELETE_SELF | linux.IN.MOVE_SELF) != 0) {
            if (is_root) return error.RootLost;
            var saved: [watch.max_path_bytes + 1]u8 = undefined;
            const path = terminated(&saved, dir.path);
            // Normal deletion can report DELETE_SELF before its parent's DELETE.
            if (identityAt(linux.AT.FDCWD, path, linux.AT.SYMLINK_NOFOLLOW)) |_| {
                return error.CoverageLost;
            } else |err| if (err != error.PathNotFound) return err;
            try self.removeTree(path);
            self.rescan = true;
            return;
        }
        if (name.len == 0) {
            self.rescan = true;
            return;
        }
        var path_buffer: [watch.max_path_bytes + 1]u8 = undefined;
        const path = try childPath(&path_buffer, dir.path, name);
        if (self.input.recursive and mask & linux.IN.ISDIR != 0) {
            if (mask & (linux.IN.DELETE | linux.IN.MOVED_FROM) != 0) try self.removeTree(path);
            if (mask & (linux.IN.CREATE | linux.IN.MOVED_TO) != 0) {
                self.walk(path, budget) catch |err| switch (err) {
                    error.PathNotFound, error.NotDirectory => {},
                    else => return err,
                };
            }
            self.rescan = true;
        } else {
            const relative_start = if (self.root_len == 1) 1 else self.root_len + 1;
            if (self.input.selected(path[relative_start..])) self.dirty = true;
        }
    }

    fn publishChanges(self: *Backend) void {
        if (self.rescan) self.mailbox.publish(.rescan) else if (self.dirty) self.mailbox.publish(.changed);
        self.rescan = false;
        self.dirty = false;
    }
};

fn terminated(buffer: *[watch.max_path_bytes + 1]u8, path: []const u8) [:0]const u8 {
    @memcpy(buffer[0..path.len], path);
    buffer[path.len] = 0;
    return buffer[0..path.len :0];
}

fn childPath(buffer: *[watch.max_path_bytes + 1]u8, parent: []const u8, name: []const u8) Error![:0]const u8 {
    const prefix_len = parent.len + @intFromBool(parent.len != 1);
    if (prefix_len + name.len > watch.max_path_bytes) return error.ResourceLimit;
    @memcpy(buffer[0..parent.len], parent);
    if (parent.len != 1) buffer[parent.len] = '/';
    @memcpy(buffer[prefix_len..][0..name.len], name);
    buffer[prefix_len + name.len] = 0;
    return buffer[0 .. prefix_len + name.len :0];
}

fn checkPath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > watch.max_path_bytes) return error.ResourceLimit;
    var depth: usize = 0;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len > 0) {
        depth += 1;
    };
    if (depth > watch.max_depth) return error.ResourceLimit;
}

fn identityAt(fd: i32, path: [:0]const u8, flags: u32) Error!Identity {
    var stat: linux.Statx = undefined;
    const result = linux.statx(fd, path, flags, .{ .TYPE = true, .INO = true, .MNT_ID = true }, &stat);
    if (linux.errno(result) != .SUCCESS) return errnoError(linux.errno(result));
    if (!stat.mask.TYPE or !stat.mask.INO) return error.CoverageLost;
    if (stat.mode & 0xf000 != 0x4000) return error.NotDirectory;
    return .{ .inode = stat.ino, .device_major = stat.dev_major, .device_minor = stat.dev_minor, .mount = if (stat.mask.MNT_ID) stat.mnt_id else 0 };
}

fn fdResult(result: usize) Error!i32 {
    if (linux.errno(result) != .SUCCESS) return errnoError(linux.errno(result));
    return @intCast(result);
}

fn errnoError(err: linux.E) Error {
    return switch (err) {
        .NOENT => error.PathNotFound,
        .NOTDIR, .LOOP => error.NotDirectory,
        .ACCES, .PERM => error.AccessDenied,
        .NOMEM => error.OutOfMemory,
        .NOSPC, .MFILE, .NFILE, .NAMETOOLONG => error.ResourceLimit,
        .EXIST => error.CoverageLost,
        else => error.IoFailure,
    };
}

fn ioError(err: anyerror) Error {
    return switch (err) {
        error.FileNotFound => error.PathNotFound,
        error.NotDir, error.SymLinkLoop => error.NotDirectory,
        error.AccessDenied, error.PermissionDenied => error.AccessDenied,
        error.OutOfMemory => error.OutOfMemory,
        error.NameTooLong, error.ProcessFdQuotaExceeded, error.SystemFdQuotaExceeded, error.SystemResources => error.ResourceLimit,
        else => error.IoFailure,
    };
}

fn failure(err: Error) watch.WatchFailure {
    return switch (err) {
        error.PathNotFound => .path_not_found,
        error.NotDirectory => .not_directory,
        error.AccessDenied => .access_denied,
        error.OutOfMemory => .out_of_memory,
        error.ResourceLimit => .resource_limit,
        error.RootLost => .root_lost,
        error.Overflow => .overflow,
        error.CoverageLost => .coverage_lost,
        error.Stopped, error.IoFailure => .io_failure,
    };
}

/// Shared only by the colocated native tests and the real Effects integration.
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

// Uses the actual fd/parser/walk synchronously, making filesystem assertions
// deterministic without sleeps or an alternative watcher implementation.
const TestWatch = struct {
    input: watch.OwnedInput = undefined,
    wake: state.Wake = .{},
    mailbox: state.Mailbox = undefined,
    backend: Backend = .{},

    fn init(self: *TestWatch, options: watch.WatchOptions) !void {
        self.input = try .init(std.testing.allocator, options);
        errdefer self.input.deinit(std.testing.allocator);
        self.mailbox = .{ .io = std.testing.io, .wake = &self.wake };
        self.backend = .{ .allocator = std.testing.allocator, .io = std.testing.io, .input = &self.input, .mailbox = &self.mailbox };
        errdefer self.backend.join();
        self.backend.inotify_fd = try fdResult(linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK));
        self.backend.stop_fd = try fdResult(linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK));
    }

    fn prepare(self: *TestWatch) !void {
        try self.backend.prepare();
        try std.testing.expect(self.mailbox.take().? == .ready);
        try std.testing.expect(self.mailbox.take() == null);
    }

    fn drain(self: *TestWatch) !?watch.WatchOutcome {
        var budget: usize = max_work;
        try self.backend.catchUp(&budget);
        self.backend.publishChanges();
        return self.mailbox.take();
    }

    fn deinit(self: *TestWatch) void {
        self.backend.requestStop();
        self.backend.join();
        self.input.deinit(std.testing.allocator);
    }
};

test "watch linux recursive changes cover existing new moved and removed subtrees" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    try fixture.dir.createDirPath(io, "watched/existing/deep");
    try fixture.dir.createDirPath(io, "incoming/deep");
    const path = try fixture.dir.realPathFileAlloc(io, "watched", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var live: TestWatch = .{};
    try live.init(.{ .path = path });
    defer live.deinit();
    try live.prepare();
    try fixture.dir.writeFile(io, .{ .sub_path = "watched/existing/deep/file", .data = "one" });
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.writeFile(io, .{ .sub_path = "watched/existing/deep/file", .data = "two" });
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.deleteFile(io, "watched/existing/deep/file");
    try std.testing.expect((try live.drain()).? == .changed);

    // All descendants already exist when the queued CREATE/MOVED_TO is read.
    try fixture.dir.createDirPath(io, "watched/new/deep");
    try fixture.dir.writeFile(io, .{ .sub_path = "watched/new/deep/file", .data = "before registration" });
    try std.testing.expect((try live.drain()).? == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "watched/new/deep/file", .data = "after registration" });
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.rename("incoming", fixture.dir, "watched/imported", io);
    try std.testing.expect((try live.drain()).? == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "watched/imported/deep/file", .data = "imported" });
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.rename("watched/new", fixture.dir, "watched/renamed", io);
    try std.testing.expect((try live.drain()).? == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "watched/renamed/deep/file", .data = "renamed" });
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.rename("watched/imported", fixture.dir, "outside", io);
    try std.testing.expect((try live.drain()).? == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "outside/deep/file", .data = "not watched" });
    try std.testing.expect((try live.drain()) == null);
    try fixture.dir.deleteTree(io, "watched/renamed");
    try std.testing.expect((try live.drain()).? == .rescan);
    try fixture.dir.symLink(io, "../outside", "watched/alias", .{ .is_directory = true });
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.writeFile(io, .{ .sub_path = "outside/deep/file", .data = "symlink target not followed" });
    try std.testing.expect((try live.drain()) == null);
}

test "watch linux selection survives atomic replacement and coarse coverage bypasses exclusions" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    var live: TestWatch = .{};
    try live.init(.{ .path = fixture.path, .select = "tracked", .exclude = &.{.{ .subtree = "ignored" }} });
    defer live.deinit();
    try live.prepare();
    try fixture.dir.writeFile(io, .{ .sub_path = "temporary", .data = "new" });
    try std.testing.expect((try live.drain()) == null);
    try fixture.dir.rename("temporary", fixture.dir, "tracked", io);
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.writeFile(io, .{ .sub_path = "temporary", .data = "replacement" });
    try fixture.dir.rename("temporary", fixture.dir, "tracked", io);
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.deleteFile(io, "tracked");
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.createDirPath(io, "ignored/child");
    try std.testing.expect((try live.drain()).? == .rescan);
    // Excluded directories are still registered and consume the same bounds.
    try std.testing.expect(std.mem.endsWith(u8, live.backend.directories.items[live.backend.directories.items.len - 1].path, "ignored/child"));
    try fixture.dir.writeFile(io, .{ .sub_path = "ignored/child/file", .data = "ignored" });
    try std.testing.expect((try live.drain()) == null);
}

test "watch linux watch-before-scan captures registration-time changes and rejects lost coverage" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    var live: TestWatch = .{};
    try live.init(.{ .path = fixture.path });
    defer live.deinit();
    // Pause at the real register/scan boundary, then change the filesystem.
    _ = terminated(&live.backend.root_buffer, fixture.path);
    live.backend.root_len = fixture.path.len;
    live.backend.root_identity = try identityAt(linux.AT.FDCWD, fixture.path, linux.AT.SYMLINK_NOFOLLOW);
    _ = try live.backend.addDirectory(fixture.path, false);
    try fixture.dir.createDirPath(io, "arrived/deep");
    try fixture.dir.writeFile(io, .{ .sub_path = "arrived/deep/file", .data = "during registration" });
    var budget: usize = max_work;
    try live.backend.scanFrom(0, &budget);
    try live.backend.catchUp(&budget);
    try std.testing.expect(live.backend.rescan);
    try std.testing.expectEqual(@as(usize, 3), live.backend.directories.items.len);
    live.mailbox.publish(.ready);
    _ = live.mailbox.take();
    live.backend.publishChanges();
    try std.testing.expect(live.mailbox.take().? == .rescan);
    try fixture.dir.writeFile(io, .{ .sub_path = "arrived/deep/file", .data = "watched" });
    try std.testing.expect((try live.drain()).? == .changed);

    const overflow: linux.inotify_event = .{ .wd = -1, .mask = linux.IN.Q_OVERFLOW, .cookie = 0, .len = 0 };
    try std.testing.expectError(error.Overflow, live.backend.parse(std.mem.asBytes(&overflow), &budget));
    try std.testing.expectEqual(watch.WatchFailure.overflow, failure(error.Overflow));
    const invalidated: linux.inotify_event = .{ .wd = live.backend.directories.items[1].wd, .mask = linux.IN.IGNORED, .cookie = 0, .len = 0 };
    try std.testing.expectError(error.CoverageLost, live.backend.parse(std.mem.asBytes(&invalidated), &budget));
    live.backend.registrations = max_registrations;
    try fixture.dir.createDirPath(io, "excess");
    try std.testing.expectError(error.ResourceLimit, live.drain());
    try std.testing.expect(live.mailbox.take() == null); // no healthy rescan on partial failure
}

test "watch linux root and ancestor identity changes terminate even after rename back" {
    const io = std.testing.io;
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    try fixture.dir.createDirPath(io, "ancestor/root");
    const path = try fixture.dir.realPathFileAlloc(io, "ancestor/root", std.testing.allocator);
    defer std.testing.allocator.free(path);
    try fixture.dir.symLink(io, "ancestor/root", "alias", .{ .is_directory = true });
    const alias = try std.fmt.allocPrint(std.testing.allocator, "{s}/alias", .{fixture.path});
    defer std.testing.allocator.free(alias);
    var live: TestWatch = .{};
    try live.init(.{ .path = alias });
    defer live.deinit();
    try live.prepare();
    try std.testing.expectEqualStrings(path, live.backend.rootPath());
    try fixture.dir.createDir(io, "different", .default_dir);
    try fixture.dir.deleteFile(io, "alias");
    try fixture.dir.symLink(io, "different", "alias", .{ .is_directory = true });
    try std.testing.expect((try live.drain()) == null);
    try fixture.dir.writeFile(io, .{ .sub_path = "ancestor/root/file", .data = "pinned target" });
    try std.testing.expect((try live.drain()).? == .changed);
    try fixture.dir.rename("ancestor", fixture.dir, "moved", io);
    try fixture.dir.rename("moved", fixture.dir, "ancestor", io);
    try std.testing.expectError(error.RootLost, live.drain());
}

test "watch linux worker partial allocation failure is terminal and stop releases both fds" {
    var fixture = try TestDirectory.init();
    defer fixture.deinit();
    var input = try watch.OwnedInput.init(std.testing.allocator, .{ .path = fixture.path });
    defer input.deinit(std.testing.allocator);
    var wake: state.Wake = .{};
    var mailbox: state.Mailbox = .{ .io = std.testing.io, .wake = &wake };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 2 });
    var backend: Backend = .{};
    defer {
        backend.requestStop();
        backend.join();
    }
    try std.testing.expect(backend.start(failing.allocator(), std.testing.io, &input, &mailbox) == null);
    const notify_fd = backend.inotify_fd;
    const stop_fd = backend.stop_fd;
    var outcome: ?watch.WatchOutcome = null;
    for (0..5000) |_| {
        outcome = mailbox.take();
        if (outcome != null) break;
        try std.Io.sleep(std.testing.io, .fromMilliseconds(1), .awake);
    }
    try std.testing.expect(outcome != null);
    try std.testing.expectEqual(watch.WatchFailure.out_of_memory, outcome.?.failed);
    backend.requestStop();
    backend.join();
    try std.testing.expect(backend.registrations > 0);
    try std.testing.expect(!mailbox.ready_seen);
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(notify_fd, linux.F.GETFD, 0)));
    try std.testing.expectEqual(linux.E.BADF, linux.errno(linux.fcntl(stop_fd, linux.F.GETFD, 0)));
}
