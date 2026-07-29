const std = @import("std");
const vaxis = @import("vaxis");

pub const CoordinateProtocol = enum {
    cell_sgr,
    auto,
};

const mouse_set_cell = "\x1b[?1002;1003;1004;1006h";
const mouse_set_pixels = "\x1b[?1002;1003;1004;1016h";
const mouse_reset = "\x1b[?1002;1003;1004;1006;1016l";

/// Terminal mouse protocol selection owned by one runtime invocation.
///
/// Callers stop the vaxis reader before entering or leaving so the wire
/// protocol and `state.pixel_mouse` cannot be observed in different states.
pub const Policy = struct {
    enabled: bool,
    coordinate_protocol: CoordinateProtocol,

    pub fn enterWithReader(
        self: Policy,
        vx: *vaxis.Vaxis,
        writer: *std.Io.Writer,
        reader: anytype,
    ) !void {
        reader.stop();
        try self.enter(vx, writer);
        try reader.start();
    }

    pub fn leaveWithReader(
        self: Policy,
        vx: *vaxis.Vaxis,
        writer: *std.Io.Writer,
        reader: anytype,
    ) !void {
        reader.stop();
        try self.leave(vx, writer);
    }

    fn enter(self: Policy, vx: *vaxis.Vaxis, writer: *std.Io.Writer) !void {
        if (!self.enabled) return;

        const pixel_coordinates = self.coordinate_protocol == .auto and
            vx.caps.sgr_pixels;

        // Publish the matching interpretation before the terminal can accept
        // the enable sequence. A failed write retains this desired state so a
        // reader is never restarted with an ambiguous coordinate unit.
        vx.state.mouse = true;
        vx.state.pixel_mouse = pixel_coordinates;

        try writer.writeAll(if (pixel_coordinates) mouse_set_pixels else mouse_set_cell);
        try writer.flush();
    }

    fn leave(self: Policy, vx: *vaxis.Vaxis, writer: *std.Io.Writer) !void {
        if (!self.enabled) return;

        // Retain the prior interpretation until reset has been written and
        // flushed. On failure, vaxis deinit can see `state.mouse` and retry.
        try writer.writeAll(mouse_reset);
        try writer.flush();
        vx.state.mouse = false;
        vx.state.pixel_mouse = false;
    }
};

const TestReader = struct {
    running: bool = true,
    stop_count: usize = 0,
    start_count: usize = 0,
    fail_start: bool = false,

    pub fn stop(self: *TestReader) void {
        self.running = false;
        self.stop_count += 1;
    }

    pub fn start(self: *TestReader) !void {
        self.start_count += 1;
        if (self.fail_start) return error.StartFailed;
        self.running = true;
    }
};

const ProbeWriter = struct {
    const Failure = enum {
        none,
        write,
        flush,
    };

    writer: std.Io.Writer,
    vx: *vaxis.Vaxis,
    reader: *TestReader,
    expected_mouse: bool,
    expected_pixel_mouse: bool,
    failure: Failure,
    output: [128]u8 = undefined,
    output_len: usize = 0,
    write_count: usize = 0,
    flush_count: usize = 0,
    first_write_state_matched: bool = false,

    fn init(
        vx: *vaxis.Vaxis,
        reader: *TestReader,
        expected_mouse: bool,
        expected_pixel_mouse: bool,
        failure: Failure,
    ) ProbeWriter {
        return .{
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                    .flush = flush,
                },
                .buffer = &.{},
            },
            .vx = vx,
            .reader = reader,
            .expected_mouse = expected_mouse,
            .expected_pixel_mouse = expected_pixel_mouse,
            .failure = failure,
        };
    }

    fn bytes(self: *const ProbeWriter) []const u8 {
        return self.output[0..self.output_len];
    }

    fn append(self: *ProbeWriter, bytes_to_append: []const u8) void {
        std.debug.assert(self.output_len + bytes_to_append.len <= self.output.len);
        @memcpy(self.output[self.output_len..][0..bytes_to_append.len], bytes_to_append);
        self.output_len += bytes_to_append.len;
    }

    fn drain(
        writer: *std.Io.Writer,
        data: []const []const u8,
        splat: usize,
    ) std.Io.Writer.Error!usize {
        const self: *ProbeWriter = @alignCast(@fieldParentPtr("writer", writer));
        if (self.write_count == 0) {
            self.first_write_state_matched =
                !self.reader.running and
                self.vx.state.mouse == self.expected_mouse and
                self.vx.state.pixel_mouse == self.expected_pixel_mouse;
        }
        self.write_count += 1;
        if (self.failure == .write) return error.WriteFailed;

        var consumed: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            self.append(chunk);
            consumed += chunk.len;
        }
        for (0..splat) |_| {
            self.append(data[data.len - 1]);
            consumed += data[data.len - 1].len;
        }
        return consumed;
    }

    fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const self: *ProbeWriter = @alignCast(@fieldParentPtr("writer", writer));
        self.flush_count += 1;
        if (self.failure == .flush) return error.WriteFailed;
    }
};

const TestVaxis = struct {
    env_map: std.process.Environ.Map,
    vx: vaxis.Vaxis,
    deinit_writer: std.Io.Writer.Allocating,

    fn init(self: *TestVaxis) !void {
        self.env_map = try std.testing.environ.createMap(std.testing.allocator);
        errdefer self.env_map.deinit();
        self.vx = try vaxis.Vaxis.init(
            std.testing.io,
            std.testing.allocator,
            &self.env_map,
            .{},
        );
        self.deinit_writer = .init(std.testing.allocator);
    }

    fn deinit(self: *TestVaxis) void {
        self.vx.deinit(std.testing.allocator, &self.deinit_writer.writer);
        self.deinit_writer.deinit();
        self.env_map.deinit();
    }
};

test "mouse coordinate protocol cell sgr is portable and resets state" {
    var fixture: TestVaxis = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.vx.caps.sgr_pixels = true;

    const policy: Policy = .{
        .enabled = true,
        .coordinate_protocol = .cell_sgr,
    };
    var reader: TestReader = .{};
    var enter_writer = ProbeWriter.init(&fixture.vx, &reader, true, false, .none);
    try policy.enterWithReader(&fixture.vx, &enter_writer.writer, &reader);

    try std.testing.expectEqualStrings(mouse_set_cell, enter_writer.bytes());
    try std.testing.expect(enter_writer.first_write_state_matched);
    try std.testing.expect(fixture.vx.caps.sgr_pixels);
    try std.testing.expect(fixture.vx.state.mouse);
    try std.testing.expect(!fixture.vx.state.pixel_mouse);
    try std.testing.expect(reader.running);
    try std.testing.expectEqual(@as(usize, 1), reader.start_count);

    fixture.vx.screen.width = 10;
    fixture.vx.screen.height = 5;
    fixture.vx.screen.width_pix = 100;
    fixture.vx.screen.height_pix = 50;
    const raw: vaxis.Mouse = .{
        .col = 35,
        .row = 27,
        .button = .left,
        .mods = .{},
        .type = .press,
    };
    const cell = fixture.vx.translateMouse(raw);
    try std.testing.expectEqual(@as(i16, 35), cell.col);
    try std.testing.expectEqual(@as(i16, 27), cell.row);
    try std.testing.expectEqual(@as(u16, 0), cell.xoffset);
    try std.testing.expectEqual(@as(u16, 0), cell.yoffset);

    var leave_writer = ProbeWriter.init(&fixture.vx, &reader, true, false, .none);
    try policy.leaveWithReader(&fixture.vx, &leave_writer.writer, &reader);
    try std.testing.expectEqualStrings(mouse_reset, leave_writer.bytes());
    try std.testing.expect(leave_writer.first_write_state_matched);
    try std.testing.expect(!fixture.vx.state.mouse);
    try std.testing.expect(!fixture.vx.state.pixel_mouse);
    try std.testing.expect(!reader.running);
}

test "mouse coordinate protocol auto preserves capability behavior on reentry" {
    var fixture: TestVaxis = undefined;
    try fixture.init();
    defer fixture.deinit();
    fixture.vx.caps.sgr_pixels = true;

    const policy: Policy = .{
        .enabled = true,
        .coordinate_protocol = .auto,
    };
    var reader: TestReader = .{};
    var first_writer = ProbeWriter.init(&fixture.vx, &reader, true, true, .none);
    try policy.enterWithReader(&fixture.vx, &first_writer.writer, &reader);
    try std.testing.expectEqualStrings(mouse_set_pixels, first_writer.bytes());
    try std.testing.expect(first_writer.first_write_state_matched);

    fixture.vx.screen.width = 10;
    fixture.vx.screen.height = 5;
    fixture.vx.screen.width_pix = 100;
    fixture.vx.screen.height_pix = 50;
    const translated = fixture.vx.translateMouse(.{
        .col = 35,
        .row = 27,
        .button = .left,
        .mods = .{},
        .type = .drag,
    });
    try std.testing.expectEqual(@as(i16, 3), translated.col);
    try std.testing.expectEqual(@as(i16, 2), translated.row);
    try std.testing.expectEqual(@as(u16, 5), translated.xoffset);
    try std.testing.expectEqual(@as(u16, 7), translated.yoffset);

    var leave_writer = ProbeWriter.init(&fixture.vx, &reader, true, true, .none);
    try policy.leaveWithReader(&fixture.vx, &leave_writer.writer, &reader);
    try std.testing.expect(!fixture.vx.state.pixel_mouse);

    var second_writer = ProbeWriter.init(&fixture.vx, &reader, true, true, .none);
    try policy.enterWithReader(&fixture.vx, &second_writer.writer, &reader);
    try std.testing.expectEqualStrings(mouse_set_pixels, second_writer.bytes());

    var second_leave_writer = ProbeWriter.init(&fixture.vx, &reader, true, true, .none);
    try policy.leaveWithReader(&fixture.vx, &second_leave_writer.writer, &reader);
    fixture.vx.caps.sgr_pixels = false;
    var fallback_writer = ProbeWriter.init(&fixture.vx, &reader, true, false, .none);
    try policy.enterWithReader(&fixture.vx, &fallback_writer.writer, &reader);
    try std.testing.expectEqualStrings(mouse_set_cell, fallback_writer.bytes());
    try std.testing.expect(!fixture.vx.state.pixel_mouse);
}

test "mouse coordinate protocol failures retain interpretation without restart" {
    for ([_]ProbeWriter.Failure{ .write, .flush }) |failure| {
        var fixture: TestVaxis = undefined;
        try fixture.init();
        defer fixture.deinit();
        fixture.vx.caps.sgr_pixels = true;

        const policy: Policy = .{
            .enabled = true,
            .coordinate_protocol = .auto,
        };
        var reader: TestReader = .{};
        var failing_enter = ProbeWriter.init(&fixture.vx, &reader, true, true, failure);
        try std.testing.expectError(
            error.WriteFailed,
            policy.enterWithReader(&fixture.vx, &failing_enter.writer, &reader),
        );
        try std.testing.expect(failing_enter.first_write_state_matched);
        try std.testing.expect(!reader.running);
        try std.testing.expectEqual(@as(usize, 0), reader.start_count);
        try std.testing.expect(fixture.vx.state.mouse);
        try std.testing.expect(fixture.vx.state.pixel_mouse);

        var failing_cleanup = ProbeWriter.init(&fixture.vx, &reader, true, true, failure);
        try std.testing.expectError(
            error.WriteFailed,
            policy.leaveWithReader(&fixture.vx, &failing_cleanup.writer, &reader),
        );
        try std.testing.expect(fixture.vx.state.mouse);
        try std.testing.expect(fixture.vx.state.pixel_mouse);

        var retry_writer = ProbeWriter.init(&fixture.vx, &reader, true, true, .none);
        try policy.leaveWithReader(&fixture.vx, &retry_writer.writer, &reader);
        try std.testing.expectEqualStrings(mouse_reset, retry_writer.bytes());
        try std.testing.expect(!fixture.vx.state.mouse);
        try std.testing.expect(!fixture.vx.state.pixel_mouse);
    }
}

test "mouse coordinate protocol lifecycle blocks restart and child admission on failure" {
    var fixture: TestVaxis = undefined;
    try fixture.init();
    defer fixture.deinit();

    const policy: Policy = .{
        .enabled = true,
        .coordinate_protocol = .cell_sgr,
    };
    var reader: TestReader = .{ .fail_start = true };
    var enter_writer = ProbeWriter.init(&fixture.vx, &reader, true, false, .none);
    try std.testing.expectError(
        error.StartFailed,
        policy.enterWithReader(&fixture.vx, &enter_writer.writer, &reader),
    );
    try std.testing.expect(!reader.running);
    try std.testing.expect(fixture.vx.state.mouse);
    try std.testing.expect(!fixture.vx.state.pixel_mouse);

    reader.fail_start = false;
    reader.running = true;
    var child_admitted = false;
    var leave_writer = ProbeWriter.init(&fixture.vx, &reader, true, false, .flush);
    if (policy.leaveWithReader(&fixture.vx, &leave_writer.writer, &reader)) {
        child_admitted = true;
    } else |err| {
        try std.testing.expectEqual(error.WriteFailed, err);
    }
    try std.testing.expect(!child_admitted);
    try std.testing.expect(!reader.running);
    try std.testing.expect(fixture.vx.state.mouse);
}
