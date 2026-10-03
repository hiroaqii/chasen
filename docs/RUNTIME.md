# Runtime and Effects

## Application Lifecycle

Chasen separates input handling, state updates, side effects, and rendering.

Startup is simple from the application side. `init` is optional, and effects
queued during `init` are drained before the first render.

Before the first render, Chasen also delivers the initial terminal size when it
is available, so apps that care about layout can initialize size-dependent state
through the normal event/update path.

The diagram below shows a normal event-loop turn. Nodes starting with `app.`
are implemented by the application author. The other nodes are handled by the
Chasen runtime.

```mermaid
flowchart TD
    Event["Runtime event<br/>key / mouse / paste / resize / focus / frame"]
    RuntimeMsg["Queued task result Msg"]
    TimerNotice["Queued non-owning Timer Notice"]
    Notify["app timer callback(Notice, Outcome, Allocator) ?Msg"]
    Continue["Internal effect-drain continuation"]
    Handle["app.handleEvent?(Event) ?Msg"]
    Update["app.update(Msg, *Ctx)"]
    Effects["Runtime drains pending Requests<br/>and completion messages"]
    NeedRender{"Redraw needed?<br/>Resize always redraws"}
    View["app.view(*Surface)"]
    Render["Terminal render"]
    Skip["No redraw"]

    Event --> Handle
    Handle -->|"Msg"| Update
    Handle -->|"null"| Effects
    RuntimeMsg --> Update
    TimerNotice --> Notify
    Notify -->|"Msg"| Update
    Notify -->|"null"| Effects
    Continue --> Effects
    Update --> Effects
    Effects -->|"completion Msg"| Update
    Effects -->|"drain complete or round limit reached"| NeedRender
    NeedRender -->|"yes"| View
    View --> Render
    NeedRender -->|"no"| Skip

    classDef app fill:#e8f5ff,stroke:#2f80ed,color:#0b2a42;
    classDef runtime fill:#f4f4f5,stroke:#71717a,color:#18181b;
    classDef decision fill:#fff7ed,stroke:#f97316,color:#431407;

    class Handle,Update,View,Notify app;
    class Event,RuntimeMsg,TimerNotice,Continue,Effects,Render,Skip runtime;
    class NeedRender decision;
```

Timer callbacks create Msgs on the runtime thread; task workers return Msgs.
Both reach update without passing through `handleEvent`.
Requested frame events go through `handleEvent`, so an animation app maps
`Event.frame` into its own `Msg` before `update` advances state.

If `handleEvent` returns `null` or is omitted, that event produces no app message.
The runtime still drains pending effects before deciding whether to redraw.
Effect completion messages, such as foreground-command or clipboard results,
go directly to `update` during the drain. Those updates can queue more effects
and request a redraw even when the original event produced no message.

The return edge from `update` resumes effect processing. Follow-up work is
processed in bounded rounds; remaining work continues in a later event-loop
turn. An internal continuation event enters the drain without calling
`handleEvent`.

Redraw is needed if any update in the turn requests it or a terminal resize
occurs. Resize forces a redraw even when `handleEvent` returns `null` or an
update calls `ctx.redraw().skip()`. It still passes through effect drain before
`view` and terminal rendering, so the screen buffer matches the new terminal
size.

Internally, `Events` owns bracketed-paste accumulation and the shared synchronous
`handleEvent`/`update` path. Each message resets redraw suppression before update;
an update error still leaves its message owned by the app. The small `Renderer`
inside Program owns the reusable frame arena and keeps view and terminal paint
timings separate. Program retains event/frame counters, effect-drain boundaries,
forced resize redraws, and the final stats callback for each turn.

## Input and Messages

The internal `TerminalSession` is initialized in its final storage and owns the
TTY buffer, Tty, Vaxis, input loop, terminal modes, resize polling, and suspension
flag. It coordinates reader stop/restart around feature changes and foreground
handoff. Program joins resize polling before the producer shutdown barrier;
reader cancellation needs neither another concurrency slot nor a DSR response.
`TerminalEffects` owns the image registry and processes foreground, clipboard,
and image requests at their existing separate effect stages. App dispatch stays
outside the session, and foreground restore does not emit a new resize event.

`handleEvent` separates raw terminal input from application state transitions.

A terminal key press is not always an application action. The same key event
might become `.quit`, `.move_down`, `.open_picker`, or no message at all,
depending on the current screen and app state. By returning `?Msg`,
`handleEvent` lets the app explicitly decide which events matter.

This keeps `update` focused on domain messages instead of terminal/runtime event
details. Timer notices are converted by their registered callbacks on runtime,
and task results arrive as Msgs. Both skip `handleEvent` and go directly to
`update`. Requested frame events still go
through `handleEvent`, which lets animation apps decide whether a frame matters
for their current state.

For apps that do not need keyboard, mouse, paste, resize, or focus handling,
`handleEvent` can be omitted entirely.

## Effects Through Ctx

The fragments below illustrate independent requests inside `init` or `update`;
callbacks and application-specific values must be supplied by the app.

Chasen does not make `update` return a command value. Instead, `update` receives
`*chasen.Ctx(Msg)` and queues runtime effects explicitly.

Queued effects have [pending request limits](#pending-request-limits). The timer
examples use non-owning Notice values and mandatory callbacks; see
[Timer Notice ownership](RUNTIME_MESSAGE_OWNERSHIP.md#timer-notice-ownership)
before passing references.

```zig
// Stop the runtime after the current update/effect cycle.
ctx.quit();

// Request one future frame event. Animations call this again while they continue.
ctx.frame().request();

// Skip the redraw after this update. Queued effects are still drained.
ctx.redraw().skip();

// Run background work that does not need captured app-owned context.
_ = try ctx.task().spawn(.{
    .run = Task.run,
    .failed = Task.failed,
});

// With no Msg.TimerNotice declaration, use void and a callback.
try ctx.timer().tick("reload", 1_000_000_000, {}, reloadNotice);

// The callback handles both fired and failed outcomes.
try ctx.timer().every("clock", 1_000_000_000, {}, clockNotice);

// Cancel a pending or running timer with this id.
try ctx.timer().cancel("clock");

// Queue a terminal image load. The request id lets the app ignore stale results.
const request_id = try ctx.image().loadPath(path, loaded, failed);

// Release an app-owned terminal image handle when it is no longer displayed.
try ctx.image().unload(handle);

// Send text to the terminal clipboard with a best-effort OSC 52 write.
const clipboard_request_id = try ctx.terminal().copyToClipboard(.{
    .text = text,
    .finished = App.clipboardCopyFinished,
});

// `ClipboardCopyResult.request_id` is the same opaque id. Keep any semantic
// page/surface metadata in app state under this id and take it on completion.
```

`Ctx` borrows an initialized `Requests(Msg)` owner; it holds no pending queues.
Most effects are stored in that owner and drained after `init` or `update` returns.
The runtime supplies its allocator and Io explicitly and keeps it in stable
storage. Apps use the received `*Ctx` only during `init`/`update` on the runtime
thread. Headless tests use an explicitly initialized
[`TestCtx`](RUNTIME_MESSAGE_OWNERSHIP.md#tests-and-migration).
Task cancellation is an immediate notification; it still leaves joining and
result cleanup to the runtime.

`TaskRuntime(Msg)` owns live task nodes, starts workers, reaps completed
supervisors, and handles cancellation and joining. Program binds it to Requests
only in its final storage and unbinds it after joining. Shared terminal event
and completion-buffer types live in `program_types.zig`; backend-independent
frame timing lives in `runtime.zig`. The public root keeps the same event and
option exports.

`TimerRuntime(Msg)` owns typed stable nodes containing copied IDs, Notice,
callback, delay, and Future. The effect
coordinator calls its cancel, tick, and every stages in that order; Program shuts
it down before joining tasks. Same-ID replacement cancels and joins the old Future before
starting the replacement. Tracking capacity is reserved before worker admission.
Workers post copied Notice/callback values, independent of node and ID lifetime,
using the non-owning queue-post helper shared with frames. Completed one-shot
retention is described below.

`ctx.quit()` remains a direct shortcut because it is used by almost every
interactive app. `ctx.allocator()`, `ctx.io()`, and `ctx.now()` are direct
accessors because they are not runtime effects.

`ctx.redraw().skip()` suppresses redraw for the current message only. Its flag
is reset before each `update`; queued effects still drain. Resize redraws even
when the app suppresses redraw.

The internal `Effects(Msg)` owns the runtime-thread completion buffer and the
continuation-wake flag. It borrows the request and live owners during each drain;
Program keeps startup, event turns, rendering, and shutdown order explicit.
Each effect-drain pass processes runtime-thread completions, foreground commands,
clipboard writes, tasks, timer cancels, one-shot timers, repeating timers, images,
and frame requests in that order. Follow-up synchronous effects are processed
in at most eight rounds. Remaining work schedules one coalesced continuation
event. If the queue is full, its existing events already guarantee another turn;
the flag stays clear so a later drain can enqueue a wake.
The eight-round limit bounds repeated passes, not elapsed time: a long-running
callback or foreground command can still delay the event loop.

Each stage detaches its own fixed-capacity value batch immediately before use.
Follow-up requests occupy separate pending storage, so an update cannot overwrite
the batch being processed. On error, the stage releases its unconsumed suffix;
the request owner separately releases new pending work. Detaching adds no heap
allocation and does not change the existing stage order or queue limits.

For task callback signatures, admission-error handling, cancellation, cleanup,
and worker concurrency costs, see [Runtime Message Ownership](RUNTIME_MESSAGE_OWNERSHIP.md).
The [task cancellation example](../examples/task_cancellation/main.zig) shows
owned work, replace/close actions, and generation checks for late results.

## Pending Request Limits

Most effects first enter a fixed-capacity pending queue in `Requests`. Its slots
count requests that the runtime has not yet taken for processing. Each stage of
effect drain detaches its batch and empties that pending queue, making the slots
available for new requests even while the detached work is running.

The current capacities and queue-full errors are:

| Request through `Ctx` | Pending capacity | Queue-full error |
| --- | --- | --- |
| `task().spawn` / `spawnOwned` | 16 shared | `TaskLimitExceeded` |
| `timer().tick` | 8 | `TimerLimitExceeded` |
| `timer().every` | 8 | `TimerLimitExceeded` |
| `timer().cancel` | 8 | `TimerCancelLimitExceeded` |
| `image().loadPath` | 8 | `TerminalImageLoadLimitExceeded` |
| `image().unload` | 8 | `TerminalImageUnloadLimitExceeded` |
| `terminal().runForegroundCommand` | 1 | `ForegroundCommandLimitExceeded` |
| `terminal().copyToClipboard` | 4 | `ClipboardCopyLimitExceeded` |

These are current implementation capacities, not configurable settings or
guarantees that the numbers will remain unchanged. Handle admission errors.
For example, submitting a seventeenth task before the task stage drains the
queue fails; already-running tasks do not occupy those pending slots. Replacing
an entry already pending in the same `tick` or `every` queue reuses its node
and slot without allocation. `every(0)` returns `InvalidInterval` before any
allocation or replacement; `tick(0)` is allowed.
An accepted `cancel` removes matching pending timers and queues cancellation of
running timers; if admission fails, it leaves those timers unchanged.

These limits do not cap the total number of running tasks or timers, the number
of bytes in their payloads, or the runtime's total memory use. Backend concurrency
limits are separate, and starting accepted work can still fail. `frame().request`
coalesces requests; `task().requestCancel` notifies directly instead of using a
queue in this table.

Ownership on admission depends on the API:

- `spawnOwned` transfers its context only on success. On an admission error,
  the caller still owns it and no task callback runs. After success, Chasen owns
  cleanup, including when the task never starts. See the
  [owned-task example](RUNTIME_MESSAGE_OWNERSHIP.md#queueing-an-owned-task).
- Timer calls allocate a typed node with copied ID, and copy the non-owning
  Notice. Referents remain caller-owned; use explicit Borrowed as described in
  [Timer Notice ownership](RUNTIME_MESSAGE_OWNERSHIP.md#timer-notice-ownership).
- Image path loads, clipboard writes, and foreground commands own copies of their
  queued inputs after admission. The caller retains the original inputs. A
  foreground `.dir` cwd duplicates the descriptor; the caller retains the
  original. Failed admission releases any partially acquired internal copies.
- A rejected `image().unload` has not scheduled release of that handle. The app
  must still arrange its release, for example by queueing it in a later update.

Queue-full errors are only part of each API's error set. Copying inputs can fail
with `OutOfMemory`; task admission can return `TaskIdExhausted`; foreground
requests also validate their inputs. A successful call means admission, not
successful execution or delivery. Timer tracking/worker start failures are
reported to the registered callback; see [Timers and Frames](#timers-and-frames).

## Timers and Frames

`tick(id, delay_ns, notice, notify)` schedules one notification;
`every(id, interval_ns, notice, notify)` repeats until canceled or replaced.
Notice is the dedicated `Msg.TimerNotice` type, or void when omitted. Root Msg
aliases and recursively nested bare pointers/slices are rejected. References
must use genuine `Borrowed(Ref)` wrappers. Simple applications need no Notice
enum or generation:

```zig
fn clockNotice(_: void, outcome: chasen.TimerOutcome, _: std.mem.Allocator) ?Msg {
    return switch (outcome) {
        .fired => .tick,
        .failed => .timer_unavailable,
    };
}
// Inside init/update:
try ctx.timer().every("clock", std.time.ns_per_s, {}, clockNotice);
```

The mandatory callback receives `.fired` or
`.failed(error.OutOfMemory / error.ConcurrencyUnavailable)` on the runtime
thread. It may return a Msg (including an owned value using its allocator), or
explicitly return null. It must not block or reenter effects/runtime driving.
Failure handlers should release application waiting/running state. An accepted
request that cannot start invokes the failure path exactly once; it cannot also
fire. There is no automatic retry. Cancellation, replacement, quit, and shutdown
do not manufacture start failures.

IDs are copied into the node's allocation; temporary ID strings are allowed.
Replacing an ID still pending in the same queue reuses that node. Running
replacement cancels and joins the old worker before starting the new one.
`every(0)` fails with `InvalidInterval` before allocation or state changes;
`tick(0)` is allowed. Admission errors leave existing pending/running timers
unchanged. A valid replacement whose later start fails does not restore the
old timer. Tracking storage is reserved before worker admission, eliminating
a firing-versus-tracking-failure race.

`cancel(id)` removes matching pending timers and queues cancellation for a
running timer. It can fail with OutOfMemory or TimerCancelLimitExceeded; failure
leaves existing timers intact. In one update, `cancel(id); tick(id, ...)` keeps
the new tick: stages process cancel, then tick, then every. If both timer kinds
use the same ID, every is processed last. A notice already posted is not
retracted; carry application generations/identity in Notice when staleness
matters. See the [tick example](../examples/tick/main.zig).

Repeating timers use fixed delay: wait, post Notice, then wait again. They do
not compensate for update/render time and skip firing during foreground
suspension. Queue delivery uses cancellable retries without making the runtime
thread post to its own full queue. Runtime converts a fired Notice immediately
before update; failure Msgs use the completion buffer. Shutdown drops queued
notices without invoking callbacks. See
[Timer Notice ownership](RUNTIME_MESSAGE_OWNERSHIP.md#timer-notice-ownership)
for Borrowed lifetime and generated Msg cleanup.

One allocation stores each pending/running node and its ID; no Notice payload
box or fixed inline-size limit is used. A large common Notice increases every
node/notification's size, and callback-created owned Msgs can allocate. This
contract does not promise lower total allocation bytes or RSS.

Completed one-shot nodes currently retain their copied ID and Future until
replacement, explicit cancellation, or shutdown. Long-lived apps should reuse
a bounded set of IDs or explicitly cancel completed timers, handling admission
errors. The pending queue limit does not bound these retained nodes.

`ctx.frame().request` requests one future frame event paced from the last
delivered frame, and is coalesced while a frame is already in flight. Animation
code should use `Frame.delta_ns` or `Frame.now_ns` for time-based movement
instead of assuming an exact frame rate. If an app has been idle without
frames, or if a foreground command interrupts a scheduled frame, the next
delivered frame can include a large elapsed delta.

Internally, `FrameRuntime` owns the single frame future and the delivered
timestamp/index. Receiving a frame joins its producer before advancing that
timeline. A frame canceled during foreground suspension is joined and requested
again without advancing either value. Requests coalesce while a frame is in
flight; start failure consumes the request, and shutdown cancels the producer.

## Clipboard

Terminal clipboard writes use OSC 52 and are best-effort. A `.sent` result means
Chasen emitted the clipboard sequence to the tty; it does not prove that the
terminal or tmux accepted the payload. Detectable local write failures are
reported through the `finished` callback. `copyToClipboard` returns a
`ClipboardCopyRequestId`, and the callback receives the same id in
`ClipboardCopyResult`. Chasen owns the physical write only; apps should correlate
that id with request-time page or operation-surface metadata when completion
presentation depends on semantic origin.

## Foreground Commands

Use `ctx.terminal().runForegroundCommand` to run an interactive external command
with terminal ownership temporarily handed off from the TUI. This fragment
belongs in `update`; the callback maps completion into an application message:

```zig
_ = try ctx.terminal().runForegroundCommand(.{
    .argv = &.{ "vi", "notes.txt" },
    .finished = App.commandFinished,
});
```

```zig
fn commandFinished(result: chasen.ForegroundCommandResult) Msg {
    return .{ .command_finished = result };
}
```

Declare `command_finished: chasen.ForegroundCommandResult` in `Msg` and handle
its outcome in `update`. Completion includes the request id and an exit code,
signal, stopped-job result, runtime failure, or abandonment. Normal app-message
delivery is deferred until TUI resume. A stopped job is terminated and reaped;
this API does not keep resumable shell jobs. Cleanup or terminal-restoration
failures are fatal to the runtime; their callback messages are disposed as
undelivered rather than passed to `update`.

Commands execute the supplied argv directly, without shell parsing. Foreground
execution is implemented for Linux and macOS; Windows reports an unsupported
completion. See the [foreground command example](../examples/foreground_command/main.zig).

Arguments are copied while queueing. The default cwd and environment are inherited
at spawn time. A `.cwd = .{ .path = path }` copies the path but resolves it at
spawn time; `.cwd = .{ .dir = dir }` duplicates an open directory descriptor and
preserves directory identity across renames. The caller retains its original
handle. `.environment = .{ .replace = &map }` copies the map, including an empty
replacement. A bare executable name uses the parent's PATH even with a replacement
environment; use an absolute executable path when that distinction matters.

## Terminal Images and Options

`ctx.image().loadPath` needs a loader configured through
`chasen.runWith`'s `terminal.image_path_loader` field. The default is null, so
`chasen.run` reports `.unsupported` for path loads. Chasen provides image handles
and placement; an external adapter supplies decoding and transmission.

In an app with a loader matching `chasen.TerminalImagePathLoaderFn`:

```zig
try chasen.runWith(.{
    .runtime = .{ .allocator = init.gpa, .io = init.io },
    .terminal = .{
        .env_map = init.environ_map,
        .image_path_loader = image_loader,
    },
}, App{});
```

The optional `image_loader_context` is caller-owned. Image load callbacks receive
a request id for stale-result checks. Delivered image handles are app-managed:
queue `ctx.image().unload(handle)` when no longer needed, including stale loads.
During shutdown the runtime releases remaining registry handles; see
[message ownership](RUNTIME_MESSAGE_OWNERSHIP.md#runtime-thread-callbacks).

Other `runWith` options include opt-in mouse reporting (`terminal.mouse`),
cell-based mouse coordinates by default, and opt-in Kitty keyboard support
(`terminal.keyboard_protocol = .kitty`). The default keyboard protocol is
`.legacy`. Runtime options expose optional stats and trace callbacks; see the
[runtime_stats](../examples/runtime_stats/main.zig) and
[runtime_trace](../examples/runtime_trace/main.zig) examples.

## Browser / Wasm Boundary

The package exports `chasen_runtime` separately from the terminal `chasen` module.
It exposes backend-independent Ctx, ownership, stats, trace, and effect-policy
types. `zig build check-runtime-wasm` compiles a small usage check for
`wasm32-freestanding`; it does not validate a browser renderer or every API.

Apps can share model/update logic, but need their own browser view and runner.
`BrowserInitialEffects` describes an experimental subset: message dispatch,
timers, frames, redraw suppression, and quit. Tasks and terminal-specific effects
are outside that subset. Chasen does not ship a browser implementation of
terminal `Surface`.
