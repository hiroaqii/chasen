const std = @import("std");

pub const style = @import("style.zig");
pub const TextStyle = style.TextStyle;
pub const Color = style.Color;

pub const surface = @import("surface.zig");
pub const Surface = surface.Surface;
pub const Column = surface.Column;

pub const ctx = @import("ctx.zig");
pub const Ctx = ctx.Ctx;

/// Run the application.
///
/// `app` must satisfy the App contract:
///   - `pub const Msg: type` — message union
///   - `pub fn update(*Self, Msg, *Ctx(Msg)) void`
///   - `pub fn view(*const Self, *Surface) void`
///   - `pub fn handleKey(Key) ?Msg`
pub fn run(allocator: std.mem.Allocator, io: std.Io, app: anytype) !void {
    const App = @TypeOf(app);
    comptime validateApp(App);
    _ = allocator;
    _ = io;
}

fn validateApp(comptime App: type) void {
    if (!@hasDecl(App, "Msg")) {
        @compileError("App must declare `pub const Msg`");
    }
    if (!@hasDecl(App, "update")) {
        @compileError("App must declare `pub fn update`");
    }
    if (!@hasDecl(App, "view")) {
        @compileError("App must declare `pub fn view`");
    }
    if (!@hasDecl(App, "handleKey")) {
        @compileError("App must declare `pub fn handleKey`");
    }
}

test {
    std.testing.refAllDecls(@This());
}
