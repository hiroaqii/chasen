# Authoring Components

This document describes the current component authoring contract for Chasen
packages such as [`chasen-ui`](https://github.com/hiroaqii/chasen-ui),
[`chasen-anim`](https://github.com/hiroaqii/chasen-anim),
[`chasen-graphics`](https://github.com/hiroaqii/chasen-graphics), and
third-party component libraries.

Chasen intentionally keeps the core small. A component is not a framework-owned
object and does not need to implement a trait. Prefer plain Zig structs and
functions that are easy for applications to compose.

Start with the [README](../README.md) for installation and a minimal app.

## Core Contract

A Chasen application owns semantic state in its model and routes all state
changes through `Msg` and `update`.

```zig
const Self = @This();

pub const Msg = union(enum) {
    pub const undelivered_policy = .plain;

    quit,
    toggle,
    frame: chasen.Frame,
};

pub fn update(self: *Self, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
    switch (msg) {
        .quit => ctx.quit(),
        .toggle => self.enabled = !self.enabled,
        .frame => |frame| {
            self.animation_time_ns = frame.now_ns;
            ctx.frame().request();
        },
    }
}

pub fn handleEvent(self: *const Self, event: chasen.Event) ?Msg {
    _ = self;
    return switch (event) {
        .key_press => |key| switch (key.codepoint) {
            'q' => .quit,
            ' ' => .toggle,
            else => null,
        },
        .frame => |frame| .{ .frame = frame },
        else => null,
    };
}

pub fn view(self: *const Self, surface: *chasen.Surface) !void {
    _ = self;
    surface.clearAll();
}
```

`view` draws the current state. It should not mutate application state and
should not return a `Msg`. If user input changes state, map it to `Msg` from
`handleEvent` and handle it in `update`.

## Package Shape

Reusable component packages should expose small, explicit APIs. A typical
component package can define:

- `State`: visual state owned directly by the app/component, or optionally by
  an app-managed `ComponentStateStore`
- `Options`: app-owned semantic inputs and callbacks expressed as values
- `Action`: component-level event result, if useful
- `handleEvent`: pure event-to-action helper
- `update`: optional helper that mutates component visual state
- `view`: draws into a `Surface`

Example shape:

```zig
pub const TextInput = struct {
    pub const State = struct {
        cursor_col: u16 = 0,
        scroll_col: u16 = 0,
    };

    pub const Options = struct {
        id: []const u8,
        value: []const u8,
        focused: bool = false,
    };

    pub const Action = union(enum) {
        insert: u21,
        backspace,
        move_left,
        move_right,
    };

    pub fn handleEvent(opts: Options, event: chasen.Event) ?Action {
        if (!opts.focused) return null;

        return switch (event) {
            .key_press => |key| switch (key.codepoint) {
                8, 127 => .backspace,
                'h' => .move_left,
                'l' => .move_right,
                else => null,
            },
            else => null,
        };
    }

    pub fn view(
        state: *const State,
        opts: Options,
        surface: *chasen.Surface,
    ) !void {
        _ = state;
        _ = try surface.copyTextAt(0, 0, opts.value, .{});
        if (opts.focused) surface.showCursor(0, 0);
    }
};
```

The application decides how `Action` maps to its own `Msg`. This keeps app
message types fully under application control.

## ComponentStateStore

`chasen.ComponentStateStore` is optional. A component can keep visual state in
its own struct, or accept a state pointer owned by the app. No store, string id,
or framework-managed component tree is required for those patterns.

Use a store when looking up visual state by stable id helps the application.
Examples include scroll offset, viewport cache, animation phase, selection
anchor, or cursor viewport position. The app owns the store and decides when
entries and the store itself stop being used.

Do not use `ComponentStateStore` for data that should be saved, restored,
deep-linked, or sent to business logic. Text input values, selected board game
ids, filters, and loaded records should live in the app model.

`ComponentStateStore` is arena-backed. `remove(id)` and
`clearNamespace(prefix)` call stored `deinit` hooks and remove map entries, but
they do not reclaim arena memory. Memory is reclaimed when the whole store is
deinitialized. Avoid using it as a high-churn cache.

Choose storage based on the required lifetime:

| Use case | Ownership pattern |
| --- | --- |
| A fixed set of components | Keep their state in app/component fields; call each owned resource's `deinit` when its owner ends. |
| Visual state belonging to one screen | Let that screen own a store and deinitialize the whole store when the screen is discarded. |
| A long-lived set of stable ids | Reuse existing entries; do not repeatedly remove and recreate them to reclaim memory. |
| Frequent insertion/removal or large, independently released buffers | Use app-owned storage with explicit reclamation; keep only visual metadata or handles in the store. |

For example, state looked up within a store can remain small:

```zig
const ListVisualState = struct {
    scroll_row: u16 = 0,

    fn init(_: chasen.ComponentStateInitContext) !@This() {
        return .{};
    }
};

fn listState(
    store: *chasen.ComponentStateStore,
    id: []const u8,
) !*ListVisualState {
    return store.getOrCreate(id, ListVisualState, ListVisualState.init);
}
```

State ids should include a package/component/path prefix:

```zig
"ui/text_input/search"
"ui/list/search/results"
"anim/transition/main"
"bgg/detail/comments"
```

Within a store that will remain alive, call `remove(id)` when a dynamic item
disappears or `clearNamespace(prefix)` to discard a group of entries:

```zig
store.clearNamespace("bgg/search/");
```

These operations invalidate the removed states even though their arena memory
remains allocated. Recreating the same ids allocates new storage. For repeated
screen creation and destruction, release the whole screen-owned store instead:

```zig
const SearchScreen = struct {
    visual: chasen.ComponentStateStore,

    fn init(allocator: std.mem.Allocator, io: std.Io) SearchScreen {
        return .{ .visual = .initWithIo(allocator, io) };
    }

    fn deinit(self: *SearchScreen) void {
        self.visual.deinit();
    }
};
```

The following fields and methods belong inside the app, alongside its `Msg`,
`update`, and `view`:

```zig
search: ?SearchScreen = null,

fn openSearch(self: *App, ctx: *chasen.Ctx(Msg)) void {
    if (self.search == null) {
        self.search = SearchScreen.init(ctx.allocator(), ctx.io());
    }
}

fn closeSearch(self: *App) void {
    if (self.search) |*screen| {
        screen.deinit();
        self.search = null;
    }
}

pub fn deinit(self: *App, _: chasen.AppDeinitContext) void {
    self.closeSearch();
}
```

Call `closeSearch` when discarding the screen and use `App.deinit` for a screen
still open at app shutdown. Closing releases the arena; reopening creates a new
store. Do not use pointers to old states after removal or store deinitialization.
Before closing, ensure no worker still borrows screen state: requesting cancel
does not wait for that worker to finish. See
[task borrowing and stale results](RUNTIME_MESSAGE_OWNERSHIP.md#borrowed-data-and-stale-results).

If a stored state owns long-lived resources, define `deinit`:

```zig
const TerminalState = struct {
    child_pid: u32,

    fn init(ctx: chasen.ComponentStateInitContext) !@This() {
        _ = ctx.io orelse @panic("TerminalState requires runtime io");
        return .{ .child_pid = 0 };
    }

    fn deinit(self: *@This(), ctx: chasen.ComponentStateDeinitContext) void {
        _ = self;
        _ = ctx;
        // Stop child process, close PTY, cancel runtime resources, etc.
    }
};
```

`ComponentStateInitContext.allocator` is the store allocator and is valid until
the store is deinitialized. `remove` calls the stored value's `deinit`, but the
underlying arena allocation remains owned by the store. `ComponentStateInitContext.io`
and `ComponentStateDeinitContext.io` are optional so the store can be used in
tests without a runtime `std.Io`.

For a buffer that must be freed independently of the store, keep ownership in
the app or explicitly retain its external allocator with the owning state.
The allocator passed to a stored state's hooks is the arena allocator; it must
not be used to free memory allocated by a different allocator.

## Surface

`chasen.Surface` is the low-level drawing substrate. Component packages should
prefer this API over libvaxis types so Chasen can keep a stable boundary.

For introductory drawing examples and text lifetimes, see [Surface Drawing](SURFACE.md).

API sketch (handle errors and return values at the call site):

```zig
surface.size();
surface.frameAllocator();
surface.writeCell(col, row, cell);
surface.readCell(col, row);
surface.borrowTextAt(col, row, text, style);
surface.copyText(text);
surface.copyTextAt(col, row, text, style);
surface.printAt(col, row, style, "value: {d}", .{value});
surface.displayWidth(text);
surface.fill(rect, cell);
surface.clear(rect);
surface.child(rect);
surface.scroll(rect, rows);
surface.showCursor(col, row);
surface.hideCursor();
surface.setCursorShape(shape);
```

`Cell` is a Chasen-owned text/style value, not a libvaxis cell. It represents
the drawing state Chasen APIs create directly: grapheme, display width, and
`TextStyle`. Backend metadata such as terminal-image placement, hyperlinks,
wrapped flags, and Kitty text scaling is intentionally not part of this public
type.

`CellChar.width = 0` means unknown or backend-measured width. It is not a
trailing/continuation-cell marker for the second cell of wide text. Components
that need wide-text traversal should use their own text model or an explicit
helper, not width-zero cells as hidden structural state.

`writeCell` borrows `cell.char.grapheme`; keep the bytes alive until the current
render finishes. `readCell` also returns a borrowed view of the screen buffer.
Use it for same-frame inspection or read-modify-write operations. Do not store
the returned `Cell` in model or component state unless you copy
`cell.char.grapheme` into app-owned memory.

`readCell` -> mutation -> `writeCell` is therefore a text/style roundtrip, not a
lossless backend-cell roundtrip. If a surface contains terminal images and an
app performs full-screen traversal, redraw the images afterward or use a future
image-aware traversal helper.

Use `child(rect)` for clipping and nested layout. A child surface is clipped to
the requested rectangle, clamped to the parent bounds, and shares the same frame
allocator as its parent. Coordinates passed to drawing APIs on a child are local
to that child. For example, `child.copyTextAt(0, 0, ...)` draws at the top-left
of the child rectangle, not the top-left of the root surface.

`borrowTextAt`, `copyTextAt`, and `printAt` draw one unwrapped line and rely on
the current surface for
clipping. On a child surface, long text is clipped by the child width and does
not draw into sibling or parent regions. Use this for component-local viewports
such as panels, table cells, text fields, and scroll windows.

`showCursor` also uses coordinates relative to the surface it is called on.
Calling `child.showCursor(4, 2)` places the terminal cursor inside the child at
local column 4, local row 2. This keeps input components from needing to convert
local cursor positions back to root-surface coordinates.

`fill`, `clear`, and `scroll` operate within the given rectangle and are safe
for component-local drawing.

`borrowTextAt` and `Column.borrowText` are borrowed text APIs. They do not copy
the string; the bytes must stay valid until the current frame finishes
rendering. Static strings, app-owned model text, and component-owned buffers are
safe. Stack buffers created during `view` are not safe:

```zig
var buf: [32]u8 = undefined;
const text = std.fmt.bufPrint(&buf, "count: {d}", .{count}) catch "";
_ = surface.borrowTextAt(0, 0, text, .{}); // invalid: text dies before render
```

Use `printAt` for formatted text and `copyText` / `copyTextAt` for dynamic text
that must be made frame-owned:

```zig
_ = try surface.printAt(0, 0, .{}, "count: {d}", .{count});

const title = try surface.copyText(dynamic_title);
panel.view(surface, .{ .title = title });
```

`frameAllocator()` is reset before each render and retains capacity. Use it only
for temporary formatting or layout buffers during `view`. Never store memory from the frame
allocator in `Model`, `Msg`, or `ComponentStateStore`.

The `surface_basics` example shows these rules in a runnable app:

```sh
zig build run-surface_basics
```

## Text Style

Use `chasen.TextStyle` for public component drawing options instead of exposing
libvaxis style types directly.

The stable style surface currently includes:

- `fg` / `bg`
- `bold` / `italic` / `dim`
- `underline` / `underline_color`
- `reverse`
- `strikethrough`

Example:

```zig
_ = surface.borrowTextAt(0, 0, "warning", .{
    .bold = true,
    .underline = .single,
    .underline_color = .{ .index = 3 },
    .fg = .{ .index = 3 },
});
```

`blink` and `invisible` are intentionally not exposed yet. They are terminal
dependent and have stronger UX implications, so add them only when a real
component or app has a clear need.

## Testing Surface Drawing

Use `chasen.testing.TestSurface` when a component test needs to verify drawing
without starting a terminal runtime.

`TestSurface` is initialized in-place. Declare the fixture first, then call
`init` on that value. This keeps the embedded `Surface` pointing at the backing
screen owned by the same fixture.

```zig
var ts: chasen.testing.TestSurface = undefined;
try ts.init(6, 3);
defer ts.deinit();

myComponent.view(&ts.surface, .{});

try ts.expectCellText(0, 0, "t");
try ts.expectSnapshot("title \nbody  \nfooter");
```

`expectSnapshot` compares a row-major text snapshot. It is intentionally small
and includes padding spaces out to the full surface width. Use
`ts.surface.readCell` or `ts.expectCellText` directly when a test needs to
inspect style, cursor behavior, wide-character layout, or individual cells.
Remember that `readCell` returns borrowed grapheme data; test assertions should
inspect it immediately.

## Animation

Animation and media packages should drive rendering with `ctx.frame().request()`.
This requests one future `Event.frame`. Re-request from `update` while the
animation is still active.

```zig
pub const Msg = union(enum) {
    pub const undelivered_policy = .plain;

    start,
    frame: chasen.Frame,
};

pub fn update(self: *Self, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
    switch (msg) {
        .start => {
            self.running = true;
            ctx.frame().request();
        },
        .frame => |frame| {
            if (!self.running) return;
            self.t_ns = frame.now_ns;
            ctx.frame().request();
        },
    }
}

pub fn handleEvent(self: *const Self, event: chasen.Event) ?Msg {
    _ = self;
    return switch (event) {
        .frame => |frame| .{ .frame = frame },
        else => null,
    };
}
```

Idle apps remain event-driven. Continuous rendering only happens while code
keeps requesting frames.

## Effect Lifecycle

Queue effects from `init` or `update`, and keep `view` draw-only. Most effects
are drained after these callbacks return; `requestCancel` is an immediate,
non-blocking notification on the owning runtime thread.

The runtime delivers the initial terminal size, when available, before the first
render. Terminal events go through optional `handleEvent`; effect-produced app
messages go directly to `update`. `redraw().skip()` is message-scoped, and resize
always redraws. A frame request asks for one event, so animations must request
another while active and use elapsed time rather than assume a fixed cadence.

See [Runtime and Effects](RUNTIME.md) for startup, effect timing, timers,
foreground commands, and terminal options. See
[Runtime Message Ownership](RUNTIME_MESSAGE_OWNERSHIP.md) for task cancellation
and cleanup contracts.

## Msg Ownership

`Msg` values cross the runtime boundary by value. Be explicit about ownership.
Every root message type must declare `undelivered_policy = .plain` or `.deinit`.
Use `.deinit` when an asynchronous result can own memory, and implement the
exact `deinitUndelivered(*Msg, allocator)` hook so shutdown can clean a result
that never reaches `update`.

Rules:

- Small display data can be copied into fixed-size structs.
- Heap data carried by `Msg` must be allocated with an app/runtime allocator.
- `update` owns heap payloads received in `Msg`.
- If `update` moves a payload into `Model`, `Model.deinit` or later state
  replacement must free it.
- If `update` discards a stale async result, it must still deinitialize the
  payload.
- Never put frame-allocator memory into `Msg`.

For small text, prefer a bounded value type:

```zig
const BoundedStr = struct {
    buf: [512]u8 = .{0} ** 512,
    len: usize = 0,

    fn slice(self: *const BoundedStr) []const u8 {
        return self.buf[0..self.len];
    }

    fn from(src: []const u8) BoundedStr {
        var result: BoundedStr = .{};
        const n = @min(src.len, result.buf.len);
        @memcpy(result.buf[0..n], src[0..n]);
        result.len = n;
        return result;
    }
};
```

For large async results, define an owned payload:

```zig
const SearchResult = struct {
    allocator: std.mem.Allocator,
    body: []u8,
    request_id: u64,

    fn deinit(self: *@This()) void {
        self.allocator.free(self.body);
        self.* = undefined;
    }
};

pub const Msg = union(enum) {
    pub const undelivered_policy = .deinit;

    got_search: SearchResult,

    pub fn deinitUndelivered(self: *@This(), _: std.mem.Allocator) void {
        switch (self.*) {
            .got_search => |result| {
                var owned = result;
                owned.deinit();
            },
        }
        self.* = undefined;
    }
};

pub fn update(self: *Self, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
    _ = ctx;
    switch (msg) {
        .got_search => |result| {
            var owned = result;
            if (owned.request_id != self.current_request_id) {
                owned.deinit();
                return;
            }

            if (self.current_result) |*old| old.deinit();
            self.current_result = owned;
        },
    }
}
```

This pattern is important for HTTP, media metadata, BGG XML payloads, terminal
buffers, and other large data.

Once Chasen calls `update`, the app owns the message even if `update` returns an
error. `deinitUndelivered` is only for messages the runtime cannot pass to
`update`; it does not replace normal update-path and model cleanup. See
[`RUNTIME_MESSAGE_OWNERSHIP.md`](RUNTIME_MESSAGE_OWNERSHIP.md) for the complete
queue, future, shutdown, timer, and terminal-image rules.

## Component Effects

Applications call `Ctx` namespace methods directly from `update`.

Component helpers that need to request runtime effects should either:

- return an app-level message that the parent handles in `update`, or
- accept `*chasen.Ctx(Msg)` and queue the effect directly.

Example:

```zig
pub fn updateTransition(self: *TransitionState, ctx: *chasen.Ctx(Msg)) void {
    if (self.running) ctx.frame().request();
}
```

Chasen intentionally does not expose a public `Cmd` effect descriptor as the
primary component boundary. This keeps the framework `Ctx`-first and avoids a
second effect API beside the namespace methods.

Do not execute I/O from `view`.

## Checklist

Before publishing a component package, verify:

- Semantic state remains in the app model.
- Visual state has an explicit app/component owner. If using `ComponentStateStore`,
  ids are stable and the store lifetime matches the intended reclamation point.
- `view` is draw-only and only uses `Surface`.
- Frame allocator memory is not stored.
- Heap payload ownership is documented.
- Async results include request ids when stale results are possible.
- Long-lived resources have a `deinit` path.
- Animations stop requesting frames when idle.
