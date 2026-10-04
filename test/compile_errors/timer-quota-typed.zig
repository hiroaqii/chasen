const chasen = @import("chasen");

const Msg = enum {
    done,
    pub const TimerNotice = struct { generation: u64 };
};

export fn rejectRaisedQuota() void {
    comptime {
        _ = chasen.runtime.Requests(Msg);
        // Resolving a notice must not raise the caller's evaluation quota.
        var i: usize = 0;
        while (i < 1_500) : (i += 1) {}
    }
}
