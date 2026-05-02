const std = @import("std");

pub const style = @import("style.zig");
pub const TextStyle = style.TextStyle;
pub const Color = style.Color;

test {
    std.testing.refAllDecls(@This());
}
