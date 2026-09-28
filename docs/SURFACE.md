# Surface Drawing

Chasen views draw directly to a `Surface`.

## Drawing Model

A `Surface` is Chasen's drawing target. It represents a rectangular terminal
cell area where `view` writes text, styles, cursor changes, and terminal image
placements.

The root `Surface` covers the whole terminal screen. A child surface covers a
smaller clipped rectangle inside its parent.

```zig
pub fn view(self: *const App, surface: *chasen.Surface) !void {
    _ = self;
    surface.clearAll();

    // Coordinates are cell-based: (0, 0) is the top-left cell.
    // The first argument is the column, and the second is the row.
    _ = surface.borrowTextAt(0, 0, "Hello", .{ .bold = true });
}
```

## Why Cells Instead of Strings

Chasen does not make `view` return a string. Instead, `view` draws directly to a
`Surface`.

String-returning views are simple and work well for text-only output, but they
make the final screen a flat byte stream. Once styles, clipping, cursor
placement, child regions, terminal images, or future non-terminal backends are
involved, Chasen needs to preserve cell-level structure.

`Surface` keeps drawing cell-based and explicit. The app draws into coordinates,
child surfaces define clipped regions, and the runtime can decide how to present
those cells through the terminal backend.

This also avoids building ANSI strings only to measure, clip, strip, or
reinterpret them later. Chasen keeps `view` as immediate drawing, while higher
level layout and widgets can be built above it when needed.

This gives applications direct access to:

- cell coordinates
- text styles
- child surfaces
- clipping
- cursor placement
- terminal image handles
- frame-scoped text allocation

`chasen.Cell` is a Chasen-owned text/style cell. It does not expose the
underlying terminal backend cell type. `Surface.readCell` is useful for tests
and same-frame read-modify-write effects, but the returned `char.grapheme` is
borrowed from the screen buffer. Copy it before storing it in model or
component state.

`CellChar.width = 0` means "unknown or backend-measured width". It is not a
trailing/continuation marker for wide text. If an app needs wide-text traversal,
it should derive that policy from its own text model, not from width-zero cells.

## Text Lifetimes

Chasen has both borrowed and frame-owned text drawing APIs.

Use `borrowTextAt` only when the text outlives the current render. Good inputs
are string literals, app state owned by the model, and other buffers that remain
valid until rendering finishes:

```zig
_ = surface.borrowTextAt(0, 0, "static label", .{});
```

> [!WARNING]
> Do not pass stack buffers or `std.fmt.bufPrint` results to `borrowTextAt`.
> `borrowTextAt` does not copy the bytes, so this can render corrupted text:
>
> ```text
> var buf: [64]u8 = undefined;
> const label = try std.fmt.bufPrint(&buf, "count: {d}", .{count});
> _ = surface.borrowTextAt(0, 0, label, .{}); // wrong: label points to stack memory
> ```

Use `printAt` for formatted text created during `view`. It formats into
Chasen's frame arena, so the text remains valid until the current render
finishes:

```zig
_ = try surface.printAt(0, 0, .{}, "count: {d}", .{count});
```

Use `copyTextAt` when the text slice is dynamic and should be copied into the
current frame before drawing:

```zig
_ = try surface.copyTextAt(0, 0, dynamic_label, .{});
```

As a rule of thumb: literals and model-owned strings can use `borrowTextAt`;
anything formatted or assembled inside `view` should use `printAt` or
`copyTextAt`.

Frame-owned text is allocated from a frame arena. The arena is reset before each
render and retains capacity so repeated redraws do not churn the allocator.

## Child Surfaces

`Surface.child(Rect)` creates a clipped local drawing area.

```zig
// A Rect describes a rectangular cell area on the parent surface.
// This one starts at column 2, row 3, and is 40 cells wide by 10 cells tall.
const body_rect = chasen.Rect{
    .col = 2,
    .row = 3,
    .width = 40,
    .height = 10,
};

// child() creates a clipped drawing surface for that rectangle.
var body = surface.child(body_rect);

// Coordinates inside the child are local: (0, 0) is the top-left cell of body.
_ = body.borrowTextAt(0, 0, "local coordinates", .{});
```

Child surfaces make it possible to build app-local panels, lists, editors,
overlays, and previews without requiring a framework-owned component tree.

> [!NOTE]
> For larger layouts, use
> [`chasen-ui.layout`](https://github.com/hiroaqii/chasen-ui) helpers to compute
> these `Rect` values. Chasen core keeps layout explicit, but real apps do not
> need to hand-write every rectangle calculation. `chasen-ui.layout` provides
> small allocation-free helpers while the app still owns layout policy and
> passes child surfaces to components.

## Further Reading

See [Authoring Components](AUTHORING_COMPONENTS.md) for cell access, Unicode
width, styles, and testing drawing code with an in-memory surface.
