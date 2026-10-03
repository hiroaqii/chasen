const chasen = @import("chasen");

const Msg = enum {
    done,
    pub const TimerNotice = @This();
};

export fn rejectInvalidNotice() void {
    var requests = chasen.runtime.Requests(Msg).init(undefined, undefined);
    requests.timer().tick("reject", 0, undefined, undefined) catch unreachable;
}
