const contract = @import("timer_contract");

const Msg = enum {
    done,
    pub const TimerNotice = error{Failed}!u64;
};

comptime {
    _ = contract.Notice(Msg);
}
