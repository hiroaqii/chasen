const chasen = @import("chasen");

const Msg = enum {
    done,
    pub const TimerNotice = fn () void;
};

export fn rejectInvalidNotice() void {
    var requests = chasen.runtime.Requests(Msg).init(undefined, undefined);
    requests.timer().tick("reject", 0, undefined, undefined) catch unreachable;
}
