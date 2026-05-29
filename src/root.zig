const std = @import("std");
const vaxis = @import("vaxis");

pub const style = @import("style.zig");
pub const TextStyle = style.TextStyle;
pub const Color = style.Color;
pub const Underline = style.Underline;

pub const surface = @import("surface.zig");
pub const Surface = surface.Surface;
pub const Column = surface.Column;
pub const Cell = surface.Cell;
pub const CursorShape = surface.CursorShape;
pub const Size = surface.Size;
pub const Rect = surface.Rect;
pub const PrintResult = surface.PrintResult;

pub const terminal_image = @import("terminal_image.zig");
pub const TerminalImageHandle = terminal_image.TerminalImageHandle;
pub const TerminalImageFit = terminal_image.TerminalImageFit;
pub const TerminalImageOptions = terminal_image.TerminalImageOptions;
pub const TerminalImageLoadError = terminal_image.LoadError;
pub const TerminalImagePathLoadError = terminal_image.PathLoadError;
pub const TerminalImagePathLoaderFn = terminal_image.PathLoaderFn;
pub const TerminalImageLoaderVaxis = terminal_image.LoaderVaxis;
pub const TerminalImageLoaderImage = terminal_image.LoaderImage;

pub const ctx = @import("ctx.zig");
pub const Ctx = ctx.Ctx;

pub const cmd = @import("cmd.zig");
pub const Cmd = cmd.Cmd;

pub const testing = @import("testing.zig");

pub const state_store = @import("state_store.zig");
pub const StateStore = state_store.StateStore;
pub const StateInitContext = state_store.StateInitContext;
pub const StateDeinitContext = state_store.StateDeinitContext;

pub const text = @import("text.zig");

pub const stats = @import("stats.zig");
pub const RuntimeEventKind = stats.RuntimeEventKind;
pub const RuntimeStats = stats.RuntimeStats;
pub const StatsFn = stats.StatsFn;

pub const trace = @import("trace.zig");
pub const TraceEvent = trace.TraceEvent;
pub const TraceFn = trace.TraceFn;

const program = @import("program.zig");

/// Keyboard input type (re-exported from libvaxis).
pub const Key = vaxis.Key;

/// Frame timing delivered by `Event.frame`.
pub const Frame = struct {
    /// Monotonic timestamp for this frame, in nanoseconds.
    now_ns: u64,
    /// Nanoseconds since the previous frame timestamp.
    delta_ns: u64,
    /// Monotonic frame counter starting at 0.
    index: u64,
};

/// Terminal event type passed to `handleEvent`.
pub const Event = union(enum) {
    key_press: vaxis.Key,
    mouse: vaxis.Mouse,
    winsize: vaxis.Winsize,
    /// Clipboard paste content. Only valid during the current event dispatch.
    paste: []const u8,
    focus_in,
    focus_out,
    /// Requested animation/media frame.
    frame: Frame,
};

/// Cleanup context passed to optional app `deinit`.
///
/// This context is intentionally smaller than `Ctx`: shutdown cleanup cannot
/// queue effects, spawn work, or request frames.
pub const AppDeinitContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
};

/// Options for the low-level `runWith` entry point.
pub const RunOptions = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    env_map: *std.process.Environ.Map,
    /// Optional callback called after each runtime event loop iteration.
    ///
    /// The callback receives lightweight timing information. Chasen does not
    /// store, aggregate, format, or export these stats. When this is `null`,
    /// Chasen skips runtime timing measurements.
    stats_fn: ?StatsFn = null,
    /// Optional caller-owned context passed to `stats_fn`.
    stats_context: ?*anyopaque = null,
    /// Optional callback called at runtime lifecycle boundaries.
    ///
    /// The callback receives event notifications, not timings. Chasen does not
    /// store, aggregate, format, or export trace events.
    trace_fn: ?TraceFn = null,
    /// Optional caller-owned context passed to `trace_fn`.
    trace_context: ?*anyopaque = null,
    /// Optional terminal image path loader.
    ///
    /// Leave null when the app does not load terminal images. Terminal-only
    /// runners can provide an adapter outside core when image decode/transmit
    /// support is needed.
    terminal_image_path_loader: ?TerminalImagePathLoaderFn = null,
    /// Optional caller-owned context passed to `terminal_image_path_loader`.
    terminal_image_loader_context: ?*anyopaque = null,
};

/// Run the application (Juicy Main API).
///
/// Usage:
/// ```
/// pub fn main(init: std.process.Init) !void {
///     try chasen.run(init, Counter{});
/// }
/// ```
pub fn run(init: std.process.Init, app: anytype) !void {
    return runWith(.{
        .allocator = init.gpa,
        .io = init.io,
        .env_map = init.environ_map,
    }, app);
}

/// Run the application with explicit options.
///
/// Use this when you need a custom allocator, Io, or Environ.Map
/// (e.g. tests, custom `Io.Threaded` setup).
pub fn runWith(opts: RunOptions, initial_app: anytype) !void {
    const App = @TypeOf(initial_app);
    comptime validateApp(App);
    try program.run(App, opts, initial_app);
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
    if (!@hasDecl(App, "handleEvent")) {
        @compileError("App must declare `pub fn handleEvent`");
    }
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("program.zig");
    _ = @import("state_store.zig");
}
