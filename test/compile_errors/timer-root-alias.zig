const contract = @import("timer_contract");

const Msg = enum {
    done,
    pub const TimerNotice = @This();
};

comptime {
    _ = contract.Notice(Msg);
}
