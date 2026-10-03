const contract = @import("timer_contract");

const Msg = enum {
    done,
    pub const TimerNotice = *const u8;
};

comptime {
    _ = contract.Notice(Msg);
}
