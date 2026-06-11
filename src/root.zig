const std = @import("std");
const vaxis = @import("vaxis");

pub const runtime = @import("runtime.zig");

pub const style = @import("style.zig");
pub const TextStyle = style.TextStyle;
pub const Color = style.Color;
pub const Underline = style.Underline;

pub const surface = @import("surface.zig");
pub const Surface = surface.Surface;
pub const Column = surface.Column;
pub const Cell = surface.Cell;
pub const CellChar = surface.CellChar;
pub const CursorShape = surface.CursorShape;
pub const Size = surface.Size;
pub const Rect = surface.Rect;
pub const PrintResult = surface.PrintResult;

pub const terminal_image = @import("terminal_image.zig");
pub const TerminalImageHandle = terminal_image.TerminalImageHandle;
pub const TerminalImageRequestId = terminal_image.TerminalImageRequestId;
pub const TerminalImageFit = terminal_image.TerminalImageFit;
pub const TerminalImageOptions = terminal_image.TerminalImageOptions;
pub const TerminalImageLoadError = terminal_image.LoadError;
pub const TerminalImagePathLoadError = terminal_image.PathLoadError;
pub const TerminalImagePathLoaderFn = terminal_image.PathLoaderFn;
pub const TerminalImageLoaderVaxis = terminal_image.LoaderVaxis;
pub const TerminalImageLoaderImage = terminal_image.LoaderImage;

pub const ctx = runtime.ctx;
pub const Ctx = runtime.Ctx;

pub const testing = @import("testing.zig");

pub const state_store = @import("state_store.zig");
pub const ComponentStateStore = state_store.ComponentStateStore;
pub const ComponentStateInitContext = state_store.ComponentStateInitContext;
pub const ComponentStateDeinitContext = state_store.ComponentStateDeinitContext;

pub const text = @import("text.zig");
pub const key_hint = @import("key_hint.zig");

pub const stats = runtime.stats;
pub const RuntimeEventKind = runtime.RuntimeEventKind;
pub const RuntimeStats = runtime.RuntimeStats;
pub const StatsFn = runtime.StatsFn;

pub const trace = runtime.trace;
pub const TraceEvent = runtime.TraceEvent;
pub const TraceFn = runtime.TraceFn;

pub const runtime_effect = runtime.runtime_effect;
pub const RuntimeEffectKind = runtime.RuntimeEffectKind;
pub const EffectSupport = runtime.EffectSupport;
pub const BrowserInitialEffects = runtime.BrowserInitialEffects;

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

pub const AppDeinitContext = runtime.AppDeinitContext;

pub const RuntimeOptions = runtime.RuntimeOptions;

/// Terminal-backend options for `runWith`.
pub const TerminalOptions = struct {
    env_map: *std.process.Environ.Map,
    /// Optional terminal image path loader.
    ///
    /// Leave null when the app does not load terminal images. Terminal-only
    /// runners can provide an adapter outside core when image decode/transmit
    /// support is needed.
    image_path_loader: ?TerminalImagePathLoaderFn = null,
    /// Optional caller-owned context passed to `image_path_loader`.
    image_loader_context: ?*anyopaque = null,
};

/// Options for the low-level `runWith` entry point.
pub const RunOptions = struct {
    runtime: RuntimeOptions,
    terminal: TerminalOptions,
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
        .runtime = .{
            .allocator = init.gpa,
            .io = init.io,
        },
        .terminal = .{
            .env_map = init.environ_map,
        },
    }, app);
}

/// Run the application with explicit options.
///
/// Use this when you need custom runtime hooks or terminal-backend options.
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
}

test "validateApp accepts apps without handleEvent" {
    const App = struct {
        pub const Msg = enum { noop };

        pub fn update(_: *@This(), _: Msg, _: *Ctx(Msg)) !void {}

        pub fn view(_: *const @This(), _: *Surface) !void {}
    };

    comptime validateApp(App);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("program.zig");
    _ = @import("state_store.zig");
}
