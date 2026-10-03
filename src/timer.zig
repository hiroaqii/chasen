const std = @import("std");

/// An explicitly borrowed reference. This wrapper does not allocate, clone,
/// destroy, extend a lifetime, synchronize access, or make data immutable.
/// Keep the referent valid while a pending/running timer, queued notice, or
/// callback-created message can still use it. Cancellation cannot retract a
/// notice that has already been queued.
pub fn Borrowed(comptime Ref: type) type {
    if (@typeInfo(Ref) != .pointer)
        @compileError("Borrowed requires a pointer or slice type");
    return struct {
        pub const BorrowedRef = Ref;
        value: Ref,

        pub fn init(value: Ref) @This() {
            return .{ .value = value };
        }
    };
}

/// A request was accepted, but the runtime could not start/track its worker.
pub const TimerStartError = error{ OutOfMemory, ConcurrencyUnavailable };

/// Delivered to a timer callback on the runtime thread.
pub const TimerOutcome = union(enum) {
    fired,
    failed: TimerStartError,
};

/// Internal typed callback/transport vocabulary. Only the runtime invokes it.
pub fn Notify(comptime Msg: type) type {
    return *const fn (Notice(Msg), TimerOutcome, std.mem.Allocator) ?Msg;
}

/// Independent non-owning value: never borrows a timer node or its ID storage.
pub fn Notification(comptime Msg: type) type {
    return struct {
        notice: Notice(Msg),
        notify: Notify(Msg),

        pub fn message(self: @This(), outcome: TimerOutcome, allocator: std.mem.Allocator) ?Msg {
            return self.notify(self.notice, outcome, allocator);
        }
    };
}

/// Internal associated-type boundary, shared by requests and runtime storage.
/// A root message may own resources; its timer notice must be a separate,
/// non-owning value type. Applications without a declaration use void notices.
pub fn Notice(comptime Msg: type) type {
    // Composite notices are also validated while instantiating a whole Program.
    // Give recursive validation room without requiring a quota in every caller.
    @setEvalBranchQuota(10_000);
    const has_notice = switch (@typeInfo(Msg)) {
        .@"struct", .@"union", .@"enum", .@"opaque" => @hasDecl(Msg, "TimerNotice"),
        else => false,
    };
    if (!has_notice) return void;
    if (@TypeOf(Msg.TimerNotice) != type)
        @compileError("Msg.TimerNotice must be a type");
    if (Msg.TimerNotice == Msg)
        @compileError("Msg.TimerNotice must be separate from the root Msg type");
    validateValue(Msg.TimerNotice);
    return Msg.TimerNotice;
}

fn isBorrowed(comptime T: type) bool {
    if (@typeInfo(T) != .@"struct") return false;
    if (!@hasDecl(T, "BorrowedRef")) return false;
    if (@TypeOf(T.BorrowedRef) != type) return false;
    if (@typeInfo(T.BorrowedRef) != .pointer) return false;
    // A marker declaration alone must not bypass recursive validation.
    return T == Borrowed(T.BorrowedRef);
}

fn validateValue(comptime T: type) void {
    if (isBorrowed(T)) return;
    switch (@typeInfo(T)) {
        .void, .bool, .int, .float, .@"enum" => {},
        .array => |array| validateValue(array.child),
        .optional => |optional| validateValue(optional.child),
        .@"struct" => |info| for (info.fields) |field| {
            validateValue(field.type);
        },
        .@"union" => |info| {
            if (info.tag_type == null)
                @compileError("TimerNotice must use tagged unions");
            for (info.fields) |field| validateValue(field.type);
        },
        .pointer => @compileError("TimerNotice references require explicit Borrowed"),
        else => @compileError("TimerNotice supports only values and explicit Borrowed references"),
    }
}

test "timer Notice defaults to void and accepts nested values and explicit borrows" {
    const PlainMsg = enum { done };
    try std.testing.expect(Notice(PlainMsg) == void);
    const Msg = union(enum) {
        owned: []u8,

        pub const TimerNotice = union(enum) {
            idle,
            generation: u64,
            nested: struct {
                names: [2]?Borrowed([]const u8),
                mutable: Borrowed(*u64),
                label: [4]u8,
                enabled: bool,
                ratio: f64,
                state: enum { waiting, ready },
            },
        };
    };
    const N = Notice(Msg);
    var generation: u64 = 9;
    const notice: N = .{ .nested = .{
        .names = .{ Borrowed([]const u8).init("text"), null },
        .mutable = Borrowed(*u64).init(&generation),
        .label = "data".*,
        .enabled = true,
        .ratio = 0.5,
        .state = .ready,
    } };
    try std.testing.expectEqualStrings("text", notice.nested.names[0].?.value);
    try std.testing.expectEqual(&generation, notice.nested.mutable.value);
    try std.testing.expect(isBorrowed(Borrowed([]const u8)));
    const Alias = Borrowed([]const u8);
    try std.testing.expect(isBorrowed(Alias));
    // An unrelated value-only type with a similarly named declaration remains
    // an ordinary struct, rather than acquiring wrapper identity.
    const Ordinary = struct {
        pub const BorrowedRef = 1;
        count: u64,
    };
    try std.testing.expect(!isBorrowed(Ordinary));
    comptime validateValue(Ordinary);
}
