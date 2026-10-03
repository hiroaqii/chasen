const chasen = @import("chasen");
const Msg = enum { done };

export fn rejectMissingCallback() void {
    var requests = chasen.runtime.Requests(Msg).init(undefined, undefined);
    requests.timer().tick("reject", 0, {}) catch unreachable;
}
