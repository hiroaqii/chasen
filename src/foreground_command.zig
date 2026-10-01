const std = @import("std");
const builtin = @import("builtin");

/// Working directory requested for a foreground command.
///
/// The value is borrowed only for the duration of
/// `Ctx.terminal().runForegroundCommand`. Chasen copies `.path` bytes and
/// duplicates `.dir` before publishing the queued command. The caller keeps
/// ownership of the original directory descriptor.
///
/// `.inherit` is resolved when the child is spawned. `.path` preserves only
/// the queued bytes and is also resolved at spawn time; only `.dir` preserves
/// an already-open directory identity across rename or path replacement.
/// Directory descriptors are supported on Linux and macOS. Other targets
/// reject `.dir` while retaining their existing `.inherit` and `.path`
/// behavior. On POSIX, `std.Io.Dir.cwd()` is a pseudo descriptor rather than
/// an opened directory and is rejected; use `.inherit` for that intent.
pub const ForegroundCommandCwd = union(enum) {
    inherit,
    path: []const u8,
    dir: std.Io.Dir,
};

/// Environment requested for a foreground command.
///
/// The value is borrowed only for the duration of
/// `Ctx.terminal().runForegroundCommand`. The source map and all key/value
/// storage must remain alive and unmodified, including by other threads, until
/// that call returns. Chasen deep-copies every key and value in `.replace`
/// before publishing the queued command, so the caller may mutate or
/// deinitialize its map afterward. An empty replacement remains a non-null
/// empty child environment and is never treated as `.inherit`.
///
/// `.inherit` resolves the process environment when the child is spawned.
/// Chasen resolves a bare `argv[0]` using the parent `PATH` even for `.replace`;
/// use an absolute executable when replacement-environment authority matters.
/// Chasen transports the supplied map without adding secret-specific handling.
/// Replacement maps are cloned, owned, and cleaned up on every compiled target;
/// they do not expand foreground-command execution support. In particular,
/// Windows keeps the existing accepted-request result
/// `failed = .{ .stage = .unsupported, .error_name = "Unsupported" }`.
pub const ForegroundCommandEnvironment = union(enum) {
    inherit,
    replace: *const std.process.Environ.Map,
};

/// Errors that can occur before a foreground command is published.
///
/// Rejection leaves all caller inputs owned by the caller and does not consume
/// a request id.
pub const ForegroundCommandQueueError = error{
    ForegroundCommandLimitExceeded,
    ForegroundCommandRuntimeStopped,
    ForegroundCommandEmptyArgv,
    ForegroundCommandCwdUnsupported,
    ForegroundCommandInvalidCwd,
    ForegroundCommandProcessFdQuotaExceeded,
    ForegroundCommandSystemFdQuotaExceeded,
    ForegroundCommandDuplicateCwdFailed,
} || std.mem.Allocator.Error;

/// Opaque id returned when a foreground command is queued.
///
/// Apps can use this to ignore stale command results if future UI state changes
/// while the command is running.
pub const ForegroundCommandRequestId = struct {
    id: u64,
};

/// A final runtime failure, separate from the child's exit status.
pub const ForegroundCommandFailure = struct {
    pub const Stage = enum { unsupported, admission, prepare, spawn, handoff, wait, cleanup, restore_tty, restore_tui };
    stage: Stage,
    /// Static diagnostic, never owned or borrowed temporary storage.
    error_name: []const u8,
};

/// Completion after job cleanup and terminal recovery. A stopped job is
/// terminated and reaped; it cannot be resumed. Cleanup/restore failures are
/// fatal to the runtime and their callback message is disposed as undelivered.
pub const ForegroundCommandOutcome = union(enum) {
    exited: u8,
    signaled: u32,
    stopped: u32,
    failed: ForegroundCommandFailure,
    runtime_abandoned,

    pub fn isFatal(self: @This()) bool {
        return switch (self) {
            .failed => |f| switch (f.stage) {
                .cleanup, .restore_tty, .restore_tui => true,
                else => false,
            },
            else => false,
        };
    }
};

pub const ForegroundCommandResult = struct {
    request_id: ForegroundCommandRequestId,
    outcome: ForegroundCommandOutcome,
};

// Internal acquisition seams shared with request admission tests.
pub const foreground_command_duplicate_min_fd: c_int = 3;

pub const DuplicateForegroundCommandDirResult = union(enum) {
    success: std.Io.Dir,
    interrupted,
    invalid,
    process_fd_quota,
    system_fd_quota,
    failed,
};

pub const NativeForegroundCommandCwdOps = struct {
    pub fn duplicate(
        _: @This(),
        dir: std.Io.Dir,
        minimum_fd: c_int,
    ) DuplicateForegroundCommandDirResult {
        return switch (builtin.os.tag) {
            .linux => duplicateLinux(dir, minimum_fd),
            .macos => duplicateMacos(dir, minimum_fd),
            else => unreachable,
        };
    }

    fn duplicateLinux(
        dir: std.Io.Dir,
        minimum_fd: c_int,
    ) DuplicateForegroundCommandDirResult {
        const rc = std.os.linux.fcntl(
            dir.handle,
            std.os.linux.F.DUPFD_CLOEXEC,
            @intCast(minimum_fd),
        );
        return switch (std.os.linux.errno(rc)) {
            .SUCCESS => .{ .success = .{ .handle = @intCast(rc) } },
            .INTR => .interrupted,
            .BADF => .invalid,
            .MFILE => .process_fd_quota,
            .NFILE => .system_fd_quota,
            else => .failed,
        };
    }

    fn duplicateMacos(
        dir: std.Io.Dir,
        minimum_fd: c_int,
    ) DuplicateForegroundCommandDirResult {
        const rc = std.c.fcntl(dir.handle, std.c.F.DUPFD_CLOEXEC, minimum_fd);
        return switch (std.c.errno(rc)) {
            .SUCCESS => .{ .success = .{ .handle = rc } },
            .INTR => .interrupted,
            .BADF => .invalid,
            .MFILE => .process_fd_quota,
            .NFILE => .system_fd_quota,
            else => .failed,
        };
    }
};

pub fn targetSupportsForegroundCommandDir(comptime os_tag: std.Target.Os.Tag) bool {
    return os_tag == .linux or os_tag == .macos;
}

fn validateForegroundCommandCwdTarget(
    cwd: ForegroundCommandCwd,
) ForegroundCommandQueueError!void {
    switch (cwd) {
        .inherit, .path => {},
        .dir => if (!targetSupportsForegroundCommandDir(builtin.os.tag))
            return error.ForegroundCommandCwdUnsupported,
    }
}

pub fn duplicateForegroundCommandDirWith(
    dir: std.Io.Dir,
    ops: anytype,
) ForegroundCommandQueueError!std.Io.Dir {
    while (true) switch (ops.duplicate(dir, foreground_command_duplicate_min_fd)) {
        .success => |duplicate| return duplicate,
        .interrupted => continue,
        .invalid => return error.ForegroundCommandInvalidCwd,
        .process_fd_quota => return error.ForegroundCommandProcessFdQuotaExceeded,
        .system_fd_quota => return error.ForegroundCommandSystemFdQuotaExceeded,
        .failed => return error.ForegroundCommandDuplicateCwdFailed,
    };
}

fn closeForegroundCommandDir(dir: std.Io.Dir) void {
    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.close(dir.handle),
        .macos => _ = std.c.close(dir.handle),
        else => unreachable,
    }
}

const NativeForegroundCommandCwdCloseOps = struct {
    pub fn close(_: @This(), dir: std.Io.Dir) void {
        closeForegroundCommandDir(dir);
    }
};

pub const NativeForegroundCommandEnvironmentOps = struct {
    pub fn clone(
        _: @This(),
        map: *const std.process.Environ.Map,
        gpa: std.mem.Allocator,
    ) std.mem.Allocator.Error!std.process.Environ.Map {
        return map.clone(gpa);
    }
};

const OwnedForegroundCommandCwd = union(enum) {
    inherit,
    path: []const u8,
    dir: std.Io.Dir,

    fn deinit(self: @This(), gpa: std.mem.Allocator) void {
        self.deinitWith(gpa, NativeForegroundCommandCwdCloseOps{});
    }

    fn deinitWith(self: @This(), gpa: std.mem.Allocator, close_ops: anytype) void {
        switch (self) {
            .inherit => {},
            .path => |path| gpa.free(path),
            .dir => |dir| close_ops.close(dir),
        }
    }

    fn childCwd(self: @This()) ForegroundCommandCwd {
        return switch (self) {
            .inherit => .inherit,
            .path => |path| .{ .path = path },
            .dir => |dir| .{ .dir = dir },
        };
    }
};

const OwnedForegroundCommandEnvironment = union(enum) {
    inherit,
    replace: std.process.Environ.Map,

    fn deinit(self: *@This()) void {
        switch (self.*) {
            .inherit => {},
            .replace => |*map| map.deinit(),
        }
        self.* = undefined;
    }

    fn childEnvironment(self: *const @This()) ?*const std.process.Environ.Map {
        return switch (self.*) {
            .inherit => null,
            .replace => |*map| map,
        };
    }
};

/// Owned command inputs. Construct before publishing a pending request and
/// keep this value alive through child execution and synchronous update.
pub const OwnedInput = struct {
    argv: []const []const u8,
    cwd: OwnedForegroundCommandCwd,
    environment: OwnedForegroundCommandEnvironment,

    pub fn initWithOps(gpa: std.mem.Allocator, argv: []const []const u8, cwd: ForegroundCommandCwd, environment: ForegroundCommandEnvironment, cwd_ops: anytype, environment_ops: anytype) ForegroundCommandQueueError!OwnedInput {
        try validateForegroundCommandCwdTarget(cwd);

        const copied_argv = try gpa.alloc([]const u8, argv.len);
        errdefer gpa.free(copied_argv);

        var copied_count: usize = 0;
        errdefer {
            for (copied_argv[0..copied_count]) |arg| {
                gpa.free(arg);
            }
        }

        for (argv, 0..) |arg, i| {
            copied_argv[i] = try gpa.dupe(u8, arg);
            copied_count += 1;
        }

        const owned_cwd: OwnedForegroundCommandCwd = switch (cwd) {
            .inherit => .inherit,
            .path => |path| .{ .path = try gpa.dupe(u8, path) },
            .dir => |dir| .{ .dir = try duplicateForegroundCommandDirWith(dir, cwd_ops) },
        };
        errdefer owned_cwd.deinit(gpa);

        var owned_environment: OwnedForegroundCommandEnvironment = switch (environment) {
            .inherit => .inherit,
            .replace => |map| .{ .replace = try environment_ops.clone(map, gpa) },
        };
        errdefer owned_environment.deinit();

        return .{ .argv = copied_argv, .cwd = owned_cwd, .environment = owned_environment };
    }

    pub fn deinit(self: *OwnedInput, gpa: std.mem.Allocator) void {
        self.deinitWith(gpa, NativeForegroundCommandCwdCloseOps{});
    }

    pub fn deinitWith(self: *OwnedInput, gpa: std.mem.Allocator, close_ops: anytype) void {
        self.environment.deinit();
        self.cwd.deinitWith(gpa, close_ops);
        for (self.argv) |arg| gpa.free(arg);
        gpa.free(self.argv);
        self.* = undefined;
    }

    pub fn childCwd(self: *const OwnedInput) ForegroundCommandCwd {
        return self.cwd.childCwd();
    }
    pub fn childEnvironment(self: *const OwnedInput) ?*const std.process.Environ.Map {
        return self.environment.childEnvironment();
    }
};
