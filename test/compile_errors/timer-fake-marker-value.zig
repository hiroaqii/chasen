const contract = @import("timer_contract");

const Msg = enum {
    done,
    pub const TimerNotice = struct {
        pub const BorrowedRef = 1;
        value: []const u8,
    };
};

comptime {
    _ = contract.Notice(Msg);
}
