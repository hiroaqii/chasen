const std = @import("std");

fn delayedAdd(io: std.Io, lhs: u32, rhs: u32) !u32 {
    try io.sleep(.fromMilliseconds(10), .awake);
    return lhs + rhs;
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    const io = threaded.io();
    var future = io.async(delayedAdd, .{ io, 20, 22 });

    const result = future.await(io);
    const value = try result;

    std.debug.print("Io.Threaded async result: {d}\n", .{value});
}
