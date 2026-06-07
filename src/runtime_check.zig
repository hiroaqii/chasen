const runtime = @import("chasen_runtime");

pub export fn chasen_runtime_compile_check() void {
    const Msg = enum { done };
    var ctx: runtime.Ctx(Msg) = .{};
    ctx.quit();
    ctx.frame().suppressRedraw();
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
