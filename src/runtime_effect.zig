const std = @import("std");

/// Runtime effect categories that a backend runner may need to interpret.
///
/// This is intentionally about runtime capabilities, not UI rendering. Browser
/// support can share update/Ctx behavior without sharing terminal `Surface`.
pub const RuntimeEffectKind = enum {
    dispatch,
    tick,
    every,
    cancel_timer,
    request_frame,
    suppress_redraw,
    quit,
    spawn,
    spawn_with,
    terminal_image_load_path,
    terminal_image_unload,
};

pub const EffectSupport = enum {
    supported,
    unsupported,

    pub fn isSupported(self: EffectSupport) bool {
        return self == .supported;
    }
};

/// Initial effect support policy for browser runtime validation.
///
/// This is not a full browser runner contract. It records the small subset that
/// is expected to work in the first browser update-sharing POC.
pub const BrowserInitialEffects = struct {
    pub fn support(kind: RuntimeEffectKind) EffectSupport {
        return switch (kind) {
            .dispatch,
            .tick,
            .every,
            .cancel_timer,
            .request_frame,
            .suppress_redraw,
            .quit,
            => .supported,

            .spawn,
            .spawn_with,
            .terminal_image_load_path,
            .terminal_image_unload,
            => .unsupported,
        };
    }

    pub fn isSupported(kind: RuntimeEffectKind) bool {
        return support(kind).isSupported();
    }
};

test "browser initial effects support update-sharing subset" {
    try std.testing.expect(BrowserInitialEffects.isSupported(.dispatch));
    try std.testing.expect(BrowserInitialEffects.isSupported(.tick));
    try std.testing.expect(BrowserInitialEffects.isSupported(.every));
    try std.testing.expect(BrowserInitialEffects.isSupported(.cancel_timer));
    try std.testing.expect(BrowserInitialEffects.isSupported(.request_frame));
    try std.testing.expect(BrowserInitialEffects.isSupported(.suppress_redraw));
    try std.testing.expect(BrowserInitialEffects.isSupported(.quit));
}

test "browser initial effects reject deferred effects" {
    try std.testing.expect(!BrowserInitialEffects.isSupported(.spawn));
    try std.testing.expect(!BrowserInitialEffects.isSupported(.spawn_with));
    try std.testing.expect(!BrowserInitialEffects.isSupported(.terminal_image_load_path));
    try std.testing.expect(!BrowserInitialEffects.isSupported(.terminal_image_unload));
}
