const chasen = @import("chasen");

const Msg = enum {
    done,
    pub const TimerNotice = union(enum) { empty, nested: ?struct { refs: [1]*const u8 } };
};

export fn rejectInvalidNotice() void {
    var requests = chasen.runtime.Requests(Msg).init(undefined, undefined);
    requests.timer().tick("reject", 0, undefined, undefined) catch unreachable;
}
