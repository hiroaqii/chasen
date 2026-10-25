//! Private, synchronous POSIX foreground ownership. No retained/background jobs.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const types = @import("foreground_command.zig");
const Outcome = types.ForegroundCommandOutcome;
const Stage = types.ForegroundCommandFailure.Stage;
const darwin = builtin.os.tag == .macos;
pub const supported = builtin.os.tag == .linux or darwin;
extern "c" fn getpgrp() c.pid_t;
extern "c" fn getpgid(c.pid_t) c.pid_t;
extern "c" fn tcgetpgrp(c_int) c.pid_t;
extern "c" fn tcsetpgrp(c_int, c.pid_t) c_int;
extern "c" fn waitid(c_int, c_uint, *c.siginfo_t, c_int) c_int;
extern "c" var environ: [*:null]?[*:0]u8;
extern "c" fn _NSGetEnviron() *[*:null]?[*:0]u8;
extern "c" fn posix_spawnattr_setpgroup(*c.posix_spawnattr_t, c.pid_t) c_int;
extern "c" fn posix_spawnattr_setsigmask(*c.posix_spawnattr_t, *const c.sigset_t) c_int;
extern "c" fn posix_spawnattr_setsigdefault(*c.posix_spawnattr_t, *const c.sigset_t) c_int;
extern "c" fn proc_listpids(u32, u32, *anyopaque, c_int) c_int;
const wait_flags: c_int = if (darwin) 0x04 | 0x08 | 0x20 else 0x04 | 0x02 | 0x01000000;
const wait_death: c_int = if (darwin) 0x04 | 0x20 else 0x04 | 0x01000000;
const wait_nohang: c_int = 1;
const wait_pid: c_int = 1;
const job_signals = [_]c.SIG{ .INT, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE, .CHLD };
const signal_bound = if (darwin) 32 else std.os.linux.NSIG;

pub fn failure(stage: Stage, name: []const u8) Outcome {
    return .{ .failed = .{ .stage = stage, .error_name = name } };
}
fn errno() c.E {
    return @enumFromInt(c._errno().*);
}
fn osFailure(stage: Stage) Outcome {
    return failure(stage, @tagName(errno()));
}
fn close(fd: c_int) void {
    _ = c.close(fd);
}
fn checked(result: c_int) !void {
    if (result == -1) return error.PosixOperationFailed;
}

/// All variable-sized input is materialized before fork. Child code only reads it.
pub const Prepared = struct {
    arena: std.heap.ArenaAllocator,
    argv: [:null]?[*:0]const u8,
    env: [:null]?[*:0]const u8,
    candidates: []const [:0]const u8,
    cwd_path: ?[:0]const u8,
    cwd_fd: ?c_int,
    signals: [signal_bound]bool,
    stdio: c_int = -1,
    status: ?[2]c_int = null,
    spawn_attr: if (darwin) ?c.posix_spawnattr_t else void = if (darwin) null else {},
    spawn_actions: if (darwin) ?c.posix_spawn_file_actions_t else void = if (darwin) null else {},

    pub fn init(gpa: std.mem.Allocator, argv: []const []const u8, cwd: types.ForegroundCommandCwd, replacement: ?*const std.process.Environ.Map) !Prepared {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        if (argv.len == 0 or argv[0].len == 0) return error.EmptyExecutable;
        const args = try a.allocSentinel(?[*:0]const u8, argv.len, null);
        for (argv, args) |arg, *dest| dest.* = (try zString(a, arg)).ptr;
        var env: std.ArrayList(?[*:0]const u8) = .empty;
        if (replacement) |map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                if (std.mem.indexOfScalar(u8, entry.key_ptr.*, '=') != null) return error.InvalidEnvironment;
                const pair = try std.fmt.allocPrint(a, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
                try env.append(a, (try zString(a, pair)).ptr);
            }
        } else {
            const inherited = if (darwin) _NSGetEnviron().* else environ;
            var i: usize = 0;
            while (inherited[i]) |value| : (i += 1) try env.append(a, (try a.dupeZ(u8, std.mem.span(value))).ptr);
        }
        const env_z = try a.allocSentinel(?[*:0]const u8, env.items.len, null);
        @memcpy(env_z, env.items);
        var candidates: std.ArrayList([:0]const u8) = .empty;
        if (std.mem.indexOfScalar(u8, argv[0], '/') != null) {
            try candidates.append(a, try zString(a, argv[0]));
        } else {
            const path = if (c.getenv("PATH")) |value| std.mem.span(value) else "/usr/local/bin:/bin:/usr/bin";
            var dirs = std.mem.splitScalar(u8, path, ':');
            while (dirs.next()) |dir| try candidates.append(a, try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ if (dir.len == 0) "." else dir, argv[0] }, 0));
        }
        var signals = [_]bool{false} ** signal_bound;
        if (!darwin) for (1..signal_bound) |i| {
            const sig: c.SIG = @enumFromInt(i);
            if (sig == .KILL or sig == .STOP) continue;
            var action: c.Sigaction = undefined;
            if (c.sigaction(sig, null, &action) == 0) signals[i] = true else if (errno() != .INVAL) return error.SignalQueryFailed;
        };
        return .{ .arena = arena, .argv = args, .env = env_z, .candidates = candidates.items, .cwd_path = switch (cwd) {
            .path => |path| try zString(a, path),
            else => null,
        }, .cwd_fd = switch (cwd) {
            .dir => |dir| dir.handle,
            else => null,
        }, .signals = signals };
    }
    pub fn deinit(self: *Prepared) void {
        self.releaseLaunch();
        self.arena.deinit();
        self.* = undefined;
    }

    /// Complete descriptor/native-action preparation before the runtime leaves UI.
    pub fn prepareLaunch(self: *Prepared, fd: c_int) !void {
        try checkSupport();
        std.debug.assert(self.stdio == -1);
        self.stdio = try duplicateStdio(fd);
        errdefer self.releaseLaunch();
        if (darwin) {
            var attr: c.posix_spawnattr_t = undefined;
            try spawnChecked(c.posix_spawnattr_init(&attr));
            self.spawn_attr = attr;
            var actions: c.posix_spawn_file_actions_t = undefined;
            try spawnChecked(c.posix_spawn_file_actions_init(&actions));
            self.spawn_actions = actions;
            // Native setters may replace the handle; update its cleanup owner directly.
            try spawnChecked(c.posix_spawnattr_setflags(&self.spawn_attr.?, .{ .START_SUSPENDED = true, .SETPGROUP = true, .SETSIGMASK = true, .SETSIGDEF = true, .CLOEXEC_DEFAULT = true }));
            try spawnChecked(posix_spawnattr_setpgroup(&self.spawn_attr.?, 0));
            var mask: c.sigset_t = undefined;
            var defaults: c.sigset_t = undefined;
            _ = c.sigemptyset(&defaults);
            try spawnChecked(c.pthread_sigmask(c.SIG.BLOCK, &defaults, &mask));
            for (job_signals) |sig| {
                _ = c.sigdelset(&mask, sig);
                _ = c.sigaddset(&defaults, sig);
            }
            try spawnChecked(posix_spawnattr_setsigmask(&self.spawn_attr.?, &mask));
            try spawnChecked(posix_spawnattr_setsigdefault(&self.spawn_attr.?, &defaults));
            for (0..3) |dest| try spawnChecked(c.posix_spawn_file_actions_adddup2(&self.spawn_actions.?, self.stdio, @intCast(dest)));
            if (self.cwd_path) |path| try spawnChecked(c.posix_spawn_file_actions_addchdir_np(&self.spawn_actions.?, path.ptr));
            if (self.cwd_fd) |cwd| try spawnChecked(c.posix_spawn_file_actions_addfchdir_np(&self.spawn_actions.?, cwd));
        } else {
            self.status = try makeStatusPipe();
        }
    }
    fn releaseLaunch(self: *Prepared) void {
        if (darwin) {
            if (self.spawn_actions) |*actions| _ = c.posix_spawn_file_actions_destroy(actions);
            if (self.spawn_attr) |*attr| _ = c.posix_spawnattr_destroy(attr);
            self.spawn_actions = null;
            self.spawn_attr = null;
        }
        if (self.status) |pair| {
            close(pair[0]);
            if (pair[1] >= 0) close(pair[1]);
            self.status = null;
        }
        if (self.stdio >= 0) close(self.stdio);
        self.stdio = -1;
    }
};
fn zString(a: std.mem.Allocator, value: []const u8) ![:0]const u8 {
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.EmbeddedNul;
    return a.dupeZ(u8, value);
}

pub const Terminal = struct {
    fd: c_int,
    pgid: c.pid_t,
    raw: c.termios,
    pub fn capture(fd: c_int) !Terminal {
        const group = getpgrp();
        if (tcgetpgrp(fd) != group) return error.NotForegroundOwner;
        var action: c.Sigaction = undefined;
        try checked(c.sigaction(.CHLD, null, &action));
        if (action.handler.handler == c.SIG.IGN or action.flags & c.SA.NOCLDWAIT != 0) return error.ChildWaitUnavailable;
        var raw: c.termios = undefined;
        try checked(c.tcgetattr(fd, &raw));
        return .{ .fd = fd, .pgid = group, .raw = raw };
    }
    fn handoff(self: Terminal, pid: c.pid_t, cooked: *const c.termios, fail_cooked: bool) !void {
        var mask = try TtouMask.init();
        const transition: anyerror!void = blk: {
            checked(tcsetpgrp(self.fd, pid)) catch |err| break :blk err;
            if (tcgetpgrp(self.fd) != pid) break :blk error.ForegroundHandoffFailed;
            if (fail_cooked) break :blk error.InjectedCookedMode;
            checked(c.tcsetattr(self.fd, .FLUSH, cooked)) catch |err| break :blk err;
        };
        try mask.restore();
        return transition;
    }
    fn restore(self: Terminal) !void {
        var mask = try TtouMask.init();
        const transition: anyerror!void = blk: {
            // Never return foreground ownership to a cooked/ISIG parent.
            checked(c.tcsetattr(self.fd, .FLUSH, &self.raw)) catch |err| break :blk err;
            checked(tcsetpgrp(self.fd, self.pgid)) catch |err| break :blk err;
            if (tcgetpgrp(self.fd) != self.pgid) break :blk error.ForegroundRestoreFailed;
        };
        try mask.restore();
        return transition;
    }
};
pub const TtouMask = struct {
    old: c.sigset_t,
    active: bool = true,
    pub fn init() !TtouMask {
        var set: c.sigset_t = undefined;
        _ = c.sigemptyset(&set);
        _ = c.sigaddset(&set, .TTOU);
        var old: c.sigset_t = undefined;
        if (c.pthread_sigmask(c.SIG.BLOCK, &set, &old) != 0) return error.SignalMaskFailed;
        return .{ .old = old };
    }
    pub fn restore(self: *TtouMask) !void {
        if (!self.active) return;
        var ignored: c.sigset_t = undefined;
        if (c.pthread_sigmask(c.SIG.SETMASK, &self.old, &ignored) != 0) {
            // A failed exact restore is fatal even if this bounded retry works.
            _ = c.pthread_sigmask(c.SIG.SETMASK, &self.old, &ignored);
            return error.SignalMaskRestoreFailed;
        }
        self.active = false;
    }
};

/// Named faults exist only at this private boundary; callers cannot configure them.
const Fault = enum { none, spawn, handoff, cooked, admission_continue, wait, wait_interrupted, authority_lost, cleanup, death_wait, group_kill, group_query, reap, restore, parent_mask };
const Probe = struct {
    fault: Fault = .none,
    signals: usize = 0,
    direct_kills: usize = 0,
    deaths: usize = 0,
    reaps: usize = 0,
    group_queries: usize = 0,
    inject_preexec_signals: bool = false,
    input_at_barriers: ?c_int = null,
    stop_before_group: bool = false,
    parent_after_fork: ?*const fn (c.pid_t) void = null,
};

pub fn run(prepared: *Prepared, terminal: Terminal, cooked: *const c.termios) Outcome {
    var probe: Probe = .{};
    return runWithProbe(prepared, terminal.fd, terminal, cooked, &probe);
}

fn runWithProbe(prepared: *Prepared, stdio_fd: c_int, terminal: ?Terminal, cooked: ?*const c.termios, probe: *Probe) Outcome {
    // Production prepares before wire leave. Private input tests have no UI.
    if (prepared.stdio < 0) prepared.prepareLaunch(stdio_fd) catch |err| return failure(if (err == error.Unsupported) .unsupported else .prepare, @errorName(err));
    defer prepared.releaseLaunch();
    if (probe.input_at_barriers) |master| _ = c.write(master, "\x03", 1);
    const outcome = execute(prepared, terminal, cooked, probe);
    if (terminal) |tty| {
        if (probe.input_at_barriers) |master| _ = c.write(master, "\x03", 1);
        const recovery: anyerror!void = if (probe.fault == .restore) error.InjectedRestore else tty.restore();
        recovery catch |err| {
            tty.restore() catch {};
            return failure(.restore_tty, @errorName(err));
        };
    }
    return outcome;
}

pub fn checkSupport() !void {
    const target_supported = switch (builtin.os.tag) {
        .linux => builtin.os.isAtLeast(.linux, .{ .major = 5, .minor = 10, .patch = 0 }) orelse false,
        .macos => builtin.os.isAtLeast(.macos, .{ .major = 13, .minor = 0, .patch = 0 }) orelse false,
        else => false,
    };
    if (!target_supported) return error.Unsupported;
    if (builtin.os.tag == .linux) {
        // UINT_MAX cannot name a valid fd. Flags zero needs no libc wrapper.
        if (!linuxChecked(std.os.linux.close_range(-1, -1, .{ .UNSHARE = false, .CLOEXEC = false }))) return error.Unsupported;
    }
}
fn linuxChecked(result: usize) bool {
    const err = std.os.linux.errno(result);
    if (err != .SUCCESS) {
        c._errno().* = @intFromEnum(err);
        return false;
    }
    return true;
}
fn spawnChecked(result: c_int) !void {
    if (result != 0) return error.NativeSpawnPreparationFailed;
}
fn duplicateStdio(fd: c_int) !c_int {
    while (true) {
        const owned = c.fcntl(fd, c.F.DUPFD_CLOEXEC, @as(c_int, 3));
        if (owned >= 0) return owned;
        if (errno() != .INTR) return error.DescriptorPreparationFailed;
    }
}
fn makeStatusPipe() ![2]c_int {
    var pair: [2]c_int = undefined;
    if (!linuxChecked(std.os.linux.pipe2(&pair, .{ .CLOEXEC = true, .NONBLOCK = true }))) return error.StatusPipeFailed;
    errdefer for (pair) |fd| close(fd);
    for (&pair) |*fd| if (fd.* <= 2) {
        const normalized = try duplicateStdio(fd.*);
        close(fd.*);
        fd.* = normalized;
    };
    return pair;
}

fn execute(prepared: *Prepared, terminal: ?Terminal, cooked: ?*const c.termios, probe: *Probe) Outcome {
    if (darwin) {
        if (probe.fault == .spawn) return failure(.spawn, "InjectedSpawn");
        var pid: c.pid_t = undefined;
        var spawn_error: c_int = @intFromEnum(c.E.NOENT);
        var denied = false;
        for (prepared.candidates) |path| {
            spawn_error = c.posix_spawn(&pid, path.ptr, &prepared.spawn_actions.?, &prepared.spawn_attr.?, prepared.argv.ptr, prepared.env.ptr);
            if (spawn_error == 0) break;
            const err: c.E = @enumFromInt(spawn_error);
            switch (err) {
                .ACCES => denied = true,
                .NOENT, .NOTDIR => {},
                else => return failure(.spawn, @tagName(err)),
            }
        }
        if (spawn_error != 0) return failure(.spawn, @tagName(if (denied) c.E.ACCES else c.E.NOENT));
        var owner: Child = .{ .pid = pid, .probe = probe };
        // Native launch suspension is not a stopped-job result. Do not wait
        // with WSTOPPED until the one admission SIGCONT has succeeded.
        if (getpgid(pid) != pid) return owner.finishFailure(failure(.handoff, "ChildGroupMismatch"));
        if (terminal) |tty| {
            if (probe.fault == .handoff) return owner.finishFailure(failure(.handoff, "InjectedHandoff"));
            tty.handoff(pid, cooked.?, probe.fault == .cooked) catch |err| return owner.finishFailure(failure(if (err == error.SignalMaskRestoreFailed) .restore_tty else .handoff, @errorName(err)));
        }
        if (probe.fault == .admission_continue) return owner.finishFailure(failure(.handoff, "InjectedResume"));
        if (c.kill(pid, .CONT) != 0) return owner.finishFailure(osFailure(.handoff));
        return finishObserved(&owner, null);
    } else {
        const status = prepared.status.?;
        var full: c.sigset_t = undefined;
        _ = c.sigfillset(&full);
        var old: c.sigset_t = undefined;
        if (c.pthread_sigmask(c.SIG.BLOCK, &full, &old) != 0) return failure(.prepare, "SignalMaskFailed");
        const pid = if (probe.fault == .spawn) @as(c.pid_t, -1) else c.fork();
        const spawn_errno = errno();
        if (pid == 0) child(prepared, terminal != null, cooked, status, old, probe);
        if (builtin.is_test) if (pid > 0) {
            if (probe.parent_after_fork) |hook| hook(pid);
        };
        var ignored: c.sigset_t = undefined;
        const mask_restored = c.pthread_sigmask(c.SIG.SETMASK, &old, &ignored) == 0 and probe.fault != .parent_mask;
        close(status[1]);
        prepared.status.?[1] = -1;
        if (pid < 0) {
            if (!mask_restored) {
                _ = c.pthread_sigmask(c.SIG.SETMASK, &old, &ignored);
                return failure(.restore_tty, "SignalMaskRestoreFailed");
            }
            return failure(.spawn, if (probe.fault == .spawn) "InjectedSpawn" else @tagName(spawn_errno));
        }
        var owner: Child = .{ .pid = pid, .probe = probe };
        if (!mask_restored) {
            const result = owner.finishFailure(failure(.restore_tty, "SignalMaskRestoreFailed"));
            _ = c.pthread_sigmask(c.SIG.SETMASK, &old, &ignored);
            return result;
        }
        // The child may already have exec'd. No parent setpgid/admission send.
        return finishObserved(&owner, status[0]);
    }
}

fn finishObserved(owner: *Child, status_fd: ?c_int) Outcome {
    const probe = owner.probe;
    var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
    if (probe.fault == .authority_lost) {
        var consumed: c_int = 0;
        while (c.waitpid(owner.pid, &consumed, 0) < 0) if (errno() != .INTR) break;
    }
    const wait_error: ?c.E = if (probe.fault == .wait) .IO else observe(owner.pid, &info, wait_flags, probe.fault == .wait_interrupted);
    if (wait_error) |err| {
        if (err == .CHILD or observe(owner.pid, &info, wait_flags | wait_nohang, false) != null) {
            owner.identity = .lost;
            return failure(.cleanup, "ChildAuthorityLost");
        }
        owner.dead = info.code >= 1 and info.code <= 3;
        return owner.finishFailure(failure(.wait, @tagName(err)));
    }
    owner.identity = .observed;
    owner.dead = info.code >= 1 and info.code <= 3;
    const value = if (darwin) info.status else info.fields.common.second.sigchld.status;
    const result: Outcome = switch (info.code) {
        1 => .{ .exited = @intCast(value) },
        2, 3 => .{ .signaled = @intCast(value) },
        4, 5 => .{ .stopped = @intCast(value) },
        else => failure(.wait, "UnknownChildStatus"),
    };
    if (!owner.cleanup()) return failure(.cleanup, "ChildCleanupFailed");
    if (status_fd) |fd| return readStatus(fd, result);
    return result;
}

const Status = extern struct { stage: c_int, code: c_int };
fn readStatus(fd: c_int, result: Outcome) Outcome {
    // Only called after owned direct-child death/reap. A competing pre-exec
    // fork may retain a CLOEXEC writer, so zero/EAGAIN both mean no record.
    var status: Status = undefined;
    const n = while (true) {
        const read = c.read(fd, @ptrCast(&status), @sizeOf(Status));
        if (read < 0 and errno() == .INTR) continue;
        break read;
    };
    if (result == .stopped) return result;
    if (n == 0 or (n < 0 and errno() == .AGAIN)) return result;
    if (n < 0) return osFailure(.spawn);
    if (n != @sizeOf(Status) or status.stage < 0 or status.stage > 1 or status.code <= 0 or status.code > 4095) return failure(.spawn, "InvalidChildStatus");
    const err: c.E = @enumFromInt(status.code);
    const name = std.enums.tagName(c.E, err) orelse return failure(.spawn, "InvalidChildStatus");
    return failure(if (status.stage == 1) .handoff else .spawn, name);
}
fn observe(pid: c.pid_t, info: *c.siginfo_t, flags: c_int, inject_interrupt: bool) ?c.E {
    var interrupted = inject_interrupt;
    while (true) {
        const err: ?c.E = if (interrupted) .INTR else if (waitid(wait_pid, @intCast(pid), info, flags) != 0) errno() else null;
        interrupted = false;
        if (err == null or err.? != .INTR) return err;
    }
}
const Child = struct {
    pid: c.pid_t,
    dead: bool = false,
    identity: enum { owned, observed, reaped, lost } = .owned,
    probe: *Probe,
    fn cleanup(self: *Child) bool {
        if (self.identity == .lost or self.identity == .reaped) return false;
        if (!self.dead) {
            self.probe.direct_kills += 1;
            if (c.kill(self.pid, .KILL) != 0 and errno() != .SRCH) return false;
            var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
            if (self.probe.fault == .death_wait or observe(self.pid, &info, wait_death, false) != null) {
                self.identity = .lost;
                return false;
            }
            self.dead = true;
            self.probe.deaths += 1;
        }
        // No child can create the group after this point. Its unreaped PID
        // pins this PGID, whether setpgid completed before an abort or not.
        self.probe.signals += 1;
        const killed = if (self.probe.fault == .group_kill) blk: {
            c._errno().* = @intFromEnum(c.E.PERM);
            break :blk @as(c_int, -1);
        } else c.kill(-self.pid, .KILL);
        const kill_error: ?c.E = if (killed == 0) null else errno();
        var group_ok = kill_error == null or kill_error == .SRCH;
        if (darwin and kill_error == .PERM and self.probe.fault != .group_kill) {
            // Darwin skips zombies in group kill and may report EPERM for an
            // empty live group. The unreaped child still pins this identity.
            group_ok = self.onlyOwnedZombie();
        }
        var status: c_int = 0;
        if (self.probe.fault == .reap) {
            // Model a competing reap at this exact boundary; the real reap
            // below must see ECHILD and never use the numeric identity again.
            while (c.waitpid(self.pid, &status, 0) < 0) if (errno() != .INTR) break;
        }
        while (c.waitpid(self.pid, &status, 0) < 0) {
            if (errno() == .INTR) continue;
            self.identity = .lost;
            return false;
        }
        self.identity = .reaped;
        self.probe.reaps += 1;
        return group_ok and self.probe.fault != .cleanup;
    }
    fn onlyOwnedZombie(self: *Child) bool {
        if (!self.dead or self.identity == .lost or self.identity == .reaped) return false;
        self.probe.group_queries += 1;
        var pids: [2]c.pid_t = undefined;
        // PROC_PGRP_ONLY includes live and zombie members. A full buffer is
        // insufficient proof, even if its first entry is our owned child.
        const bytes = if (self.probe.fault == .group_query) 0 else proc_listpids(2, @intCast(self.pid), &pids, @sizeOf(@TypeOf(pids)));
        return bytes == @sizeOf(c.pid_t) and pids[0] == self.pid;
    }
    fn finishFailure(self: *Child, outcome: Outcome) Outcome {
        return if (self.cleanup()) outcome else failure(.cleanup, "ChildCleanupFailed");
    }
};

fn child(prepared: *const Prepared, has_tty: bool, cooked: ?*const c.termios, status: [2]c_int, inherited_mask: c.sigset_t, probe: *const Probe) noreturn {
    close(status[0]);
    if (builtin.is_test and probe.stop_before_group) _ = c.raise(.STOP);
    if (c.setpgid(0, 0) != 0) childError(status[1], 0);
    for (0..3) |fd| if (c.dup2(prepared.stdio, @intCast(fd)) < 0) childError(status[1], 0);
    if (prepared.cwd_path) |path| if (c.chdir(path.ptr) != 0) childError(status[1], 0);
    if (prepared.cwd_fd) |fd| if (c.fchdir(fd) != 0) childError(status[1], 0);
    if (status[1] > 3 and !linuxChecked(std.os.linux.close_range(3, status[1] - 1, .{ .UNSHARE = false, .CLOEXEC = false }))) childError(status[1], 0);
    if (!linuxChecked(std.os.linux.close_range(status[1] + 1, -1, .{ .UNSHARE = false, .CLOEXEC = false }))) childError(status[1], 0);
    if (probe.inject_preexec_signals) {
        _ = c.kill(c.getpid(), .WINCH);
        _ = c.kill(c.getpid(), .USR1);
    }
    for (prepared.signals, 0..) |valid, i| {
        if (!valid) continue;
        const sig: c.SIG = @enumFromInt(i);
        var action: c.Sigaction = undefined;
        if (c.sigaction(sig, null, &action) != 0) childError(status[1], 0);
        const force = for (job_signals) |job| {
            if (job == sig) break true;
        } else false;
        if (force or (action.handler.handler != c.SIG.DFL and action.handler.handler != c.SIG.IGN)) {
            var reset: c.Sigaction = std.mem.zeroes(c.Sigaction);
            reset.handler.handler = c.SIG.DFL;
            _ = c.sigemptyset(&reset.mask);
            if (c.sigaction(sig, &reset, null) != 0) childError(status[1], 0);
        }
    }
    if (has_tty) {
        if (probe.fault == .handoff) {
            c._errno().* = @intFromEnum(c.E.IO);
            childError(status[1], 1);
        }
        const pid = c.getpid();
        if (tcsetpgrp(0, pid) != 0) childError(status[1], 1);
        if (tcgetpgrp(0) != pid) {
            c._errno().* = @intFromEnum(c.E.IO);
            childError(status[1], 1);
        }
        if (probe.fault == .cooked) {
            c._errno().* = @intFromEnum(c.E.IO);
            childError(status[1], 1);
        }
        if (c.tcsetattr(0, .FLUSH, cooked.?) != 0) childError(status[1], 1);
    }
    var mask = inherited_mask;
    for (job_signals) |sig| _ = c.sigdelset(&mask, sig);
    if (c.sigprocmask(c.SIG.SETMASK, &mask, null) != 0) childError(status[1], 0);
    var denied = false;
    for (prepared.candidates) |path| {
        _ = c.execve(path.ptr, prepared.argv.ptr, prepared.env.ptr);
        switch (errno()) {
            .ACCES => denied = true,
            .NOENT, .NOTDIR => {},
            else => childError(status[1], 0),
        }
    }
    c._errno().* = @intFromEnum(if (denied) c.E.ACCES else c.E.NOENT);
    childError(status[1], 0);
}
fn childError(fd: c_int, stage: c_int) noreturn {
    const status: Status = .{ .stage = stage, .code = c._errno().* };
    // One writer, initially empty pipe, <= PIPE_BUF: no partial/growing protocol.
    while (c.write(fd, @ptrCast(&status), @sizeOf(Status)) < 0) if (errno() != .INTR) break;
    c._exit(126);
}

/// Runs the same prepared spawn/wait/cleanup machinery without terminal handoff
/// for input-ownership tests. Never callable in a product executable.
pub fn testRun(io: std.Io, argv: []const []const u8, cwd: types.ForegroundCommandCwd, replacement: ?*const std.process.Environ.Map) Outcome {
    if (!builtin.is_test) @compileError("testRun is test-only");
    var prepared = Prepared.init(std.testing.allocator, argv, cwd, replacement) catch |err| return failure(.prepare, @errorName(err));
    defer prepared.deinit();
    const file = std.Io.Dir.openFileAbsolute(io, "/dev/null", .{ .mode = .read_write }) catch |err| return failure(.spawn, @errorName(err));
    defer file.close(io);
    var probe: Probe = .{};
    return runWithProbe(&prepared, file.handle, null, null, &probe);
}

test "foreground prepared child closes input and returns exec failure" {
    const result = testRun(std.testing.io, &.{"/nonexistent/chasen-foreground-fixture"}, .inherit, null);
    try std.testing.expectEqual(Stage.spawn, result.failed.stage);
    try std.testing.expectEqualStrings("NOENT", result.failed.error_name);
}

test "foreground real wait fault cleans exactly once while ECHILD never signals" {
    if (!supported) return error.SkipZigTest;
    var prepared = try Prepared.init(std.testing.allocator, &.{ "/bin/sh", "-c", "exit 0" }, .inherit, null);
    defer prepared.deinit();
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    for ([_]Fault{ .none, .spawn, .wait, .wait_interrupted, .authority_lost, .cleanup }) |fault| {
        var probe: Probe = .{ .fault = fault };
        const result = runWithProbe(&prepared, file.handle, null, null, &probe);
        switch (fault) {
            .none, .wait_interrupted => try std.testing.expectEqual(@as(u8, 0), result.exited),
            .spawn => try std.testing.expectEqual(Stage.spawn, result.failed.stage),
            .wait => try std.testing.expectEqual(Stage.wait, result.failed.stage),
            .authority_lost, .cleanup => try std.testing.expectEqual(Stage.cleanup, result.failed.stage),
            else => unreachable,
        }
        const cleaned: usize = if (fault == .spawn or fault == .authority_lost) 0 else 1;
        try std.testing.expectEqual(cleaned, probe.signals);
        try std.testing.expectEqual(cleaned, probe.reaps);
    }
}

fn forbiddenInheritedHandler(_: c.SIG) callconv(.c) void {
    c._exit(77);
}
test "foreground preexec cannot run inherited WINCH or application handlers" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var previous: [2]c.Sigaction = undefined;
    const signals = [_]c.SIG{ .WINCH, .USR1 };
    var action: c.Sigaction = std.mem.zeroes(c.Sigaction);
    action.handler.handler = forbiddenInheritedHandler;
    _ = c.sigemptyset(&action.mask);
    for (signals, 0..) |sig, i| try checked(c.sigaction(sig, &action, &previous[i]));
    defer for (signals, 0..) |sig, i| {
        _ = c.sigaction(sig, &previous[i], null);
    };
    var blocked: c.sigset_t = undefined;
    _ = c.sigemptyset(&blocked);
    _ = c.sigaddset(&blocked, .USR1);
    var original: c.sigset_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_sigmask(c.SIG.BLOCK, &blocked, &original));
    defer {
        var ignored: c.sigset_t = undefined;
        _ = c.pthread_sigmask(c.SIG.SETMASK, &original, &ignored);
    }
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    var prepared = try Prepared.init(std.testing.allocator, &.{"/bin/true"}, .inherit, null);
    defer prepared.deinit();
    var probe: Probe = .{ .inject_preexec_signals = true };
    const result = runWithProbe(&prepared, file.handle, null, null, &probe);
    try std.testing.expectEqual(@as(u8, 0), result.exited);
    var current: c.sigset_t = undefined;
    var empty: c.sigset_t = undefined;
    _ = c.sigemptyset(&empty);
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_sigmask(c.SIG.BLOCK, &empty, &current));
    try std.testing.expectEqual(@as(c_int, 1), c.sigismember(&current, .USR1));
    for (signals) |sig| {
        var unchanged: c.Sigaction = undefined;
        try checked(c.sigaction(sig, null, &unchanged));
        try std.testing.expect(unchanged.handler.handler == action.handler.handler);
    }
    // With USR1 unblocked, its default termination occurs before exec, instead
    // of entering the inherited callback (which would exit 77).
    _ = c.sigdelset(&current, .USR1);
    var ignored: c.sigset_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), c.pthread_sigmask(c.SIG.SETMASK, &current, &ignored));
    probe = .{ .inject_preexec_signals = true };
    const signaled = runWithProbe(&prepared, file.handle, null, null, &probe);
    try std.testing.expectEqual(@as(u32, @intFromEnum(c.SIG.USR1)), signaled.signaled);
}

test "foreground real PTY handoff and restore faults recover authority" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fixture = @cImport({
        @cInclude("pty.h");
        @cInclude("sys/ioctl.h");
        @cInclude("unistd.h");
    });
    var prepared = try Prepared.init(std.testing.allocator, &.{"/bin/true"}, .inherit, null);
    defer prepared.deinit();
    for ([_]Fault{ .none, .handoff, .cooked, .wait, .authority_lost, .restore }) |fault| {
        var master: c_int = -1;
        var slave: c_int = -1;
        try checked(fixture.openpty(&master, &slave, null, null, null));
        defer close(master);
        defer close(slave);
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            // Test owner uses only preallocated data/libc after this fork.
            if (fixture.setsid() < 0 or fixture.ioctl(slave, fixture.TIOCSCTTY, @as(c_int, 0)) < 0) c._exit(90);
            var cooked: c.termios = undefined;
            if (c.tcgetattr(slave, &cooked) != 0) c._exit(91);
            var raw = cooked;
            raw.lflag.ISIG = false;
            raw.lflag.ICANON = false;
            if (c.tcsetattr(slave, .NOW, &raw) != 0) c._exit(92);
            const terminal = Terminal.capture(slave) catch c._exit(93);
            var ignored_child: c.Sigaction = std.mem.zeroes(c.Sigaction);
            ignored_child.handler.handler = c.SIG.IGN;
            _ = c.sigemptyset(&ignored_child.mask);
            var previous_child: c.Sigaction = undefined;
            if (c.sigaction(.CHLD, &ignored_child, &previous_child) != 0) c._exit(98);
            if (Terminal.capture(slave)) |_| c._exit(99) else |err| {
                if (err != error.ChildWaitUnavailable) c._exit(99);
            }
            if (c.sigaction(.CHLD, &previous_child, null) != 0) c._exit(98);
            var probe: Probe = .{ .fault = fault, .input_at_barriers = master };
            const result = runWithProbe(&prepared, slave, terminal, &cooked, &probe);
            if (fault == .none) {
                // A queued VINTR can reach the child after handoff; only the
                // child may terminate, and the parent still restores below.
                if (!((result == .exited and result.exited == 0) or (result == .signaled and result.signaled == @intFromEnum(c.SIG.INT)))) c._exit(94);
            } else if (result != .failed) c._exit(94);
            const expected: Stage = if (fault == .restore) .restore_tty else if (fault == .authority_lost) .cleanup else if (fault == .wait) .wait else .handoff;
            const cleaned: usize = if (fault == .authority_lost) 0 else 1;
            if ((fault != .none and result.failed.stage != expected) or probe.signals != cleaned or probe.reaps != cleaned) c._exit(95);
            var restored: c.termios = undefined;
            if (c.tcgetattr(slave, &restored) != 0 or restored.lflag.ISIG or tcgetpgrp(slave) != getpgrp()) c._exit(96);
            var current: c.sigset_t = undefined;
            var empty: c.sigset_t = undefined;
            _ = c.sigemptyset(&empty);
            if (c.pthread_sigmask(c.SIG.BLOCK, &empty, &current) != 0 or c.sigismember(&current, .TTOU) != 0) c._exit(97);
            c._exit(0);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
    }
}

test "foreground TTIN and TTOU stops have their own typed terminal" {
    if (!supported) return error.SkipZigTest;
    for ([_][]const u8{ "kill -TTIN $$", "kill -TTOU $$" }, [_]c.SIG{ .TTIN, .TTOU }) |command, sig| {
        const result = testRun(std.testing.io, &.{ "/bin/sh", "-c", command }, .inherit, null);
        try std.testing.expectEqual(@as(u32, @intFromEnum(sig)), result.stopped);
    }
}

test "foreground preserves non-job ignored disposition across exec" {
    if (!supported) return error.SkipZigTest;
    var ignored: c.Sigaction = std.mem.zeroes(c.Sigaction);
    ignored.handler.handler = c.SIG.IGN;
    _ = c.sigemptyset(&ignored.mask);
    var previous: c.Sigaction = undefined;
    try checked(c.sigaction(.USR2, &ignored, &previous));
    defer _ = c.sigaction(.USR2, &previous, null);
    const result = testRun(std.testing.io, &.{ "/bin/sh", "-c", "kill -USR2 $$; exit 9" }, .inherit, null);
    try std.testing.expectEqual(@as(u8, 9), result.exited);
}

test "foreground status is atomic CLOEXEC and never waits for another fork's writer" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const pair = try makeStatusPipe();
    defer close(pair[0]);
    var writer_open = true;
    defer {
        if (writer_open) close(pair[1]);
    }
    for (pair) |fd| {
        try std.testing.expect(fd >= 3);
        try std.testing.expect(c.fcntl(fd, c.F.GETFD) & 1 != 0);
        try std.testing.expect(c.fcntl(fd, c.F.GETFL) & 0x800 != 0);
    }
    const original: Outcome = .{ .exited = 7 };
    try std.testing.expectEqual(@as(u8, 7), readStatus(pair[0], original).exited);
    for ([_]c_int{ 0, 1 }) |stage| {
        const record: Status = .{ .stage = stage, .code = @intFromEnum(c.E.ACCES) };
        try std.testing.expectEqual(@as(isize, @sizeOf(Status)), c.write(pair[1], @ptrCast(&record), @sizeOf(Status)));
        const result = readStatus(pair[0], original);
        try std.testing.expectEqual(if (stage == 0) Stage.spawn else Stage.handoff, result.failed.stage);
        try std.testing.expectEqualStrings("ACCES", result.failed.error_name);
    }
    try std.testing.expectEqual(@as(isize, 1), c.write(pair[1], "x", 1));
    try std.testing.expectEqualStrings("InvalidChildStatus", readStatus(pair[0], original).failed.error_name);
    const invalid: Status = .{ .stage = 2, .code = 1 };
    try std.testing.expectEqual(@as(isize, @sizeOf(Status)), c.write(pair[1], @ptrCast(&invalid), @sizeOf(Status)));
    try std.testing.expectEqualStrings("InvalidChildStatus", readStatus(pair[0], original).failed.error_name);

    // Competing fork sees the endpoints immediately after atomic creation.
    // Its pre-exec writer stays open across the parent's completed-job read.
    var script_buf: [160]u8 = undefined;
    const script = try std.fmt.bufPrintZ(&script_buf, "test ! -e /proc/self/fd/{d} && test ! -e /proc/self/fd/{d}", .{ pair[0], pair[1] });
    const args = [_:null]?[*:0]const u8{ "/bin/sh", "-c", script.ptr };
    const competitor = c.fork();
    if (competitor < 0) return error.ForkFailed;
    if (competitor == 0) {
        _ = c.raise(.STOP);
        _ = c.execve("/bin/sh", &args, environ);
        c._exit(99);
    }
    var live = true;
    defer if (live) {
        _ = c.kill(competitor, .KILL);
        _ = c.waitpid(competitor, null, 0);
    };
    var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
    try std.testing.expectEqual(@as(?c.E, null), observe(competitor, &info, wait_flags, false));
    close(pair[1]);
    writer_open = false;
    try std.testing.expectEqual(@as(u8, 7), readStatus(pair[0], original).exited); // EAGAIN, not EOF.
    try checked(c.kill(competitor, .CONT));
    var status: c_int = 0;
    try std.testing.expectEqual(competitor, c.waitpid(competitor, &status, 0));
    live = false;
    try std.testing.expectEqual(@as(c_int, 0), status); // Neither endpoint survived exec.
    try std.testing.expectEqual(@as(u8, 7), readStatus(pair[0], original).exited); // EOF.
}

fn waitForTestStop(pid: c.pid_t) void {
    var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
    if (observe(pid, &info, wait_flags, false) != null or info.code != 5) c._exit(91);
}
test "foreground Linux abort pins death before group cleanup before and after exec" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fixture = @cImport({
        @cInclude("sys/prctl.h");
        @cInclude("unistd.h");
    });
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    for ([_]bool{ true, false }) |before_group| {
        var prepared = try Prepared.init(std.testing.allocator, &.{ "/bin/sh", "-c", "/bin/sleep 60 & kill -STOP $$" }, .inherit, null);
        defer prepared.deinit();
        const fixture_pid = c.fork();
        if (fixture_pid < 0) return error.ForkFailed;
        if (fixture_pid == 0) {
            _ = fixture.alarm(10);
            if (fixture.prctl(fixture.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) c._exit(92);
            var probe: Probe = .{ .fault = .parent_mask, .stop_before_group = before_group, .parent_after_fork = waitForTestStop };
            const result = runWithProbe(&prepared, file.handle, null, null, &probe);
            if (result != .failed or result.failed.stage != .restore_tty) c._exit(93);
            if (probe.direct_kills != 1 or probe.deaths != 1 or probe.signals != 1 or probe.reaps != 1) c._exit(94);
            var status: c_int = 0;
            const helper = c.waitpid(-1, &status, 0);
            if (before_group) {
                if (helper != -1 or errno() != .CHILD) c._exit(95);
            } else if (helper <= 0 or status != @intFromEnum(c.SIG.KILL)) c._exit(96);
            c._exit(0);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(fixture_pid, c.waitpid(fixture_pid, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
    }
}

test "foreground macOS native suspension is admission and later STOP is a job result" {
    if (!darwin) return error.SkipZigTest;
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    var prepared = try Prepared.init(std.testing.allocator, &.{ "/bin/sh", "-c", "kill -STOP $$; exit 99" }, .inherit, null);
    defer prepared.deinit();
    var abort: Probe = .{ .fault = .admission_continue };
    const failed = runWithProbe(&prepared, file.handle, null, null, &abort);
    try std.testing.expectEqual(Stage.handoff, failed.failed.stage);
    try std.testing.expectEqual(@as(usize, 1), abort.direct_kills);
    try std.testing.expectEqual(@as(usize, 1), abort.deaths);
    try std.testing.expectEqual(@as(usize, 1), abort.reaps);
    var resumed: Probe = .{};
    const stopped = runWithProbe(&prepared, file.handle, null, null, &resumed);
    try std.testing.expectEqual(@as(u32, @intFromEnum(c.SIG.STOP)), stopped.stopped);
    try std.testing.expectEqual(@as(usize, 1), resumed.reaps);
}

test "foreground support floor rejects lower configured targets" {
    const meets_floor = if (darwin)
        builtin.os.isAtLeast(.macos, .{ .major = 13, .minor = 0, .patch = 0 }) orelse false
    else
        builtin.os.isAtLeast(.linux, .{ .major = 5, .minor = 10, .patch = 0 }) orelse false;
    if (!meets_floor) try std.testing.expectError(error.Unsupported, checkSupport()) else try checkSupport();
}

test "foreground missing Linux close_range fails preparation without launching" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const fixture = @cImport({
        @cInclude("linux/filter.h");
        @cInclude("linux/seccomp.h");
        @cInclude("sys/prctl.h");
        @cInclude("sys/syscall.h");
    });
    var prepared = try Prepared.init(std.testing.allocator, &.{"/bin/true"}, .inherit, null);
    defer prepared.deinit();
    for ([_]u32{ @intFromEnum(c.E.NOSYS), @intFromEnum(c.E.PERM) }) |failure_code| {
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            var rules = [_]fixture.struct_sock_filter{
                .{ .code = fixture.BPF_LD | fixture.BPF_W | fixture.BPF_ABS, .jt = 0, .jf = 0, .k = 0 },
                .{ .code = fixture.BPF_JMP | fixture.BPF_JEQ | fixture.BPF_K, .jt = 0, .jf = 1, .k = fixture.SYS_close_range },
                .{ .code = fixture.BPF_RET | fixture.BPF_K, .jt = 0, .jf = 0, .k = fixture.SECCOMP_RET_ERRNO | failure_code },
                .{ .code = fixture.BPF_RET | fixture.BPF_K, .jt = 0, .jf = 0, .k = fixture.SECCOMP_RET_ALLOW },
            };
            const filter: fixture.struct_sock_fprog = .{ .len = rules.len, .filter = &rules };
            if (fixture.prctl(fixture.PR_SET_NO_NEW_PRIVS, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) c._exit(90);
            if (fixture.prctl(fixture.PR_SET_SECCOMP, @as(c_ulong, fixture.SECCOMP_MODE_FILTER), &filter) != 0) c._exit(91);
            prepared.prepareLaunch(0) catch |err| {
                c._exit(if (err == error.Unsupported and prepared.stdio == -1 and prepared.status == null) 0 else 92);
            };
            c._exit(93);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(pid, c.waitpid(pid, &status, 0));
        try std.testing.expectEqual(@as(c_int, 0), status);
    }
}

test "foreground cleanup faults stop signaling and still reap a proven dead child" {
    if (!supported) return error.SkipZigTest;
    for ([_]Fault{ .death_wait, .group_kill, .reap }) |fault| {
        const pid = c.fork();
        if (pid < 0) return error.ForkFailed;
        if (pid == 0) {
            _ = c.setpgid(0, 0);
            _ = c.raise(.STOP);
            c._exit(99);
        }
        var probe: Probe = .{ .fault = fault };
        var owner: Child = .{ .pid = pid, .probe = &probe };
        try std.testing.expect(!owner.cleanup());
        try std.testing.expectEqual(@as(usize, 1), probe.direct_kills);
        try std.testing.expectEqual(@as(usize, if (fault == .death_wait) 0 else 1), probe.signals);
        try std.testing.expectEqual(@as(usize, if (fault == .group_kill) 1 else 0), probe.reaps);
        const counts = probe;
        try std.testing.expect(!owner.cleanup());
        try std.testing.expectEqual(counts.signals, probe.signals);
        try std.testing.expectEqual(counts.direct_kills, probe.direct_kills);
        // Only the test owns the deliberately unconsumed death-wait status.
        if (fault == .death_wait) try std.testing.expectEqual(pid, c.waitpid(pid, null, 0));
    }
}

// Run these tests under GuardMalloc with CHASEN_TEST_REQUIRE_NATIVE_REWRITE=1
// to require an observed native relocation as well as correct Prepared cleanup.
test "foreground macOS ownership native rewrite witness" {
    if (!darwin or c.getenv("CHASEN_TEST_REQUIRE_NATIVE_REWRITE") == null) return error.SkipZigTest;
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    var rewrites: usize = 0;
    for (0..8) |_| {
        var actions: c.posix_spawn_file_actions_t = undefined;
        try spawnChecked(c.posix_spawn_file_actions_init(&actions));
        defer _ = c.posix_spawn_file_actions_destroy(&actions);
        var previous = @intFromPtr(actions);
        for (0..3) |dest| {
            try spawnChecked(c.posix_spawn_file_actions_adddup2(&actions, file.handle, @intCast(dest)));
            if (@intFromPtr(actions) != previous) rewrites += 1;
            previous = @intFromPtr(actions);
        }
        try spawnChecked(c.posix_spawn_file_actions_addchdir_np(&actions, "/"));
        if (@intFromPtr(actions) != previous) rewrites += 1;
    }
    std.debug.print("native handle rewrites: {d}\n", .{rewrites});
    try std.testing.expect(rewrites > 0);
}

fn testNativeReleased(prepared: *Prepared, caller_fd: c_int, owned_fd: c_int) !void {
    try std.testing.expectEqual(@as(c_int, -1), prepared.stdio);
    try std.testing.expect(prepared.spawn_actions == null);
    try std.testing.expect(prepared.spawn_attr == null);
    try std.testing.expect(prepared.status == null);
    try std.testing.expectEqual(@as(c_int, -1), c.fcntl(owned_fd, c.F.GETFD));
    try std.testing.expectEqual(c.E.BADF, errno());
    try std.testing.expect(c.fcntl(caller_fd, c.F.GETFD) >= 0);
    prepared.releaseLaunch();
    try std.testing.expect(c.fcntl(caller_fd, c.F.GETFD) >= 0);
}

test "foreground macOS ownership runs three stdio actions and both cwd forms repeatedly" {
    if (!darwin) return error.SkipZigTest;
    const root = try std.Io.Dir.openDirAbsolute(std.testing.io, "/", .{});
    defer root.close(std.testing.io);
    for ([_]types.ForegroundCommandCwd{ .{ .path = "/" }, .{ .dir = root } }) |cwd| {
        var pair: [2]c_int = undefined;
        try checked(c.socketpair(c.AF.UNIX, c.SOCK.STREAM, 0, &pair));
        defer close(pair[0]);
        defer close(pair[1]);
        var prepared = try Prepared.init(std.testing.allocator, &.{
            "/bin/sh",                                                                                                   "-c",
            "read value && [ \"$value\" = input ] && [ \"$(/bin/pwd -P)\" = / ] || exit 42; printf out; printf err >&2",
        }, cwd, null);
        defer prepared.deinit();
        for (0..8) |_| {
            try std.testing.expectEqual(@as(isize, 6), c.write(pair[0], "input\n", 6));
            try prepared.prepareLaunch(pair[1]);
            const owned_fd = prepared.stdio;
            try std.testing.expect(prepared.spawn_actions != null and prepared.spawn_attr != null);
            var probe: Probe = .{};
            const result = runWithProbe(&prepared, pair[1], null, null, &probe);
            if (result == .failed) std.debug.print("native launch failed: {t} / {s}\n", .{ result.failed.stage, result.failed.error_name });
            try std.testing.expect(result == .exited);
            try std.testing.expectEqual(@as(u8, 0), result.exited);
            try testNativeReleased(&prepared, pair[1], owned_fd);
            var output: [6]u8 = undefined;
            var offset: usize = 0;
            while (offset < output.len) {
                const n = c.recv(pair[0], output[offset..].ptr, output.len - offset, c.MSG.DONTWAIT);
                try std.testing.expect(n > 0);
                offset += @intCast(n);
            }
            try std.testing.expectEqualStrings("outerr", &output);
            try std.testing.expect(c.fcntl(root.handle, c.F.GETFD) >= 0);
        }
    }
}

test "foreground macOS ownership releases real spawn failures" {
    if (!darwin) return error.SkipZigTest;
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    var prepared = try Prepared.init(std.testing.allocator, &.{"/dev/null/chasen-missing-executable"}, .{ .path = "/" }, null);
    defer prepared.deinit();
    for (0..8) |_| {
        try prepared.prepareLaunch(file.handle);
        const owned_fd = prepared.stdio;
        var probe: Probe = .{};
        const result = runWithProbe(&prepared, file.handle, null, null, &probe);
        try std.testing.expectEqual(Stage.spawn, result.failed.stage);
        try std.testing.expectEqualStrings("NOENT", result.failed.error_name);
        try testNativeReleased(&prepared, file.handle, owned_fd);
    }
}

test "foreground macOS ownership releases partial preparation and retries" {
    if (!darwin) return error.SkipZigTest;
    const file = try std.Io.Dir.openFileAbsolute(std.testing.io, "/dev/null", .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const root = try std.Io.Dir.openDirAbsolute(std.testing.io, "/", .{});
    defer root.close(std.testing.io);
    var prepared = try Prepared.init(std.testing.allocator, &.{"/usr/bin/true"}, .{ .dir = root }, null);
    defer prepared.deinit();
    for (0..8) |_| {
        // No intervening descriptor allocation: prepareLaunch takes this lowest free fd.
        const failed_fd = try duplicateStdio(file.handle);
        close(failed_fd);
        prepared.cwd_fd = -1; // Real addfchdir failure, after the three adddup2 calls.
        try std.testing.expectError(error.NativeSpawnPreparationFailed, prepared.prepareLaunch(file.handle));
        try testNativeReleased(&prepared, file.handle, failed_fd);
        prepared.cwd_fd = root.handle;
        try prepared.prepareLaunch(file.handle);
        const owned_fd = prepared.stdio;
        var probe: Probe = .{};
        const result = runWithProbe(&prepared, file.handle, null, null, &probe);
        if (result == .failed) std.debug.print("native retry failed: {t} / {s}\n", .{ result.failed.stage, result.failed.error_name });
        try std.testing.expect(result == .exited);
        try std.testing.expectEqual(@as(u8, 0), result.exited);
        try testNativeReleased(&prepared, file.handle, owned_fd);
        try std.testing.expect(c.fcntl(root.handle, c.F.GETFD) >= 0);
    }
}

fn testStoppedGroupMember(group: c.pid_t) !c.pid_t {
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        if (c.setpgid(0, group) != 0) c._exit(90);
        _ = c.raise(.STOP);
        c._exit(0);
    }
    var status: c_int = 0;
    if (c.waitpid(pid, &status, c.W.UNTRACED) != pid) return error.ChildWaitFailed;
    if (status & 0xff != 0x7f) return error.ChildDidNotStop;
    return pid;
}

test "foreground macOS group cleanup accepts only its unreaped dead child" {
    if (!darwin) return error.SkipZigTest;
    for ([_]Fault{ .none, .group_query, .group_kill }) |fault| {
        const pid = try testStoppedGroupMember(0);
        var probe: Probe = .{ .fault = fault };
        var owner: Child = .{ .pid = pid, .probe = &probe };
        defer if (owner.identity == .owned or owner.identity == .observed) {
            _ = owner.cleanup();
        };
        try checked(c.kill(pid, .KILL));
        var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
        try std.testing.expect(observe(pid, &info, wait_death, false) == null);
        try std.testing.expect(info.code >= 1 and info.code <= 3);
        owner.dead = true;
        owner.identity = .observed;
        try std.testing.expectEqual(fault == .none, owner.cleanup());
        try std.testing.expectEqual(@as(usize, 1), probe.signals);
        try std.testing.expectEqual(@as(usize, 1), probe.reaps);
        try std.testing.expectEqual(@as(usize, if (fault == .group_kill) 0 else 1), probe.group_queries);
        const counts = probe;
        try std.testing.expect(!owner.cleanup());
        try std.testing.expect(!owner.onlyOwnedZombie());
        try std.testing.expectEqual(counts.signals, probe.signals);
        try std.testing.expectEqual(counts.reaps, probe.reaps);
        try std.testing.expectEqual(counts.group_queries, probe.group_queries);
    }
}

test "foreground macOS group cleanup rejects an additional live member and still kills the group" {
    if (!darwin) return error.SkipZigTest;
    const leader = try testStoppedGroupMember(0);
    var probe: Probe = .{};
    var owner: Child = .{ .pid = leader, .probe = &probe };
    defer if (owner.identity == .owned or owner.identity == .observed) {
        _ = owner.cleanup();
    };
    const member = try testStoppedGroupMember(leader);
    var member_reaped = false;
    defer if (!member_reaped) {
        _ = c.kill(member, .KILL);
        _ = c.waitpid(member, null, 0);
    };
    try checked(c.kill(leader, .KILL));
    var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
    try std.testing.expect(observe(leader, &info, wait_death, false) == null);
    owner.dead = true;
    owner.identity = .observed;
    try std.testing.expect(!owner.onlyOwnedZombie());
    try std.testing.expect(owner.cleanup());
    try std.testing.expectEqual(@as(usize, 1), probe.reaps);
    try std.testing.expectEqual(@as(usize, 1), probe.group_queries);
    var status: c_int = 0;
    const waited = c.waitpid(member, &status, 0);
    member_reaped = waited == member or (waited < 0 and errno() == .CHILD);
    try std.testing.expectEqual(member, waited);
    try std.testing.expectEqual(@as(c_int, @intFromEnum(c.SIG.KILL)), status);
}
