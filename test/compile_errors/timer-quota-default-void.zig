const chasen = @import("chasen");

const Msg = enum { done };

export fn rejectRaisedQuota() void {
    comptime {
        _ = chasen.runtime.Requests(Msg);
        // The default void path must leave the caller's quota unchanged too.
        var i: usize = 0;
        while (i < 1_500) : (i += 1) {}
    }
}
