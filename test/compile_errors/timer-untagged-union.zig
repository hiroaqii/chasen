const contract = @import("timer_contract");

const Msg = enum {
    done,
    pub const TimerNotice = union { generation: u64, flag: bool };
};

comptime {
    _ = contract.Notice(Msg);
}
