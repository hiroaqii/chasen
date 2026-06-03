const runtime = @import("chasen_runtime");

pub export fn chasen_runtime_compile_check() void {
    const Msg = enum { done };
    var ctx: runtime.Ctx(Msg) = .{};
    ctx.quit();
    ctx.suppressRedraw();
    ctx.requestFrame();

    const stats = runtime.RuntimeStats{
        .event_kind = .user_msg,
        .event_count = 1,
        .frame_count = 0,
        .did_update = true,
    };
    _ = stats;
}
