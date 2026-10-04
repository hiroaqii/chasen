const chasen = @import("chasen");

const Msg = enum {
    done,
    pub const TimerNotice = void;
};

export fn rejectRaisedQuota() void {
    comptime {
        _ = chasen.runtime.Requests(Msg);
        // An explicit void declaration follows the same caller quota contract.
        var i: usize = 0;
        while (i < 1_500) : (i += 1) {}
    }
}
