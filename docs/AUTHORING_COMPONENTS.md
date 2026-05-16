# Authoring Components

This document describes the current component authoring contract for Chasen
packages such as [`chasen-ui`](https://github.com/hiroaqii/chasen-ui),
`chasen-anim`, `chasen-media`, and third-party component libraries.

Chasen intentionally keeps the core small. A component is not a framework-owned
object and does not need to implement a trait. Prefer plain Zig structs and
functions that are easy for applications to compose.

## Core Contract

A Chasen application owns semantic state in its model and routes all state
changes through `Msg` and `update`.

```zig
const Self = @This();

pub const Msg = union(enum) {
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
            ctx.requestFrame();
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

- `State`: visual retained state owned by `StateStore`
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
        _ = surface.textAt(0, 0, opts.value, .{});
        if (opts.focused) surface.showCursor(0, 0);
    }
};
```

The application decides how `Action` maps to its own `Msg`. This keeps app
message types fully under application control.

## StateStore

Use `chasen.StateStore` for visual state that belongs to a reusable component
but is not part of the application's semantic model. Examples include scroll
offset, viewport cache, animation phase, selection anchor, or cursor viewport
position.

Do not use `StateStore` for data that should be saved, restored, deep-linked,
or sent to business logic. Text input values, selected board game ids, filters,
and loaded records should live in the app model.

```zig
const ListVisualState = struct {
    scroll_row: u16 = 0,

    fn init(_: chasen.StateInitContext) !@This() {
        return .{};
    }
};

fn listState(
    store: *chasen.StateStore,
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

Call `remove(id)` when a dynamic item disappears. Call
`clearNamespace(prefix)` when leaving a screen:

```zig
store.clearNamespace("bgg/search/");
```

If a stored state owns long-lived resources, define `deinit`:

```zig
const TerminalState = struct {
    child_pid: u32,

    fn init(ctx: chasen.StateInitContext) !@This() {
        _ = ctx.io orelse @panic("TerminalState requires runtime io");
        return .{ .child_pid = 0 };
    }

    fn deinit(self: *@This(), ctx: chasen.StateDeinitContext) void {
        _ = self;
        _ = ctx;
        // Stop child process, close PTY, cancel runtime resources, etc.
    }
};
```

`StateInitContext.allocator` is the store allocator and is valid until the state
is removed or the store is deinitialized. `StateInitContext.io` and
`StateDeinitContext.io` are optional so the store can be used in tests without a
runtime `std.Io`.

## Surface

`chasen.Surface` is the low-level drawing substrate. Component packages should
prefer this API over libvaxis types so Chasen can keep a stable boundary.

Important APIs:

```zig
surface.size();
surface.frameAllocator();
surface.writeCell(col, row, cell);
surface.readCell(col, row);
surface.textAt(col, row, text, style);
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

Use `child(rect)` for clipping and nested layout. `fill`, `clear`, and `scroll`
operate within the given rectangle and are safe for component-local drawing.

`textAt` and `Column.text` are borrowed text APIs. They do not copy the string;
the bytes must stay valid until the current frame finishes rendering. Static
strings, app-owned model text, and component-owned buffers are safe. Stack
buffers created during `view` are not safe:

```zig
var buf: [32]u8 = undefined;
const text = std.fmt.bufPrint(&buf, "count: {d}", .{count}) catch "";
_ = surface.textAt(0, 0, text, .{}); // invalid: text dies before render
```

Use `printAt` for formatted text and `copyText` / `copyTextAt` for dynamic text
that must be made frame-owned:

```zig
try surface.printAt(0, 0, .{}, "count: {d}", .{count});

const title = try surface.copyText(dynamic_title);
panel.view(surface, .{ .title = title });
```

`frameAllocator()` is reset after the current frame. Use it only for temporary
formatting or layout buffers during `view`. Never store memory from the frame
allocator in `Model`, `Msg`, or `StateStore`.

## Animation

Animation and media packages should drive rendering with `ctx.requestFrame()`.
This requests one future `Event.frame`. Re-request from `update` while the
animation is still active.

```zig
pub const Msg = union(enum) {
    start,
    frame: chasen.Frame,
};

pub fn update(self: *Self, msg: Msg, ctx: *chasen.Ctx(Msg)) !void {
    switch (msg) {
        .start => {
            self.running = true;
            ctx.requestFrame();
        },
        .frame => |frame| {
            if (!self.running) return;
            self.t_ns = frame.now_ns;
            ctx.requestFrame();
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

## Msg Ownership

`Msg` values cross the runtime boundary by value. Be explicit about ownership.

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
    got_search: SearchResult,
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

## Cmd

Applications normally call `Ctx` methods directly from `update`.

`chasen.Cmd(Msg)` exists as an effect descriptor for helpers that need to
compose effects before handing them back to app code. A component package may
return a `Cmd(Msg)` from an update helper, but the application should still
dispatch it from `update`:

```zig
const command = widget.update(action);
try ctx.dispatch(command);
```

Do not execute I/O from `view`.

## Checklist

Before publishing a component package, verify:

- Semantic state remains in the app model.
- Visual retained state uses `StateStore` with stable ids.
- `view` is draw-only and only uses `Surface`.
- Frame allocator memory is not stored.
- Heap payload ownership is documented.
- Async results include request ids when stale results are possible.
- Long-lived resources have a `deinit` path.
- Animations stop requesting frames when idle.
