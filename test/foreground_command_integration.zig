//! Linux PTY proof of the real Chasen runtime. Re-exec modes are fixture-only;
//! production foreground commands execute their requested argv directly.
const std = @import("std");
const chasen = @import("chasen");
const c = @cImport({
    @cInclude("pty.h");
    @cInclude("errno.h");
    @cInclude("sys/resource.h");
    @cInclude("unistd.h");
    @cInclude("signal.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/prctl.h");
    @cInclude("sys/ioctl.h");
    @cInclude("poll.h");
    @cInclude("fcntl.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
});
extern "c" var environ: [*:null]?[*:0]u8;

fn write(fd: c_int, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = c.write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (n < 0) {
            if (std.c._errno().* == c.EINTR) continue;
            return error.WriteFailed;
        }
        if (n == 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}
fn marker(comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const bytes = std.fmt.bufPrint(&buf, format, args) catch c._exit(90);
    write(1, bytes) catch c._exit(91);
}
const App = struct {
    executable: []const u8,
    mode: []const u8,
    count: usize = 0,
    input_failure: ?*InputFailure = null,
    cleaned: ?*bool = null,
    pub const Msg = union(enum) {
        pub const undelivered_policy = .plain;
        run,
        next,
        quit,
        done: chasen.ForegroundCommandResult,
    };
    pub fn init(self: *App, _: *chasen.Ctx(Msg)) !void {
        if (std.mem.eql(u8, self.mode, "init-failure")) return error.ExpectedInitFailure;
        if (self.input_failure) |fault| fault.armed.store(true, .release);
        marker("\nREADY\n", .{});
    }
    pub fn deinit(self: *App, _: chasen.AppDeinitContext) void {
        if (self.cleaned) |cleaned| cleaned.* = true;
    }
    pub fn handleEvent(_: *App, event: chasen.Event) ?Msg {
        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                'r' => .run,
                'n' => .next,
                'q' => .quit,
                else => null,
            },
            else => null,
        };
    }
    pub fn update(self: *App, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
        if (self.input_failure) |fault| {
            // The real reader has returned EOF before quit/foreground can stop
            // it. Joining must retain that reason, even with this queued key.
            if (fault.buffered and (msg == .run or msg == .quit)) try fault.failure_read.wait(ctx.io());
        }
        switch (msg) {
            .run => {
                if (std.mem.eql(u8, self.mode, "cwd-env")) {
                    var original_buf: [64]u8 = undefined;
                    var renamed_buf: [64]u8 = undefined;
                    const original = try std.fmt.bufPrintZ(&original_buf, "original-{d}", .{self.count});
                    const renamed = try std.fmt.bufPrintZ(&renamed_buf, "renamed-{d}", .{self.count});
                    if (c.mkdir(original, 0o700) != 0) return error.CwdSetupFailed;
                    const fd = c.open(original, c.O_RDONLY | c.O_DIRECTORY | c.O_CLOEXEC);
                    if (fd < 0) return error.CwdSetupFailed;
                    var live = true;
                    defer {
                        if (live) _ = c.close(fd);
                    }
                    const marker_fd = c.openat(fd, "owned-identity", c.O_CREAT | c.O_WRONLY | c.O_CLOEXEC, @as(c_uint, 0o600));
                    if (marker_fd < 0) return error.CwdSetupFailed;
                    _ = c.close(marker_fd);
                    var empty: std.process.Environ.Map = .init(std.heap.page_allocator);
                    defer empty.deinit();
                    _ = try ctx.terminal().runForegroundCommand(.{
                        .argv = &.{ self.executable, "--child", self.mode },
                        .cwd = .{ .dir = .{ .handle = fd } },
                        .environment = .{ .replace = &empty },
                        .finished = done,
                    });
                    _ = c.close(fd);
                    live = false;
                    if (c.rename(original, renamed) != 0 or c.mkdir(original, 0o700) != 0) return error.CwdRenameFailed;
                } else {
                    _ = try ctx.terminal().runForegroundCommand(.{ .argv = &.{ self.executable, "--child", self.mode }, .finished = done });
                }
            },
            .next => marker("\nNEXT\n", .{}),
            .quit => ctx.quit(),
            .done => |result| {
                self.count += 1;
                var attr: c.struct_termios = undefined;
                if (c.tcgetattr(0, &attr) != 0 or attr.c_lflag & c.ISIG != 0 or c.tcgetpgrp(0) != c.getpgrp()) return error.ParentNotRestored;
                switch (result.outcome) {
                    .exited => |n| marker("\nRESULT exited {d} {d}\n", .{ n, self.count }),
                    .signaled => |n| marker("\nRESULT signaled {d} {d}\n", .{ n, self.count }),
                    .stopped => |n| marker("\nRESULT stopped {d} {d}\n", .{ n, self.count }),
                    .failed => |f| {
                        marker("\nFAILED {s} {s}\n", .{ @tagName(f.stage), f.error_name });
                        return error.CommandFailed;
                    },
                    .runtime_abandoned => return error.UnexpectedAbandon,
                }
            },
        }
    }
    fn done(result: chasen.ForegroundCommandResult) Msg {
        return .{ .done = result };
    }
    pub fn view(_: *const App, surface: *chasen.Surface) !void {
        var col = surface.column(.{});
        col.borrowText("Foreground fixture: r command, n input, q quit", .{});
    }
};

fn runChild(mode: []const u8) noreturn {
    if (c.tcgetpgrp(0) != c.getpgrp() or c.getpid() != c.getpgrp()) c._exit(81);
    var attr: c.struct_termios = undefined;
    if (c.tcgetattr(0, &attr) != 0 or attr.c_lflag & (c.ISIG | c.ICANON) != (c.ISIG | c.ICANON)) c._exit(82);
    // Inspect before opening any fixture descriptor. Launch retains only stdio.
    for (3..256) |fd| if (c.fcntl(@as(c_int, @intCast(fd)), c.F_GETFD) >= 0) c._exit(86);
    if (std.mem.eql(u8, mode, "cwd-env")) {
        if (environ[0] != null) c._exit(87);
        const identity = c.open("owned-identity", c.O_RDONLY | c.O_CLOEXEC);
        if (identity < 0) c._exit(88);
        _ = c.close(identity);
    }
    _ = c.signal(c.SIGINT, c.SIG_IGN);
    // Leader-first death can orphan a stopped group and cause kernel SIGHUP.
    // Keep this helper alive through that as well, to prove explicit cleanup.
    _ = c.signal(c.SIGHUP, c.SIG_IGN);
    const helper = c.fork();
    if (helper < 0) c._exit(83);
    if (helper == 0) {
        // A survivor of terminal SIGINT must still be killed by group cleanup.
        _ = c.signal(c.SIGINT, c.SIG_IGN);
        while (true) _ = c.pause();
    }
    _ = c.signal(c.SIGINT, c.SIG_DFL);
    _ = c.signal(c.SIGHUP, c.SIG_DFL);
    marker("\nCHILD {d} {d} {d} {d}\n", .{ c.getpid(), c.getpgrp(), c.tcgetpgrp(0), helper });
    if (std.mem.eql(u8, mode, "stop")) {
        _ = c.raise(c.SIGSTOP);
        c._exit(84);
    }
    var byte: u8 = 0;
    while (c.read(0, &byte, 1) < 0) {
        if (std.c._errno().* != c.EINTR) c._exit(85);
    }
    c._exit(7);
}

const Wire = struct {
    kitty: i32 = 0,
    alt: bool = false,
    paste: bool = false,
    mouse: u5 = 0,
    resize: bool = false,
    unicode: bool = false,
    scan: usize = 0,
    fn consume(self: *Wire, fd: c_int, output: []const u8, resize_response: bool) !void {
        while (self.scan + 1 < output.len) {
            if (output[self.scan] != 27 or output[self.scan + 1] != '[') {
                self.scan += 1;
                continue;
            }
            const start = self.scan + 2;
            var end = start;
            while (end < output.len and !(output[end] >= 0x40 and output[end] <= 0x7e)) : (end += 1) {}
            if (end == output.len) return;
            const body = output[start..end];
            const final = output[end];
            self.scan = end + 1;
            if (final == 'c' and body.len == 0) try write(fd, "\x1b[?1;2c");
            if (final == 'u' and std.mem.eql(u8, body, "?")) try write(fd, "\x1b[?1u");
            if (final == 'p' and std.mem.eql(u8, body, "?2027$")) try write(fd, "\x1b[?2027;1$y");
            if (final == 'u' and body.len > 0 and body[0] == '>') self.kitty += 1;
            if (final == 'u' and body.len > 0 and body[0] == '<') {
                self.kitty -= 1;
                if (self.kitty < 0) return error.DuplicateKittyPop;
            }
            if ((final == 'h' or final == 'l') and body.len > 0 and body[0] == '?') {
                const set = final == 'h';
                var params = std.mem.splitScalar(u8, body[1..], ';');
                while (params.next()) |param| {
                    const mode = std.fmt.parseInt(u32, param, 10) catch continue;
                    switch (mode) {
                        1049 => self.alt = set,
                        2004 => self.paste = set,
                        1002, 1003, 1004, 1006, 1016 => {
                            const bit: u5 = switch (mode) {
                                1002 => 1,
                                1003 => 2,
                                1004 => 4,
                                1006 => 8,
                                else => 16,
                            };
                            if (set) self.mouse |= bit else self.mouse &= ~bit;
                        },
                        2027 => self.unicode = set,
                        2048 => {
                            self.resize = set;
                            if (set and resize_response) try write(fd, "\x1b[48;24;80;0;0t");
                        },
                        else => {},
                    }
                }
            }
        }
    }
    fn assertChild(self: Wire) !void {
        if (self.kitty != 0 or self.alt or self.paste or self.mouse != 0 or self.resize or self.unicode) return error.ChildInheritedTuiMode;
    }
};
fn nowMillis() i64 {
    var ts: c.struct_timespec = undefined;
    _ = c.clock_gettime(c.CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000 + @divTrunc(ts.tv_nsec, 1000000);
}
fn runCase(executable: [:0]const u8, mode: [:0]const u8, enhanced: bool, resize_response: bool, cwd: [:0]const u8) !void {
    var master: c_int = -1;
    var size: c.struct_winsize = .{ .ws_row = 24, .ws_col = 80, .ws_xpixel = 0, .ws_ypixel = 0 };
    const argv = [_:null]?[*:0]const u8{ executable.ptr, "--app", mode.ptr, if (enhanced) "kitty" else "legacy" };
    const pid = c.forkpty(&master, null, null, &size);
    if (pid < 0) return error.ForkPtyFailed;
    if (pid == 0) {
        if (c.chdir(cwd) != 0) {
            marker("\nfixture chdir failed: errno={d}\n", .{std.c._errno().*});
            c._exit(79);
        }
        _ = std.c.execve(executable.ptr, &argv, environ);
        marker("\nfixture execve failed: errno={d}\n", .{std.c._errno().*});
        c._exit(80);
    }
    defer _ = c.close(master);
    var finished = false;
    var job_pid: c_int = 0;
    var helper_pid: c_int = 0;
    defer if (!finished) {
        // The direct app PID remains unreaped and pinned. Killing it adopts
        // remaining fixture children into this subreaper before targeted cleanup.
        _ = c.kill(-pid, c.SIGKILL);
        _ = c.waitpid(pid, null, 0);
        for ([_]c_int{ job_pid, helper_pid }) |owned| if (owned > 0) {
            var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
            if (c.waitid(c.P_PID, @intCast(owned), &info, c.WNOHANG | c.WEXITED | c.WNOWAIT) == 0) {
                _ = c.kill(owned, c.SIGKILL);
                _ = c.waitpid(owned, null, 0);
            }
        };
    };
    _ = c.fcntl(master, c.F_SETFL, @as(c_int, c.O_NONBLOCK));
    var output: [256 * 1024]u8 = undefined;
    var len: usize = 0;
    var wire: Wire = .{};
    var phase: enum { ready, child, result, next, done } = .ready;
    var cycle: usize = 0;
    var phase_start: usize = 0;
    const deadline = nowMillis() + 15000;
    while (nowMillis() < deadline) {
        var pfd: c.struct_pollfd = .{ .fd = master, .events = c.POLLIN, .revents = 0 };
        _ = c.poll(&pfd, 1, 50);
        const n = c.read(master, output[len..].ptr, output.len - len);
        if (n > 0) len += @intCast(n);
        if (n <= 0 and phase != .done) {
            // Detect early exit without reaping: cleanup still owns the PID.
            var info: c.siginfo_t = std.mem.zeroes(c.siginfo_t);
            if (c.waitid(c.P_PID, @intCast(pid), &info, c.WNOHANG | c.WEXITED | c.WNOWAIT) == 0 and info.si_signo != 0) {
                std.debug.print("foreground PTY exited early {s} phase {s}\n{s}\n", .{ mode, @tagName(phase), output[0..len] });
                return error.AppExitedEarly;
            }
        }
        if (len == output.len) return error.ExcessiveOutput;
        try wire.consume(master, output[0..len], resize_response);
        if (std.mem.indexOf(u8, output[0..len], "FAILURE-CLEAN") != null) phase = .done;
        const recent = output[phase_start..len];
        switch (phase) {
            .ready => if (std.mem.indexOf(u8, recent, "READY") != null) {
                try write(master, if (std.mem.eql(u8, mode, "quit-failure")) "q" else "r");
                phase = .child;
                phase_start = len;
            },
            .child => if (std.mem.indexOf(u8, recent, "CHILD ")) |start| {
                const rest = recent[start + 6 ..];
                if (std.mem.indexOfScalar(u8, rest, '\n') == null) continue;
                var tokens = std.mem.tokenizeAny(u8, rest, " \r\n");
                job_pid = try std.fmt.parseInt(c_int, tokens.next().?, 10);
                const group = try std.fmt.parseInt(c_int, tokens.next().?, 10);
                const foreground = try std.fmt.parseInt(c_int, tokens.next().?, 10);
                helper_pid = try std.fmt.parseInt(c_int, tokens.next().?, 10);
                if (job_pid != group or group != foreground or group == pid) return error.BadJobRouting;
                if (!std.mem.eql(u8, mode, "stop")) try wire.assertChild();
                if (std.mem.eql(u8, mode, "int")) try write(master, "\x03") else if (std.mem.eql(u8, mode, "quit")) try write(master, "\x1c") else if (std.mem.eql(u8, mode, "tstp")) try write(master, "\x1a") else if (!std.mem.eql(u8, mode, "stop")) try write(master, "x\n");
                phase = .result;
                // Preserve current output: a self-stop may have completed.
            },
            .result => if (std.mem.indexOf(u8, recent, "RESULT ")) |start| {
                var tokens = std.mem.tokenizeAny(u8, recent[start + 7 ..], " \r\n");
                const tag = tokens.next() orelse continue;
                const code_text = tokens.next() orelse continue;
                const count_text = tokens.next() orelse continue;
                const code = try std.fmt.parseInt(u32, code_text, 10);
                const count = try std.fmt.parseInt(usize, count_text, 10);
                const expected: u32 = if (std.mem.eql(u8, mode, "int")) c.SIGINT else if (std.mem.eql(u8, mode, "quit")) c.SIGQUIT else if (std.mem.eql(u8, mode, "tstp")) c.SIGTSTP else if (std.mem.eql(u8, mode, "stop")) c.SIGSTOP else 7;
                const expected_tag = if (expected == 7) "exited" else if (expected == c.SIGSTOP or expected == c.SIGTSTP) "stopped" else "signaled";
                if (!std.mem.eql(u8, tag, expected_tag) or code != expected or count != cycle + 1) return error.BadCompletion;
                if (wire.kitty != @as(i32, if (enhanced) 1 else 0) or !wire.alt or !wire.paste or wire.mouse != 15 or !wire.resize or !wire.unicode) {
                    std.debug.print("mode {s} enhanced={} cycle={d}: kitty={d} alt={} paste={} mouse={} resize={}\n{s}\n", .{ mode, enhanced, cycle, wire.kitty, wire.alt, wire.paste, wire.mouse, wire.resize, output[0..len] });
                    return error.ModesNotRestored;
                }
                if (c.tcgetpgrp(master) != pid) return error.ParentAuthorityNotRestored;
                // The fixture is a subreaper; the killed helper becomes its
                // direct child after the command leader was reaped by Chasen.
                var helper_status: c_int = 0;
                const helper_waited = c.waitpid(helper_pid, &helper_status, c.WNOHANG);
                if (helper_waited == 0) continue;
                if (helper_waited != helper_pid or !c.WIFSIGNALED(helper_status) or (c.WTERMSIG(helper_status) != c.SIGKILL and c.WTERMSIG(helper_status) != c.SIGQUIT)) {
                    std.debug.print("helper {s}: expected pid={d}, waited={d}, status={d}\n", .{ mode, helper_pid, helper_waited, helper_status });
                    return error.HelperSurvived;
                }
                job_pid = 0;
                helper_pid = 0;
                try write(master, "n");
                phase = .next;
                phase_start = len;
            },
            .next => if (std.mem.indexOf(u8, recent, "NEXT") != null) {
                cycle += 1;
                if (cycle == 2) {
                    try write(master, "q");
                    phase = .done;
                } else {
                    try write(master, "r");
                    phase = .child;
                }
                phase_start = len;
            },
            .done => {
                var status: c_int = 0;
                if (c.waitpid(pid, &status, c.WNOHANG) == pid) {
                    finished = true;
                    if (!c.WIFEXITED(status) or c.WEXITSTATUS(status) != 0) return error.AppFailed;
                    if (wire.kitty != 0 or wire.resize or wire.paste or wire.mouse != 0 or wire.alt or wire.unicode) return error.FinalModesLeaked;
                    return;
                }
            },
        }
    }
    std.debug.print("foreground PTY timeout {s} phase {s}\n{s}\n", .{ mode, @tagName(phase), output[0..len] });
    return error.FixtureTimeout;
}

pub fn main(init: std.process.Init) !void {
    const no_core: c.struct_rlimit = .{ .rlim_cur = 0, .rlim_max = 0 };
    _ = c.setrlimit(c.RLIMIT_CORE, &no_core);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len >= 3 and std.mem.eql(u8, args[1], "--child")) runChild(args[2]);
    if (args.len >= 4 and std.mem.eql(u8, args[1], "--app")) {
        const original = try std.posix.tcgetattr(0);
        if (std.mem.eql(u8, args[2], "exit") and std.mem.eql(u8, args[3], "legacy")) {
            for (0..2) |limit| {
                var small: std.Io.Threaded = .init(init.gpa, .{ .concurrent_limit = .limited(limit) });
                defer small.deinit();
                if (chasen.runWith(.{ .runtime = .{ .allocator = init.gpa, .io = small.io() }, .terminal = .{ .env_map = init.environ_map } }, App{ .executable = args[0], .mode = "init-failure" })) |_| {
                    return error.ExpectedCapacityFailure;
                } else |err| if (err != error.ConcurrencyUnavailable) return err;
                if (!std.meta.eql(original, try std.posix.tcgetattr(0))) return error.TermiosLeaked;
                try expectFreeSlots(small.io(), limit);
            }
        }
        const fail_restart = std.mem.eql(u8, args[2], "restart-failure");
        const buffered_failure = std.mem.eql(u8, args[2], "quit-failure") or std.mem.eql(u8, args[2], "foreground-failure");
        var probe: InputFailure = .{
            .threaded = .init(init.gpa, .{ .concurrent_limit = if (fail_restart) .limited(2) else .unlimited }),
            .fail_restart = fail_restart,
            .buffered = buffered_failure,
        };
        defer probe.threaded.deinit();
        var io = probe.threaded.io();
        var vtable = io.vtable.*;
        vtable.operate = InputFailure.operate;
        vtable.concurrent = InputFailure.concurrent;
        io.vtable = &vtable;
        var cleaned = false;
        const fail_input = std.mem.eql(u8, args[2], "input-failure") or buffered_failure;
        const result = chasen.runWith(.{ .runtime = .{ .allocator = init.gpa, .io = io }, .terminal = .{ .env_map = init.environ_map, .mouse = true, .keyboard_protocol = if (std.mem.eql(u8, args[3], "kitty")) .kitty else .legacy } }, App{ .executable = args[0], .mode = args[2], .input_failure = if (fail_input) &probe else null, .cleaned = &cleaned });
        if (fail_restart) {
            if (result) |_| return error.ExpectedRestartFailure else |err| if (err != error.ConcurrencyUnavailable) return err;
            if (probe.admissions != 3 or cleaned) return error.WrongFailureBoundary;
        } else if (fail_input) {
            if (result) |_| return error.ExpectedInputFailure else |err| if (err != error.EndOfStream) return err;
        } else try result;
        if (!fail_restart and !cleaned) return error.AppNotCleaned;
        if (!std.meta.eql(original, try std.posix.tcgetattr(0))) return error.TermiosLeaked;
        // Limit the same backend after return so leaked resident futures cannot
        // hide behind the default unlimited admission used for normal restarts.
        probe.threaded.concurrent_limit = .limited(2);
        try expectFreeSlots(probe.threaded.io(), 2);
        if (fail_input or fail_restart) marker("\nFAILURE-CLEAN\n", .{});
        return;
    }
    if (c.prctl(c.PR_SET_CHILD_SUBREAPER, @as(c_ulong, 1), @as(c_ulong, 0), @as(c_ulong, 0), @as(c_ulong, 0)) != 0) return error.SubreaperFailed;
    // Re-exec happens after chdir, so argv[0] may no longer resolve there.
    const executable = try std.process.executablePathAlloc(init.io, init.arena.allocator());
    const temporary = init.environ_map.get("TMPDIR") orelse return error.MissingManagedTmpdir;
    const cwd = try std.fmt.allocPrintSentinel(init.arena.allocator(), "{s}/foreground-cwd-XXXXXX", .{temporary}, 0);
    if (c.mkdtemp(cwd) == null) return error.CwdSetupFailed;
    defer std.Io.Dir.cwd().deleteTree(init.io, cwd) catch {};
    for ([_][:0]const u8{ "exit", "int", "quit", "tstp", "stop" }) |mode| {
        for ([_]bool{ false, true }) |enhanced| try runCase(executable, mode, enhanced, enhanced, cwd);
    }
    try runCase(executable, "cwd-env", false, false, cwd);
    for ([_][:0]const u8{ "input-failure", "quit-failure", "foreground-failure", "restart-failure" }) |mode| try runCase(executable, mode, false, false, cwd);
    std.debug.print("foreground PTY: 15 cases / 22 commands passed (capacity failures, EOF/quit/foreground error return, cleanup and slot reuse)\n", .{});
}

// Inject EOF after startup at the real tty read boundary, leaving the signal
// pipe and libvaxis reader/error propagation/teardown paths intact.
const InputFailure = struct {
    threaded: std.Io.Threaded,
    armed: std.atomic.Value(bool) = .init(false),
    buffered: bool = false,
    next_eof: bool = false, // Reader-owned; preserves one real key before EOF.
    failure_read: std.Io.Event = .unset,
    fail_restart: bool = false,
    admissions: usize = 0, // Only the runtime thread admits these terminal futures.
    fn concurrent(userdata: ?*anyopaque, result_len: usize, result_alignment: std.mem.Alignment, context: []const u8, context_alignment: std.mem.Alignment, start: *const fn (*const anyopaque, *anyopaque) void) std.Io.ConcurrentError!*std.Io.AnyFuture {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *@This() = @fieldParentPtr("threaded", threaded);
        self.admissions += 1;
        // Signal owner, initial reader, then query restart. This proof must not
        // depend on Threaded's scheduling-dependent busy_count release timing.
        if (self.fail_restart and self.admissions == 3) return error.ConcurrencyUnavailable;
        return threaded.io().vtable.concurrent(userdata, result_len, result_alignment, context, context_alignment, start);
    }
    fn operate(userdata: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata));
        const self: *@This() = @fieldParentPtr("threaded", threaded);
        const tty_read = operation == .file_read_streaming and c.isatty(operation.file_read_streaming.file.handle) == 1;
        if (tty_read and self.next_eof) {
            self.failure_read.set(threaded.io());
            return .{ .file_read_streaming = 0 };
        }
        const result = try threaded.io().vtable.operate(userdata, operation);
        if (tty_read and self.armed.load(.acquire)) {
            if (self.buffered) self.next_eof = true else return .{ .file_read_streaming = 0 };
        }
        return result;
    }
};

fn expectFreeSlots(io: std.Io, count: usize) !void {
    const Probe = struct {
        fn run(gate: *std.Io.Event, worker_io: std.Io) void {
            gate.wait(worker_io) catch {};
        }
    };
    var gate: std.Io.Event = .unset;
    var futures: [2]?std.Io.Future(void) = .{ null, null };
    defer {
        gate.set(io);
        for (&futures) |*future| if (future.*) |*f| f.await(io);
    }
    for (futures[0..count]) |*future| {
        // Threaded may release busy_count just after publishing a Future result.
        // Bound that backend scheduling lag while requiring simultaneous slots.
        for (0..2000) |_| {
            future.* = io.concurrent(Probe.run, .{ &gate, io }) catch {
                try io.sleep(.fromMilliseconds(1), .awake);
                continue;
            };
            break;
        }
        if (future.* == null) return error.ConcurrentSlotLeaked;
    }
}
