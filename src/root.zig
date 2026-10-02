const std = @import("std");
const vaxis = @import("vaxis");
const program_types = @import("program_types.zig");

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

pub const foreground_command = @import("foreground_command.zig");
pub const ForegroundCommandCwd = foreground_command.ForegroundCommandCwd;
pub const ForegroundCommandEnvironment = foreground_command.ForegroundCommandEnvironment;
pub const ForegroundCommandQueueError = foreground_command.ForegroundCommandQueueError;
pub const ForegroundCommandRequestId = foreground_command.ForegroundCommandRequestId;
pub const ForegroundCommandFailure = foreground_command.ForegroundCommandFailure;
pub const ForegroundCommandOutcome = foreground_command.ForegroundCommandOutcome;
pub const ForegroundCommandResult = foreground_command.ForegroundCommandResult;
pub const clipboard = @import("clipboard.zig");
pub const ClipboardCopyRequestId = clipboard.ClipboardCopyRequestId;
pub const ClipboardCopyOutcome = clipboard.ClipboardCopyOutcome;
pub const ClipboardCopyResult = clipboard.ClipboardCopyResult;

pub const ctx = runtime.ctx;
pub const Ctx = runtime.Ctx;
pub const TaskStartError = runtime.TaskStartError;
pub const TaskId = runtime.TaskId;
pub const UndeliveredPolicy = runtime.UndeliveredPolicy;

pub const testing = @import("testing.zig");

pub const state_store = @import("state_store.zig");
pub const ComponentStateStore = state_store.ComponentStateStore;
pub const ComponentStateInitContext = state_store.ComponentStateInitContext;
pub const ComponentStateDeinitContext = state_store.ComponentStateDeinitContext;

pub const text = @import("text.zig");

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
pub const Frame = runtime.Frame;

/// Terminal event type passed to `handleEvent`.
pub const Event = program_types.Event;

pub const AppDeinitContext = runtime.AppDeinitContext;

pub const RuntimeOptions = runtime.RuntimeOptions;

pub const KeyboardProtocol = program_types.KeyboardProtocol;
pub const MouseCoordinateProtocol = program_types.MouseCoordinateProtocol;
pub const TerminalOptions = program_types.TerminalOptions;
pub const RunOptions = program_types.RunOptions;

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
    runtime.validateUndeliveredPolicy(App.Msg);
}

test "validateApp accepts apps without handleEvent" {
    const App = struct {
        pub const Msg = enum {
            noop,

            pub const undelivered_policy = .plain;
        };

        pub fn update(_: *@This(), _: Msg, _: *Ctx(Msg)) !void {}

        pub fn view(_: *const @This(), _: *Surface) !void {}
    };

    comptime validateApp(App);
}

test "TerminalOptions mouse coordinate protocol defaults to portable cell sgr" {
    const opts: TerminalOptions = .{
        .env_map = undefined,
    };

    try std.testing.expectEqual(false, opts.mouse);
    try std.testing.expectEqual(MouseCoordinateProtocol.cell_sgr, opts.mouse_coordinate_protocol);
    try std.testing.expectEqual(KeyboardProtocol.legacy, opts.keyboard_protocol);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("program.zig");
    _ = @import("program_types.zig");
    _ = @import("program/tasks.zig");
    _ = @import("requests.zig");
    _ = @import("state_store.zig");
}
