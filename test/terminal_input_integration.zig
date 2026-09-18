const std = @import("std");
const vaxis = @import("vaxis");

const c = @cImport({
    @cInclude("pty.h");
});

const read_buffer_len = 1024;
const filler_key: u21 = 'x';
const sentinel_key: u21 = 'q';
const idle_limit = 2_000;

const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
};

const EventLoop = vaxis.Loop(Event);

const MouseCase = struct {
    name: []const u8,
    sequence: []const u8,
    button: vaxis.Mouse.Button,
    col: i16,
    row: i16,
};

const PtyFixture = struct {
    io: std.Io,
    master: std.Io.File,
    tty_buffer: [4096]u8,
    tty: vaxis.Tty,
    loop: EventLoop,

    fn init(self: *PtyFixture, io: std.Io, vx: *vaxis.Vaxis) !void {
        var master_fd: c_int = undefined;
        var slave_fd: c_int = undefined;
        var winsize: c.struct_winsize = .{
            .ws_row = 24,
            .ws_col = 80,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.openpty(&master_fd, &slave_fd, null, null, &winsize) != 0) {
            return error.OpenPtyFailed;
        }
        const master: std.Io.File = .{
            .handle = master_fd,
            .flags = .{ .nonblocking = false },
        };
        const slave: std.Io.File = .{
            .handle = slave_fd,
            .flags = .{ .nonblocking = false },
        };
        errdefer master.close(io);
        errdefer slave.close(io);

        const original_termios = try vaxis.tty.PosixTty.makeRaw(slave_fd);

        self.io = io;
        self.master = master;
        self.tty_buffer = undefined;
        self.tty = .{
            .io = io,
            .termios = original_termios,
            .fd = slave,
            .tty_writer = slave.writerStreaming(io, &self.tty_buffer),
        };
        self.loop = .init(io, &self.tty, vx);
    }

    fn deinit(self: *PtyFixture) void {
        self.loop.should_quit = true;
        if (self.loop.thread) |*future| {
            _ = future.cancel(self.io);
            self.loop.thread = null;
        }
        self.loop.should_quit = false;
        self.tty.deinit();
        self.master.close(self.io);
    }

    fn writeAll(self: *PtyFixture, bytes: []const u8) !void {
        try self.master.writeStreamingAll(self.io, bytes);
    }
};

pub fn main(init: std.process.Init) !void {
    var vx = try vaxis.init(init.io, init.gpa, init.environ_map, .{});
    var deinit_writer: std.Io.Writer.Allocating = .init(init.gpa);
    defer deinit_writer.deinit();
    defer vx.deinit(init.gpa, &deinit_writer.writer);

    const cases = [_]MouseCase{
        .{
            .name = "wheel-up",
            .sequence = "\x1b[<64;1;1M",
            .button = .wheel_up,
            .col = 0,
            .row = 0,
        },
        .{
            .name = "wheel-down-multi-digit",
            .sequence = "\x1b[<65;123;45M",
            .button = .wheel_down,
            .col = 122,
            .row = 44,
        },
    };

    for (cases) |case| {
        for (1..case.sequence.len) |split_at| {
            try runSplitMouseCase(init.io, &vx, case, split_at);
        }
    }
    try runStandaloneEscapeCase(init.io, &vx);
}

/// Force the first 1024-byte terminal read to end at every possible byte in an
/// SGR wheel report. The remainder is already queued in the PTY, matching a
/// wheel burst whose escape sequence happens to straddle two reads.
fn runSplitMouseCase(
    io: std.Io,
    vx: *vaxis.Vaxis,
    case: MouseCase,
    split_at: usize,
) !void {
    std.debug.assert(split_at > 0 and split_at < case.sequence.len);

    var fixture: PtyFixture = undefined;
    try fixture.init(io, vx);
    defer fixture.deinit();

    const filler_len = read_buffer_len - split_at;
    var burst: [read_buffer_len + 64]u8 = undefined;
    @memset(burst[0..filler_len], @intCast(filler_key));
    @memcpy(burst[filler_len .. filler_len + case.sequence.len], case.sequence);
    const sentinel_index = filler_len + case.sequence.len;
    burst[sentinel_index] = @intCast(sentinel_key);

    // Queue the whole burst before the reader starts. This makes the first
    // read's 1024-byte boundary deterministic while keeping the continuation
    // immediately available to libvaxis' zero-time poll.
    try fixture.writeAll(burst[0 .. sentinel_index + 1]);
    try fixture.loop.start();

    var filler_count: usize = 0;
    var mouse_count: usize = 0;
    var idle_count: usize = 0;
    while (true) {
        const maybe_event = try fixture.loop.tryEvent();
        if (maybe_event == null) {
            idle_count += 1;
            if (idle_count >= idle_limit) {
                std.debug.print(
                    "{s} split {d}: timed out after {d} filler keys and {d} mouse events\n",
                    .{ case.name, split_at, filler_count, mouse_count },
                );
                return error.TerminalInputTimeout;
            }
            try io.sleep(.fromMilliseconds(1), .awake);
            continue;
        }
        idle_count = 0;

        switch (maybe_event.?) {
            .key_press => |key| {
                if (key.codepoint == filler_key and key.mods.eql(.{})) {
                    filler_count += 1;
                    continue;
                }
                if (key.codepoint == sentinel_key and key.mods.eql(.{})) break;

                std.debug.print(
                    "{s} split {d}: mouse bytes leaked as key U+{X} (alt={}, ctrl={}, shift={})\n",
                    .{
                        case.name,
                        split_at,
                        key.codepoint,
                        key.mods.alt,
                        key.mods.ctrl,
                        key.mods.shift,
                    },
                );
                return error.MouseSequenceLeakedAsKey;
            },
            .mouse => |mouse| {
                mouse_count += 1;
                if (mouse_count != 1 or
                    mouse.button != case.button or
                    mouse.type != .press or
                    mouse.col != case.col or
                    mouse.row != case.row or
                    !std.meta.eql(mouse.mods, vaxis.Mouse.Modifiers{}))
                {
                    std.debug.print(
                        "{s} split {d}: unexpected mouse event {any}\n",
                        .{ case.name, split_at, mouse },
                    );
                    return error.UnexpectedMouseEvent;
                }
            },
        }
    }

    if (filler_count != filler_len or mouse_count != 1) {
        std.debug.print(
            "{s} split {d}: expected {d} filler keys and one mouse event, got {d} and {d}\n",
            .{ case.name, split_at, filler_len, filler_count, mouse_count },
        );
        return error.IncompleteTerminalInput;
    }
}

/// The split-sequence fix must not turn a genuine, standalone Esc press into a
/// pending prefix. Send the sentinel only after Esc has been observed.
fn runStandaloneEscapeCase(io: std.Io, vx: *vaxis.Vaxis) !void {
    var fixture: PtyFixture = undefined;
    try fixture.init(io, vx);
    defer fixture.deinit();

    try fixture.loop.start();
    try fixture.writeAll("\x1b");
    try expectKey(io, &fixture.loop, vaxis.Key.escape, "standalone Esc");

    try fixture.writeAll("3");
    try expectKey(io, &fixture.loop, '3', "ordinary digit");
}

fn expectKey(io: std.Io, loop: *EventLoop, expected: u21, label: []const u8) !void {
    var idle_count: usize = 0;
    while (idle_count < idle_limit) {
        if (try loop.tryEvent()) |event| {
            switch (event) {
                .key_press => |key| {
                    if (key.codepoint == expected and key.mods.eql(.{})) return;
                    std.debug.print(
                        "{s}: expected U+{X}, got key U+{X} with modifiers {any}\n",
                        .{ label, expected, key.codepoint, key.mods },
                    );
                    return error.UnexpectedKey;
                },
                .mouse => |mouse| {
                    std.debug.print("{s}: unexpected mouse event {any}\n", .{ label, mouse });
                    return error.UnexpectedMouseEvent;
                },
            }
        }
        idle_count += 1;
        try io.sleep(.fromMilliseconds(1), .awake);
    }

    std.debug.print("{s}: timed out waiting for U+{X}\n", .{ label, expected });
    return error.TerminalInputTimeout;
}
