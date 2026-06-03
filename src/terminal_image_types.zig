/// Opaque terminal image handle returned by the Chasen runtime.
///
/// Applications may store this in their model, but should not infer backend
/// state from the fields. `generation` lets the runtime reject stale handles
/// after unload/replacement.
pub const TerminalImageHandle = struct {
    id: u32,
    generation: u32,
};

/// Image scaling policy for terminal image placement.
pub const TerminalImageFit = enum {
    none,
    fill,
    fit,
    contain,
};

pub const TerminalImageHorizontalAlign = enum {
    left,
    center,
    right,
};

pub const TerminalImageVerticalAlign = enum {
    top,
    middle,
    bottom,
};

/// Terminal image placement options.
pub const TerminalImageOptions = struct {
    fit: TerminalImageFit = .none,
    horizontal_align: TerminalImageHorizontalAlign = .left,
    vertical_align: TerminalImageVerticalAlign = .top,
    z_index: ?i32 = null,
};

pub const DrawError = error{
    TerminalImageRegistryUnavailable,
    InvalidTerminalImageHandle,
};

/// Result reason delivered when a terminal image load effect fails.
///
/// The runtime keeps the first API intentionally small. Detailed backend
/// diagnostics can be added later without exposing backend error sets through
/// app messages.
pub const LoadError = enum {
    unsupported,
    load_failed,
    registry_full,
};

pub const PathLoadError = error{
    Unsupported,
    LoadFailed,
};
