const contract = @import("timer_contract");

const Msg = enum {
    done,
    pub const TimerNotice = union(enum) { empty, nested: ?struct { refs: [1]*const u8 } };
};

comptime {
    _ = contract.Notice(Msg);
}
