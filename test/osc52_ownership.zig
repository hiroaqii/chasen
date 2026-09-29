const std = @import("std");
const vaxis = @import("vaxis");
const program = @import("chasen_program");

const TestMsg = union(enum) {
    noop,

    pub const undelivered_policy = .plain;
};
const Event = program.InternalEvent(TestMsg);

// Build as an executable, not a Zig test artifact: the pinned libvaxis TestTty
// lacks resetSignalHandler on macOS. Its production Tty has that method. This
// check never opens a terminal or starts a reader, and only delivers paste.
pub fn main(init: std.process.Init) !void {
    if (@hasField(Event, "paste")) return error.InternalEventOwnsPaste;

    var gpa: std.heap.DebugAllocator(.{
        .safety = true,
        .enable_memory_limit = true,
    }) = .init;
    defer if (gpa.deinit() == .leak) @panic("OSC 52 ownership check leaked memory");
    const allocator = gpa.allocator();

    var loop = vaxis.Loop(Event).init(init.io, undefined, undefined);
    var queued: usize = 0;
    while (try loop.tryPostEvent(.continue_effect_drain)) queued += 1;
    if (queued == 0) return error.EmptyQueue;

    var parser: vaxis.Parser = .{};
    var cache: vaxis.GraphemeCache = .{};
    const cases = [_]struct { input: []const u8, text: []const u8 }{
        .{ .input = "\x1b]52;c;Zmlyc3Q=\x1b\\", .text = "first" },
        .{ .input = "\x1b]52;c;c2Vjb25k\x1b\\", .text = "second" },
    };
    for (cases) |case| {
        const result = try parser.parse(case.input, allocator);
        if (result.n != case.input.len) return error.IncompleteResponse;
        const event = result.event orelse return error.MissingPaste;
        if (event != .paste) return error.ExpectedPaste;
        if (!std.mem.eql(u8, case.text, event.paste)) return error.IncorrectPaste;
        if (gpa.total_requested_bytes == 0) return error.ExpectedOwnedPaste;

        // Use the runtime's real event type and libvaxis handler. An unsolicited
        // response must be freed immediately, even when the queue is full.
        try vaxis.loop.handleEventGeneric(
            &loop,
            undefined,
            &cache,
            Event,
            event,
            allocator,
        );
        if (gpa.total_requested_bytes != 0) return error.PasteNotFreed;
        if (try loop.tryPostEvent(.continue_effect_drain)) return error.QueueChanged;
    }

    // Invalid base64 must also release its temporary decode buffer.
    const invalid_input = "\x1b]52;c;!!!!\x1b\\";
    const invalid_result = try parser.parse(invalid_input, allocator);
    if (invalid_result.n != invalid_input.len) return error.IncompleteResponse;
    if (invalid_result.event != null) return error.InvalidResponseProducedEvent;
    if (gpa.total_requested_bytes != 0) return error.InvalidResponseNotFreed;

    var drained: usize = 0;
    while (try loop.tryEvent()) |event| {
        if (event != .continue_effect_drain) return error.UnexpectedQueuedEvent;
        drained += 1;
    }
    if (drained != queued) return error.QueueChanged;
}
