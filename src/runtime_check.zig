const std = @import("std");
const runtime = @import("chasen_runtime");

pub export fn chasen_runtime_compile_check(allocator: *const std.mem.Allocator, io: *const std.Io) void {
    const Msg = enum { done };
    var requests = runtime.Requests(Msg).init(allocator.*, io.*);
    defer requests.deinit();
    var ctx = runtime.Ctx(Msg).init(&requests);
    ctx.quit();
    ctx.redraw().skip();
    ctx.frame().request();

    const stats = runtime.RuntimeStats{
        .event_kind = .user_msg,
        .event_count = 1,
        .frame_count = 0,
        .did_update = true,
    };
    _ = stats;

    if (!runtime.BrowserInitialEffects.isSupported(.dispatch)) unreachable;
    if (runtime.BrowserInitialEffects.isSupported(.spawn)) unreachable;
}
