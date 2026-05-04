// Investigation: Io.Evented (io_uring) smoke test.
// As of Zig 0.16.0, std.Io.Uring has an error-set mismatch bug
// (ReadOnlyFileSystem not in Dir.OpenError), so this fails to compile.
// Kept as a repro to re-check when Zig updates.
const std = @import("std");

fn delayedAdd(io: std.Io, lhs: u32, rhs: u32) !u32 {
    try io.sleep(.fromMilliseconds(10), .awake);
    return lhs + rhs;
}

pub fn main() !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var evented: std.Io.Evented = undefined;
    try evented.init(gpa, .{});
    defer evented.deinit();

    const io = evented.io();
    var future = io.async(delayedAdd, .{ io, 20, 22 });

    const result = future.await(io);
    const value = try result;

    std.debug.print("Io.Evented async result: {d}\n", .{value});
}
