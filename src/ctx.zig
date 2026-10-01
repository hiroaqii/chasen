const std = @import("std");
const requests_mod = @import("requests.zig");

pub const TaskId = requests_mod.TaskId;
pub const TaskStartError = requests_mod.TaskStartError;

/// App-facing request window. The initialized owner must outlive this borrow.
/// Apps may use it only during init/update on the owning runtime thread.
pub fn Ctx(comptime Msg: type) type {
    const Requests = requests_mod.Requests(Msg);
    return struct {
        requests: *Requests,

        pub fn init(requests: *Requests) @This() {
            return .{ .requests = requests };
        }
        pub const SpawnOptions = Requests.SpawnOptions;
        pub const FrameEffects = Requests.FrameEffects;
        pub const RedrawEffects = Requests.RedrawEffects;
        pub const TaskEffects = Requests.TaskEffects;
        pub const TimerEffects = Requests.TimerEffects;
        pub const ImageEffects = Requests.ImageEffects;
        pub const TerminalEffects = Requests.TerminalEffects;
        pub const TerminalImageLoadedFn = Requests.TerminalImageLoadedFn;
        pub const TerminalImageFailedFn = Requests.TerminalImageFailedFn;
        pub const ForegroundCommandFinishedFn = Requests.ForegroundCommandFinishedFn;
        pub const ClipboardCopyFinishedFn = Requests.ClipboardCopyFinishedFn;
        pub const ClipboardCopyOutcome = Requests.ClipboardCopyOutcome;
        pub const ClipboardCopyResult = Requests.ClipboardCopyResult;
        pub const ClipboardCopyRequestId = Requests.ClipboardCopyRequestId;

        pub fn quit(self: *@This()) void {
            self.requests.quit();
        }
        pub fn shouldQuit(self: *const @This()) bool {
            return self.requests.shouldQuit();
        }
        pub fn frame(self: *@This()) FrameEffects {
            return self.requests.frame();
        }
        pub fn redraw(self: *@This()) RedrawEffects {
            return self.requests.redraw();
        }
        pub fn task(self: *@This()) TaskEffects {
            return self.requests.task();
        }
        pub fn timer(self: *@This()) TimerEffects {
            return self.requests.timer();
        }
        pub fn image(self: *@This()) ImageEffects {
            return self.requests.image();
        }
        pub fn terminal(self: *@This()) TerminalEffects {
            return self.requests.terminal();
        }
        pub fn now(self: *const @This()) std.Io.Timestamp {
            return self.requests.now();
        }
        pub fn allocator(self: *const @This()) std.mem.Allocator {
            return self.requests.allocator();
        }
        pub fn io(self: *const @This()) std.Io {
            return self.requests.io();
        }
    };
}

test "Ctx uses explicitly initialized request environment" {
    var requests = requests_mod.Requests(u8).init(std.testing.allocator, std.testing.io);
    defer requests.deinit();
    var ctx = Ctx(u8).init(&requests);
    ctx.frame().request();
    ctx.redraw().skip();
    ctx.quit();
    try std.testing.expect(ctx.shouldQuit());
    try std.testing.expect(requests.takeFrameRequest());
    try std.testing.expect(requests.redrawWasSuppressed());
    const bytes = try ctx.allocator().alloc(u8, 8);
    defer ctx.allocator().free(bytes);
    _ = ctx.now();
}
