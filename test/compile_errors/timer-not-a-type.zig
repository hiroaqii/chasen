const contract = @import("timer_contract");

const Msg = enum {
    done,
    pub const TimerNotice = 42;
};

comptime {
    _ = contract.Notice(Msg);
}
