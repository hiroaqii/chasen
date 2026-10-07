const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const types = @import("../program_types.zig");
const RuntimeCompletionBuffer = types.RuntimeCompletionBuffer;
const InternalEvent = types.InternalEvent;
const runtime = @import("../runtime.zig");
const ctx_mod = @import("../ctx.zig");
const requests_mod = @import("../requests.zig");
const terminal_image = @import("../terminal_image.zig");
const foreground_job = @import("../foreground_job.zig");
const foreground_command = @import("../foreground_command.zig");
const TerminalSession = @import("terminal_session.zig").TerminalSession;
const applyMsg = @import("events.zig").applyMsg;

pub const TerminalEffects = struct {
    images: terminal_image.Registry = .{},

    pub fn deinit(self: *TerminalEffects, session: anytype) void {
        self.images.freeAll(session.vx, session.writer());
        self.images.deinit(session.allocator);
    }

    pub fn processForeground(self: *TerminalEffects, comptime App: type, app: *App, ctx: *ctx_mod.Ctx(App.Msg), session: *TerminalSession(App.Msg), stats: *?runtime.RuntimeStats, opts: types.RunOptions) !bool {
        _ = self;
        const Runner = struct {
            session: *TerminalSession(App.Msg),
            fn run(runner: @This(), entry: *const requests_mod.Requests(App.Msg).ForegroundCommandEntry) !foreground_command.ForegroundCommandOutcome {
                return runner.session.runForeground(entry);
            }
        };
        return processPendingForegroundCommandsWithRunner(App, app, ctx, session.allocator, session.io, stats, opts, Runner{ .session = session }) catch |err| {
            try session.checkInputFailure();
            return err;
        };
    }

    pub fn processClipboard(self: *TerminalEffects, comptime App: type, app: *App, ctx: *ctx_mod.Ctx(App.Msg), session: *TerminalSession(App.Msg), stats: *?runtime.RuntimeStats, opts: types.RunOptions) !bool {
        _ = self;
        return processPendingClipboardCopies(App, app, ctx, &session.vx, &session.tty, session.allocator, session.io, stats, opts);
    }

    pub fn processImages(self: *TerminalEffects, comptime Msg: type, ctx: *ctx_mod.Ctx(Msg), completions: *RuntimeCompletionBuffer(Msg), session: *TerminalSession(Msg), opts: types.RunOptions) !void {
        try processPendingTerminalImages(Msg, ctx, completions, &self.images, &session.vx, session.writer(), session.allocator, opts);
    }
};

fn processPendingForegroundCommandsWithRunner(
    comptime App: type,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    allocator: std.mem.Allocator,
    io: std.Io,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
    runner: anytype,
) !bool {
    var pending_commands = app_ctx.requests.detachForegroundCommands();
    // Abandon every unprocessed entry on an early error, before freeing inputs.
    defer {
        while (pending_commands.next()) |queued| {
            var entry = queued;
            var msg = entry.message(.runtime_abandoned);
            runtime.deinitUndeliveredMessage(App.Msg, &msg, allocator);
            entry.deinit(allocator);
        }
    }
    var needs_render = false;

    while (pending_commands.next()) |queued_entry| {
        var entry = queued_entry;
        defer entry.deinit(allocator);

        const outcome = if (app_ctx.shouldQuit()) foreground_command.ForegroundCommandOutcome.runtime_abandoned else runner.run(&entry) catch |err| foreground_job.failure(.restore_tui, @errorName(err));
        var msg = entry.message(outcome);
        if (outcome.isFatal() or outcome == .runtime_abandoned) {
            runtime.deinitUndeliveredMessage(App.Msg, &msg, allocator);
            if (outcome.isFatal()) return error.ForegroundRecoveryFailed;
        } else {
            needs_render = try applyMsg(App, app, msg, app_ctx, io, stats, opts) or needs_render;
        }
    }

    return needs_render;
}

fn processPendingClipboardCopies(
    comptime App: type,
    app: *App,
    app_ctx: *ctx_mod.Ctx(App.Msg),
    vx: *vaxis.Vaxis,
    tty: *vaxis.Tty,
    allocator: std.mem.Allocator,
    io: std.Io,
    stats: *?runtime.RuntimeStats,
    opts: types.RunOptions,
) !bool {
    var pending_copies = app_ctx.requests.detachClipboardCopies();
    defer pending_copies.deinit();
    var needs_render = false;
    while (pending_copies.next()) |queued| {
        var entry = queued;
        defer entry.deinit(allocator);
        const outcome: ctx_mod.Ctx(App.Msg).ClipboardCopyOutcome = if (vx.*.copyToSystemClipboard(tty.writer(), entry.text, allocator)) |_| .sent else |err| .{ .write_failed = @errorName(err) };
        needs_render = try applyMsg(App, app, entry.message(outcome), app_ctx, io, stats, opts) or needs_render;
    }

    return needs_render;
}

fn processPendingTerminalImages(
    comptime Msg: type,
    app_ctx: *ctx_mod.Ctx(Msg),
    runtime_completions: *RuntimeCompletionBuffer(Msg),
    registry: *terminal_image.Registry,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    opts: types.RunOptions,
) !void {
    // Take ownership of queued image effects before processing so unwind
    // cleanup only sees entries that have not reached the drain step.
    var pending_unloads = app_ctx.requests.detachTerminalImageUnloads();
    defer pending_unloads.deinit();

    while (pending_unloads.next()) |handle| {
        _ = registry.unload(vx.*, tty, handle);
    }

    var pending_loads = app_ctx.requests.detachTerminalImageLoads();
    defer pending_loads.deinit();

    while (pending_loads.next()) |entry| {
        defer allocator.free(entry.path);

        switch (loadTerminalImagePath(registry, vx, tty, allocator, entry.path, opts)) {
            .loaded => |handle| {
                var msg = entry.loaded(entry.request_id, handle);
                runtime_completions.append(msg) catch |err| {
                    runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                    _ = registry.unload(vx.*, tty, handle);
                    return err;
                };
            },
            .failed => |reason| {
                var msg = entry.failed(entry.request_id, reason);
                runtime_completions.append(msg) catch |err| {
                    runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
                    return err;
                };
            },
        }
    }
}

const TerminalImageLoadResult = union(enum) {
    loaded: terminal_image.TerminalImageHandle,
    failed: terminal_image.LoadError,
};

fn loadTerminalImagePath(
    registry: *terminal_image.Registry,
    vx: *vaxis.Vaxis,
    tty: *std.Io.Writer,
    allocator: std.mem.Allocator,
    path: []const u8,
    opts: types.RunOptions,
) TerminalImageLoadResult {
    const loader = opts.terminal.image_path_loader orelse terminal_image.unsupportedPathLoader;
    const image = loader(opts.terminal.image_loader_context, vx, tty, allocator, path) catch |err| {
        if (err == error.Unsupported) return .{ .failed = .unsupported };
        return .{ .failed = .load_failed };
    };
    const handle = registry.add(allocator, image) catch {
        vx.freeImage(tty, image.id);
        return .{ .failed = .registry_full };
    };
    return .{ .loaded = handle };
}

pub fn discardQueuedForegroundCommands(comptime Msg: type, app_ctx: *ctx_mod.Ctx(Msg), allocator: std.mem.Allocator) void {
    var batch = app_ctx.requests.detachForegroundCommands();
    defer batch.deinit();
    while (batch.next()) |queued| {
        var entry = queued;
        var msg = entry.finished(.{ .request_id = entry.request_id, .outcome = .runtime_abandoned });
        runtime.deinitUndeliveredMessage(Msg, &msg, allocator);
        entry.deinit(allocator);
    }
}

test "clipboard detached suffix survives reentrant update and is freed on update error" {
    const TestApp = struct {
        fail_update: bool,
        received: usize = 0,
        pub const Msg = struct {
            request_id: u64,
            pub const undelivered_policy = .plain;
        };
        fn finished(result: ctx_mod.Ctx(Msg).ClipboardCopyResult) Msg {
            std.debug.assert(result.outcome == .sent);
            return .{ .request_id = result.request_id.id };
        }
        pub fn update(self: *@This(), msg: Msg, ctx: *ctx_mod.Ctx(Msg)) !void {
            self.received += 1;
            try std.testing.expectEqual(self.received, msg.request_id);
            if (self.received == 1) {
                _ = try ctx.terminal().copyToClipboard(.{ .text = "new", .finished = finished });
                if (self.fail_update) return error.UpdateFailed;
            }
        }
    };
    for ([_]bool{ false, true }) |fail_update| {
        var requests = requests_mod.Requests(TestApp.Msg).init(std.testing.allocator, std.testing.io);
        defer requests.deinit();
        var ctx = ctx_mod.Ctx(TestApp.Msg).init(&requests);
        _ = try ctx.terminal().copyToClipboard(.{ .text = "first", .finished = TestApp.finished });
        _ = try ctx.terminal().copyToClipboard(.{ .text = "second", .finished = TestApp.finished });
        var env: std.process.Environ.Map = .init(std.testing.allocator);
        defer env.deinit();
        var buffer: [128]u8 = undefined;
        var tty = try vaxis.Tty.init(std.testing.io, &buffer);
        defer tty.deinit();
        var vx = try vaxis.Vaxis.init(std.testing.io, std.testing.allocator, &env, .{});
        defer vx.deinit(std.testing.allocator, tty.writer());
        var app: TestApp = .{ .fail_update = fail_update };
        var stats: ?runtime.RuntimeStats = null;
        const result = processPendingClipboardCopies(TestApp, &app, &ctx, &vx, &tty, std.testing.allocator, std.testing.io, &stats, .{
            .runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io },
            .terminal = .{ .env_map = &env },
        });
        if (fail_update) {
            try std.testing.expectError(error.UpdateFailed, result);
        } else {
            try std.testing.expect(try result);
        }
        try std.testing.expectEqual(@as(usize, if (fail_update) 1 else 2), app.received);
        if (comptime builtin.os.tag == .linux) {
            const wire = tty.tty_writer.written();
            try std.testing.expect(std.mem.indexOf(u8, wire, "Zmlyc3Q=") != null);
            try std.testing.expectEqual(!fail_update, std.mem.indexOf(u8, wire, "c2Vjb25k") != null);
            try std.testing.expect(std.mem.indexOf(u8, wire, "bmV3") == null);
        }
        var remaining = requests.detachClipboardCopies();
        defer remaining.deinit();
        var new_entry = remaining.next().?;
        defer new_entry.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("new", new_entry.text);
        try std.testing.expectEqual(@as(u64, 3), new_entry.request_id.id);
        try std.testing.expect(remaining.next() == null);
    }
}

test "image batch overflow frees current and unconsumed paths" {
    const Msg = struct {
        pub const undelivered_policy = .plain;
        fn loaded(_: terminal_image.TerminalImageRequestId, _: terminal_image.TerminalImageHandle) @This() {
            unreachable;
        }
        fn failed(_: terminal_image.TerminalImageRequestId, _: terminal_image.LoadError) @This() {
            return .{};
        }
    };
    var requests = requests_mod.Requests(Msg).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var ctx = ctx_mod.Ctx(Msg).init(&requests);
    for ([_][]const u8{ "one.png", "two.png", "three.png" }) |path| {
        _ = try ctx.image().loadPath(path, Msg.loaded, Msg.failed);
    }
    var completions: RuntimeCompletionBuffer(Msg) = .{};
    try completions.init(std.testing.allocator);
    defer completions.deinitUndelivered(std.testing.allocator);
    for (0..RuntimeCompletionBuffer(Msg).capacity - 1) |_| try completions.append(.{});
    var registry: terminal_image.Registry = .{};
    defer registry.deinit(std.testing.allocator);
    try std.testing.expectError(error.RuntimeCompletionLimitExceeded, processPendingTerminalImages(
        Msg,
        &ctx,
        &completions,
        &registry,
        undefined,
        undefined,
        std.testing.allocator,
        .{ .runtime = .{ .allocator = std.testing.allocator, .io = std.testing.io }, .terminal = .{ .env_map = undefined } },
    ));
    try std.testing.expectEqual(@as(usize, RuntimeCompletionBuffer(Msg).capacity), completions.items.items.len);
    var empty = requests.detachTerminalImageLoads();
    defer empty.deinit();
    try std.testing.expect(empty.next() == null);
}

fn foregroundCommandProgramTestFdOpen(fd: std.Io.Dir.Handle) bool {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const rc = std.os.linux.fcntl(fd, std.os.linux.F.GETFD, 0);
            break :blk std.os.linux.errno(rc) == .SUCCESS;
        },
        .macos => blk: {
            const rc = std.c.fcntl(fd, std.c.F.GETFD);
            break :blk std.c.errno(rc) == .SUCCESS;
        },
        else => false,
    };
}

fn foregroundCommandTestTouchPath() ![]const u8 {
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/touch", .{})) |_| {
        return "/usr/bin/touch";
    } else |_| {}
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/bin/touch", .{})) |_| {
        return "/bin/touch";
    } else |_| {}
    return error.SkipZigTest;
}

fn foregroundCommandTestTruePath() ![]const u8 {
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/true", .{})) |_| {
        return "/usr/bin/true";
    } else |_| {}
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/bin/true", .{})) |_| {
        return "/bin/true";
    } else |_| {}
    return error.SkipZigTest;
}

fn foregroundCommandTestPrintenvPath() ![]const u8 {
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/printenv", .{})) |_| {
        return "/usr/bin/printenv";
    } else |_| {}
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/bin/printenv", .{})) |_| {
        return "/bin/printenv";
    } else |_| {}
    return error.SkipZigTest;
}

fn foregroundCommandTestShellPath() ![]const u8 {
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/bin/sh", .{})) |_| {
        return "/bin/sh";
    } else |_| {}
    if (std.Io.Dir.accessAbsolute(std.testing.io, "/usr/bin/sh", .{})) |_| {
        return "/usr/bin/sh";
    } else |_| {}
    return error.SkipZigTest;
}

fn foregroundCommandParentCanary(map: *const std.process.Environ.Map) ![]const u8 {
    const non_secret_keys = [_][]const u8{
        "HOME",
        "USER",
        "LOGNAME",
        "LANG",
        "LC_ALL",
        "TERM",
        "SHELL",
        "XDG_RUNTIME_DIR",
    };
    for (non_secret_keys) |key| {
        if (map.contains(key)) return key;
    }
    return error.SkipZigTest;
}

test "foreground command inherit cwd reaches child spawn" {
    const TestMsg = union(enum) { finished };
    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{try foregroundCommandTestTruePath()},
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    switch (entry.input.childCwd()) {
        .inherit => {},
        else => return error.TestUnexpectedResult,
    }
    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        entry.input.childEnvironment(),
    );
    switch (outcome) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
}

test "foreground environment replacement snapshot reaches child without parent leakage" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);
    var caller_dir = try tmp.dir.openDir(std.testing.io, "original", .{});
    var caller_dir_live = true;
    defer if (caller_dir_live) caller_dir.close(std.testing.io);
    var caller_map: std.process.Environ.Map = .init(std.testing.allocator);
    var caller_map_live = true;
    defer if (caller_map_live) caller_map.deinit();
    try caller_map.put("ISSUE55_VALUE", "queued-value");
    try caller_map.put("ISSUE55_SECOND", "queued-second");
    var parent_map = try std.testing.environ.createMap(std.testing.allocator);
    defer parent_map.deinit();
    const parent_canary = try foregroundCommandParentCanary(&parent_map);

    const printenv_path = try foregroundCommandTestPrintenvPath();
    const shell_path = try foregroundCommandTestShellPath();
    const caller_argv0 = try std.testing.allocator.dupe(u8, shell_path);
    defer std.testing.allocator.free(caller_argv0);
    // Test-only: the production path preserves caller argv and never inserts a
    // shell. This fixture verifies only fixed test values and an allowlisted
    // parent key, discards command output, then creates an empty cwd-relative
    // marker. It never persists ambient environment values.
    const caller_command = try std.fmt.allocPrint(
        std.testing.allocator,
        "test \"$ISSUE55_VALUE\" = queued-value && test \"$ISSUE55_SECOND\" = queued-second && ! {s} {s} >/dev/null 2>&1 && : > environment-marker",
        .{ printenv_path, parent_canary },
    );
    defer std.testing.allocator.free(caller_command);
    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ caller_argv0, "-c", caller_command },
        .cwd = .{ .dir = caller_dir },
        .environment = .{ .replace = &caller_map },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    @memset(caller_argv0, 'x');
    @memset(caller_command, 'x');
    try caller_map.put("ISSUE55_VALUE", "caller-mutated");
    try std.testing.expect(caller_map.orderedRemove("ISSUE55_SECOND"));
    caller_map.deinit();
    caller_map_live = false;
    caller_dir.close(std.testing.io);
    caller_dir_live = false;
    try tmp.dir.rename("original", tmp.dir, "renamed", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    switch (entry.input.childCwd()) {
        .dir => {},
        else => return error.TestUnexpectedResult,
    }
    const queued_environment = entry.input.childEnvironment() orelse return error.TestUnexpectedResult;
    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        queued_environment,
    );
    switch (outcome) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }

    try tmp.dir.access(std.testing.io, "renamed/environment-marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "original/environment-marker", .{}));
}

test "foreground environment inherit and empty replacement remain distinct in child" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    const finished = &struct {
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .finished;
        }
    }.done;
    var parent_map = try std.testing.environ.createMap(std.testing.allocator);
    defer parent_map.deinit();
    const parent_canary = try foregroundCommandParentCanary(&parent_map);
    const printenv_path = try foregroundCommandTestPrintenvPath();
    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();

    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ printenv_path, parent_canary },
        .environment = .inherit,
        .finished = finished,
    });
    {
        var pending = app_ctx.requests.detachForegroundCommands();
        defer pending.deinit();
        var entry = pending.next().?;
        defer entry.deinit(std.testing.allocator);
        try std.testing.expect(entry.input.childEnvironment() == null);
        const outcome = foreground_job.testRun(
            std.testing.io,
            entry.input.argv,
            entry.input.childCwd(),
            entry.input.childEnvironment(),
        );
        switch (outcome) {
            .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
            else => return error.TestUnexpectedResult,
        }
    }

    var empty_map: std.process.Environ.Map = .init(std.testing.allocator);
    defer empty_map.deinit();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ printenv_path, parent_canary },
        .environment = .{ .replace = &empty_map },
        .finished = finished,
    });
    {
        var pending = app_ctx.requests.detachForegroundCommands();
        defer pending.deinit();
        var entry = pending.next().?;
        defer entry.deinit(std.testing.allocator);
        const queued_empty = entry.input.childEnvironment() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 0), queued_empty.count());
        const outcome = foreground_job.testRun(
            std.testing.io,
            entry.input.argv,
            entry.input.childCwd(),
            queued_empty,
        );
        switch (outcome) {
            .exited => |code| try std.testing.expect(code != 0),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "foreground command directory cwd keeps identity across rename and caller close" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);
    var caller_dir = try tmp.dir.openDir(std.testing.io, "original", .{});
    var caller_open = true;
    defer if (caller_open) caller_dir.close(std.testing.io);

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ try foregroundCommandTestTouchPath(), "marker" },
        .cwd = .{ .dir = caller_dir },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    const duplicate_fd = switch (entry.input.childCwd()) {
        .dir => |dir| dir.handle,
        else => return error.TestUnexpectedResult,
    };

    caller_dir.close(std.testing.io);
    caller_open = false;
    try tmp.dir.rename("original", tmp.dir, "renamed", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);

    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        entry.input.childEnvironment(),
    );
    switch (outcome) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expect(foregroundCommandProgramTestFdOpen(duplicate_fd));
    try tmp.dir.access(std.testing.io, "renamed/marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "original/marker", .{}));
}

test "foreground command path cwd copies bytes and resolves at spawn time" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);

    const queued_path = try std.fmt.allocPrint(
        std.testing.allocator,
        ".zig-cache/tmp/{s}/original",
        .{tmp.sub_path},
    );
    defer std.testing.allocator.free(queued_path);
    const expected_path = try std.testing.allocator.dupe(u8, queued_path);
    defer std.testing.allocator.free(expected_path);

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{ try foregroundCommandTestTouchPath(), "marker" },
        .cwd = .{ .path = queued_path },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });
    @memset(queued_path, 'x');

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    switch (entry.input.childCwd()) {
        .path => |path| try std.testing.expectEqualStrings(expected_path, path),
        else => return error.TestUnexpectedResult,
    }

    try tmp.dir.rename("original", tmp.dir, "renamed", std.testing.io);
    try tmp.dir.createDir(std.testing.io, "original", .default_dir);
    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        entry.input.childEnvironment(),
    );
    switch (outcome) {
        .exited => |code| try std.testing.expectEqual(@as(u8, 0), code),
        else => return error.TestUnexpectedResult,
    }
    try tmp.dir.access(std.testing.io, "original/marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "renamed/marker", .{}));
}

test "foreground command accepts a duplicable non-directory and reports spawn failure" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) { finished };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(std.testing.io, "not-a-directory", .{});
    defer file.close(std.testing.io);

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{try foregroundCommandTestTouchPath()},
        .cwd = .{ .dir = .{ .handle = file.handle } },
        .finished = &struct {
            fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
                return .finished;
            }
        }.done,
    });

    var pending = app_ctx.requests.detachForegroundCommands();
    defer pending.deinit();
    var entry = pending.next().?;
    defer entry.deinit(std.testing.allocator);
    const outcome = foreground_job.testRun(
        std.testing.io,
        entry.input.argv,
        entry.input.childCwd(),
        entry.input.childEnvironment(),
    );
    switch (outcome) {
        .failed => |f| try std.testing.expectEqual(foreground_command.ForegroundCommandFailure.Stage.spawn, f.stage),
        else => return error.TestUnexpectedResult,
    }
}

test "foreground command processing copies the taken owner before callback requeue" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const TestMsg = union(enum) {
        first_finished,
        second_finished,

        pub const undelivered_policy = .plain;
    };
    const Callbacks = struct {
        fn first(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .first_finished;
        }

        fn second(_: foreground_command.ForegroundCommandResult) TestMsg {
            return .second_finished;
        }
    };
    const TestApp = struct {
        follow_up_dir: std.Io.Dir,
        follow_up_environment: *const std.process.Environ.Map,
        update_count: usize = 0,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), msg: Msg, app_ctx: *ctx_mod.Ctx(Msg)) !void {
            self.update_count += 1;
            switch (msg) {
                .first_finished => _ = try app_ctx.terminal().runForegroundCommand(.{
                    .argv = &.{"second"},
                    .cwd = .{ .dir = self.follow_up_dir },
                    .environment = .{ .replace = self.follow_up_environment },
                    .finished = Callbacks.second,
                }),
                .second_finished => {},
            }
        }
    };
    const Runner = struct {
        first_duplicate: *?std.Io.Dir.Handle,
        first_environment_observed: *bool,

        fn run(
            self: @This(),
            entry: *const requests_mod.Requests(TestMsg).ForegroundCommandEntry,
        ) !foreground_command.ForegroundCommandOutcome {
            self.first_duplicate.* = switch (entry.input.childCwd()) {
                .dir => |dir| dir.handle,
                else => return error.TestUnexpectedResult,
            };
            const environment = entry.input.childEnvironment() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("first", environment.get("ISSUE55_OWNER").?);
            self.first_environment_observed.* = true;
            return .{ .exited = 0 };
        }
    };

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "first", .default_dir);
    try tmp.dir.createDir(std.testing.io, "second", .default_dir);
    const first_dir = try tmp.dir.openDir(std.testing.io, "first", .{});
    defer first_dir.close(std.testing.io);
    const second_dir = try tmp.dir.openDir(std.testing.io, "second", .{});
    defer second_dir.close(std.testing.io);
    var first_environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer first_environment.deinit();
    try first_environment.put("ISSUE55_OWNER", "first");
    var second_environment: std.process.Environ.Map = .init(std.testing.allocator);
    defer second_environment.deinit();
    try second_environment.put("ISSUE55_OWNER", "second");

    var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{
        .argv = &.{"first"},
        .cwd = .{ .dir = first_dir },
        .environment = .{ .replace = &first_environment },
        .finished = Callbacks.first,
    });

    var app: TestApp = .{
        .follow_up_dir = second_dir,
        .follow_up_environment = &second_environment,
    };
    var first_duplicate: ?std.Io.Dir.Handle = null;
    var first_environment_observed = false;
    var stats: ?runtime.RuntimeStats = null;
    _ = try processPendingForegroundCommandsWithRunner(
        TestApp,
        &app,
        &app_ctx,
        std.testing.allocator,
        std.testing.io,
        &stats,
        .{
            .runtime = .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
            },
            .terminal = undefined,
        },
        Runner{
            .first_duplicate = &first_duplicate,
            .first_environment_observed = &first_environment_observed,
        },
    );

    try std.testing.expectEqual(@as(usize, 1), app.update_count);
    try std.testing.expect(first_environment_observed);
    const first_fd = first_duplicate orelse return error.TestUnexpectedResult;
    try std.testing.expect(!foregroundCommandProgramTestFdOpen(first_fd));
    try std.testing.expectEqual(@as(u8, 1), app_ctx.requests._pending_foreground_commands_len);

    const follow_up = app_ctx.requests._pending_foreground_commands[0].input.childCwd();
    const second_fd = switch (follow_up) {
        .dir => |dir| dir.handle,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(foregroundCommandProgramTestFdOpen(second_fd));
    const follow_up_environment = app_ctx.requests._pending_foreground_commands[0].input.childEnvironment() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("second", follow_up_environment.get("ISSUE55_OWNER").?);
    app_ctx.requests.discardPendingEffects();
    try std.testing.expect(!foregroundCommandProgramTestFdOpen(second_fd));
}

test "foreground cleanup covers runner outcome and delivery terminals with replacement environment" {
    if (builtin.os.tag != .linux and builtin.os.tag != .macos) return error.SkipZigTest;

    const Mode = enum {
        terminal_leave_error,
        terminal_restore_error,
        spawn_failure,
        wait_failure,
        exited,
        signaled,
        app_update_error,
        cleanup_failure,
        tty_restore_failure,
        stopped,
    };
    const TestMsg = union(enum) {
        finished,

        pub const undelivered_policy = .plain;
    };
    const TestApp = struct {
        fail_update: bool,
        updates: usize = 0,

        pub const Msg = TestMsg;

        pub fn update(self: *@This(), _: Msg, _: *ctx_mod.Ctx(Msg)) !void {
            self.updates += 1;
            if (self.fail_update) return error.InjectedAppUpdate;
        }
    };
    const Runner = struct {
        mode: Mode,
        duplicate_fd: *?std.Io.Dir.Handle,

        fn run(
            self: @This(),
            entry: *const requests_mod.Requests(TestMsg).ForegroundCommandEntry,
        ) !foreground_command.ForegroundCommandOutcome {
            self.duplicate_fd.* = switch (entry.input.childCwd()) {
                .dir => |dir| dir.handle,
                else => return error.TestUnexpectedResult,
            };
            const environment = entry.input.childEnvironment() orelse return error.TestUnexpectedResult;
            try std.testing.expectEqualStrings("owned", environment.get("ISSUE55_TERMINAL").?);
            return switch (self.mode) {
                .terminal_leave_error => error.InjectedTerminalLeave,
                .terminal_restore_error => error.InjectedTerminalRestore,
                .spawn_failure => foreground_job.failure(.spawn, "InjectedSpawn"),
                .wait_failure => foreground_job.failure(.wait, "InjectedWait"),
                .exited, .app_update_error => .{ .exited = 0 },
                .signaled => .{ .signaled = 15 },
                .stopped => .{ .stopped = 20 },
                .cleanup_failure => foreground_job.failure(.cleanup, "ChildAuthorityLost"),
                .tty_restore_failure => foreground_job.failure(.restore_tty, "InjectedRestore"),
            };
        }
    };
    const Completion = struct {
        var calls: usize = 0;
        fn done(_: foreground_command.ForegroundCommandResult) TestMsg {
            calls += 1;
            return .finished;
        }
    };
    const Harness = struct {
        fn run(mode: Mode, expected_error: ?anyerror) !void {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            try tmp.dir.createDir(std.testing.io, "caller", .default_dir);
            const caller_dir = try tmp.dir.openDir(std.testing.io, "caller", .{});
            defer caller_dir.close(std.testing.io);
            var caller_environment: std.process.Environ.Map = .init(std.testing.allocator);
            defer caller_environment.deinit();
            try caller_environment.put("ISSUE55_TERMINAL", "owned");

            var app_ctx_requests = requests_mod.Requests(TestMsg).init(std.testing.allocator, std.testing.io);
            var app_ctx = ctx_mod.Ctx(TestMsg).init(&app_ctx_requests);
            defer app_ctx.requests.discardPendingEffects();
            Completion.calls = 0;
            _ = try app_ctx.terminal().runForegroundCommand(.{
                .argv = &.{"command"},
                .cwd = .{ .dir = caller_dir },
                .environment = .{ .replace = &caller_environment },
                .finished = Completion.done,
            });

            var duplicate_fd: ?std.Io.Dir.Handle = null;
            var app: TestApp = .{ .fail_update = mode == .app_update_error };
            var stats: ?runtime.RuntimeStats = null;
            const result = processPendingForegroundCommandsWithRunner(
                TestApp,
                &app,
                &app_ctx,
                std.testing.allocator,
                std.testing.io,
                &stats,
                .{
                    .runtime = .{
                        .allocator = std.testing.allocator,
                        .io = std.testing.io,
                    },
                    .terminal = undefined,
                },
                Runner{ .mode = mode, .duplicate_fd = &duplicate_fd },
            );
            if (result) |_| {
                try std.testing.expect(expected_error == null);
            } else |err| {
                try std.testing.expectEqual(expected_error orelse return err, err);
            }

            try std.testing.expectEqual(@as(usize, 1), Completion.calls);
            try std.testing.expectEqual(@as(usize, if (expected_error != null and expected_error.? == error.ForegroundRecoveryFailed) 0 else 1), app.updates);
            const owned_fd = duplicate_fd orelse return error.TestUnexpectedResult;
            try std.testing.expect(!foregroundCommandProgramTestFdOpen(owned_fd));
            try std.testing.expect(foregroundCommandProgramTestFdOpen(caller_dir.handle));
            try std.testing.expectEqual(@as(u8, 0), app_ctx.requests._pending_foreground_commands_len);
        }
    };

    const cases = [_]struct { mode: Mode, expected_error: ?anyerror }{
        .{ .mode = .terminal_leave_error, .expected_error = error.ForegroundRecoveryFailed },
        .{ .mode = .terminal_restore_error, .expected_error = error.ForegroundRecoveryFailed },
        .{ .mode = .spawn_failure, .expected_error = null },
        .{ .mode = .wait_failure, .expected_error = null },
        .{ .mode = .exited, .expected_error = null },
        .{ .mode = .signaled, .expected_error = null },
        .{ .mode = .app_update_error, .expected_error = error.InjectedAppUpdate },
        .{ .mode = .cleanup_failure, .expected_error = error.ForegroundRecoveryFailed },
        .{ .mode = .tty_restore_failure, .expected_error = error.ForegroundRecoveryFailed },
        .{ .mode = .stopped, .expected_error = null },
    };
    for (cases) |case| try Harness.run(case.mode, case.expected_error);
}

test "foreground shutdown abandons queued command once and rejects followups" {
    const Harness = struct {
        var calls: usize = 0;
        var frees: usize = 0;
        const Msg = struct {
            pub const undelivered_policy = .deinit;
            bytes: []u8,
            pub fn deinitUndelivered(self: *@This(), allocator: std.mem.Allocator) void {
                allocator.free(self.bytes);
                frees += 1;
            }
        };
        fn done(result: foreground_command.ForegroundCommandResult) Msg {
            std.debug.assert(result.outcome == .runtime_abandoned);
            calls += 1;
            return .{ .bytes = std.testing.allocator.dupe(u8, "completion") catch unreachable };
        }
    };
    Harness.calls = 0;
    Harness.frees = 0;
    var app_ctx_requests = requests_mod.Requests(Harness.Msg).init(std.testing.allocator, std.testing.io);
    var app_ctx = ctx_mod.Ctx(Harness.Msg).init(&app_ctx_requests);
    defer app_ctx.requests.discardPendingEffects();
    _ = try app_ctx.terminal().runForegroundCommand(.{ .argv = &.{"never-spawn"}, .finished = Harness.done });
    app_ctx.quit();
    discardQueuedForegroundCommands(Harness.Msg, &app_ctx, std.testing.allocator);
    discardQueuedForegroundCommands(Harness.Msg, &app_ctx, std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), Harness.calls);
    try std.testing.expectEqual(@as(usize, 1), Harness.frees);
    try std.testing.expectError(error.ForegroundCommandRuntimeStopped, app_ctx.terminal().runForegroundCommand(.{ .argv = &.{"never-spawn"}, .finished = Harness.done }));
}
