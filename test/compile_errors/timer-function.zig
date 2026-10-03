const contract = @import("timer_contract");

const Msg = enum {
    done,
    pub const TimerNotice = fn () void;
};

comptime {
    _ = contract.Notice(Msg);
}
