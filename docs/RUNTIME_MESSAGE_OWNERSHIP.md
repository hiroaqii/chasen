# Runtime Message Ownership

Chasen transports an application's root `Msg` by value. Most messages reach
`App.update`, but shutdown and runtime error unwind create paths where delivery
is no longer possible. This document defines who owns a message on each path
and how an application makes cleanup explicit.

## Required root Msg policy

Every `App.Msg` used with `chasen.run` or `chasen.runWith` must declare one of
these policies:

```zig
pub const undelivered_policy = .plain;
```

The type annotation is normally unnecessary; use
`chasen.UndeliveredPolicy` when an explicit public type is useful.

Choose `.plain` when every message that can cross an asynchronous runtime
boundary is safe to discard by value. Small enums, fixed-size values, request
ids, and runtime-owned terminal image handles are typical examples.

Choose `.deinit` when a task, task failure callback, or another runtime effect
can produce a message that owns heap storage:

```zig
pub const Msg = union(enum) {
    pub const undelivered_policy = .deinit;

    loaded: []u8,
    refresh,
    quit,

    pub fn deinitUndelivered(self: *Msg, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .loaded => |bytes| allocator.free(bytes),
            .refresh, .quit => {},
        }
        self.* = undefined;
    }
};
```

The hook must have the exact signature
`fn (*Msg, std.mem.Allocator) void`. Chasen validates the declaration at
compile time. Declaring the policy explicitly is intentional: adding the first
owned variant to a formerly plain message type should require an ownership
decision in the same change.

The runnable [`owned_task_result`](../examples/owned_task_result/main.zig)
example shows both sides of the transfer: `update` adopts a delivered buffer,
while `deinitUndelivered` releases the same variant if shutdown prevents
delivery. The task propagates cancellation without constructing a failure Msg.

## Ownership states

| State | Owner | Next step |
|---|---|---|
| A task or callback is constructing `Msg` | Producer | Move it to the event queue, a runtime-thread completion buffer, or a task future outcome |
| `Msg` is in the event queue | Chasen runtime | Deliver it to `App.update` or call `deinitUndelivered` during shutdown drain |
| `Msg` is passed to `App.update` | Application | Consume, move, or deinitialize the payload, including when `update` returns an error |
| A worker cannot post because shutdown began | Task future outcome | Runtime thread awaits the future and calls `deinitUndelivered` |
| A runtime-thread callback cannot be delivered | Runtime completion buffer | Deliver in the next bounded effect-drain round or call `deinitUndelivered` during unwind |

There is no path where both the event queue and a task future own the same
message. A worker retries non-blocking queue transfer while the runtime is
active. Successful transfer returns `.posted`; shutdown or transfer failure
returns `.undelivered(Msg)` to the future. Only the owner selected by that
outcome performs the final action.

## Shutdown sequence

Normal event dispatch stops after the app requests quit, but producers may
still be active. The terminal runner therefore performs an ownership barrier
before `App.deinit`:

1. Raise the shutdown flag, prevent new starts, notify every started task of
   cancellation before the first join, and discard pending task contexts.
2. Cancel the existing tty reader without allocating a helper and drain events.
3. Cancel frame and timer futures.
4. Await task supervisors, each the sole owner of its worker Future; deinitialize
   undelivered results on runtime, after worker-side context cleanup completes.
5. Drain already-posted messages and unapplied runtime-thread completions.
6. Clean remaining foreground/clipboard effects and run `App.deinit`, followed
   by terminal and image-registry cleanup.

OSC 52 clipboard responses are a separate terminal-internal ownership case.
Chasen exposes clipboard writes, not clipboard-read requests, and deliberately
omits libvaxis' allocator-owning `.paste` field from its internal event union.
libvaxis therefore frees an unsolicited OSC 52 response synchronously instead
of attempting to transfer it through the bounded event queue. Ordinary user
paste still reaches `Event.paste`: Chasen assembles it from bracketed-paste
markers and owns the temporary buffer for that one dispatch. Chasen pins a
libvaxis revision whose parser also frees the decode buffer when malformed
base64 fails before an event can be constructed.

Clipboard writes have a separate correlation contract. `copyToClipboard`
returns an opaque `ClipboardCopyRequestId`, and its completion repeats that id.
The runtime copies and owns queued text until the OSC 52 write is drained, but it
does not own application page/surface metadata. Apps retain that semantic
metadata under the request id and consume it on matching completion; unknown or
superseded ids can therefore be discarded without reconstructing origin in a
static callback.

## Task context and cancellation

`spawn` needs only run/failed callbacks; `spawnOwned(context, options)` adds a
typed context and one cleanup callback. Both return a `TaskId`, scoped to one
Ctx/run and never reused there. Ignore it when individual cancellation is not
needed. `requestCancel(id)` may only be called from init/update on the owning
runtime thread. It marks pending work or notifies the live task, without join
or allocation; repeated requests and completed/absent IDs are harmless.

| Terminal | Context owner/action | Message |
| --- | --- | --- |
| Admission error (limit or ID exhaustion) | Caller retains context; no callback | None |
| Accepted but not started: cancel, quit, unwind, test discard | Runtime/test caller invokes cleanup once | None; no failed callback |
| Tracking/supervisor/worker admission failure | Runtime invokes failed, then cleanup once | Existing runtime completion buffer or undelivered cleanup |
| Started run returns Msg or Canceled | Worker invokes cleanup once after run | Msg moves to queue/outcome; Canceled makes no Msg |
| Undelivered result | Context already consumed | Runtime invokes root Msg destructor once |

Owned signatures are `run(*T, Allocator, Io) Io.Cancelable!Msg`,
`failed(*T, TaskStartError, Allocator) Msg`, and `cleanup(*T, Allocator) void`.
Plain signatures omit *T (and failed omits Allocator). `TaskStartError` is
`error{OutOfMemory, ConcurrencyUnavailable}`. Data/work errors belong in Msg;
propagate `error.Canceled` from cooperative Io operations without failure Msg.

Do not free context in run/failed. Move owned fields into a result and clear
the source before the shared cleanup sees it. Borrowed fields remain the
application's lifetime responsibility; a typed pointer is not a lifetime proof.
Cleanup must not enqueue effects or wait for work; normal run cleanup remains
on the worker, failed/pending cleanup on runtime. Msg cleanup stays on runtime.

Cancellation does not revoke a produced/queued Msg, force arbitrary code to
stop, undo effects, guarantee an exit deadline, or determine staleness. Keep
application generations/identity checks. Cancellation during full-queue result
transfer returns the owned Msg for runtime destruction. Non-cooperative tasks
can still delay shutdown.

A supervisor waits for publication of its optional worker Future, then for
completion or a cancellation request, and alone awaits/cancels that Future.
Runtime reaps only completed supervisors during ordinary effect drain; a last
completion may wait for the next event or shutdown. Each started task costs two
Io concurrency units. Threaded retains its peak thread pool until backend deinit;
reclaimed task nodes do not imply reclaimed threads. This cost applies to plain
tasks too, without requiring extra caller bookkeeping.

## Tests and migration

Use `chasen.testing.discardPendingTasks(Msg, &ctx)` or `TestCtx.resetTransient()`
to abandon pending tasks with the same production cleanup. Neither runs a task
nor makes a synthetic Msg; resetting preserves the next task identity.
Low-level tests taking `ctx.takePendingTasks()` consume every returned entry
exactly once through `run(Allocator, Io)`, `failed(TaskStartError, Allocator)`
(for an uncanceled unstarted entry), or `discard(Allocator)`.
The raw typed context/callback representation and its decoder are private.
Internal byte storage is not a supported accessor: modifying/reinterpreting it,
forging entries, or copying and consuming an entry twice is outside the contract.
This boundary does not provide linear ownership or make bytes inaccessible.

Replace the old untyped context submission with spawnOwned and typed callbacks;
move repeated run/failed destruction into cleanup. Preserve admission-error
cleanup in the caller. Replace old task failure unions with TaskStartError and
remove abandonment-only message branches. Do not remove unrelated foreground
command terminals with similar names. The replaced task API is removed without
a compatibility period. See README for a complete admission-error example.

## Runtime-thread callbacks

Task start failures and terminal image load callbacks are produced on the
runtime thread. They must not be posted back into the same bounded queue that
the runtime thread consumes: a full queue would self-deadlock. Chasen stores
them in a preallocated bounded completion buffer and applies them at the start
of the next effect-drain round. A continuation event schedules another main
loop turn when the bounded synchronous drain limit is reached.

Terminal image callback messages carry registry handles, not independent image
allocations. `deinitUndelivered` must not unload such a handle during shutdown;
the runtime image registry releases all remaining handles after app cleanup.

## Timer restriction

`ctx.timer().tick` and `ctx.timer().every` accept message templates. The runtime
may copy, replace, repeat, cancel, or drop those templates without invoking
`deinitUndelivered`. Only pass non-owning/copy-safe variants to timer APIs.

An app may still use `.deinit` for its root `Msg` when task results own memory;
the particular variants used as timer templates must be plain values.

## Review checklist

When adding a new asynchronously produced message variant:

1. Identify whether its payload owns memory or merely borrows/references
   runtime-owned state.
2. Add the owned case to `deinitUndelivered` before wiring the producer.
3. Keep the normal `update` cleanup path separate; the runtime hook is never
   called after `update` has accepted the message.
4. Verify stale-result branches also release their payloads.
5. Do not use an owning variant as a timer template.
6. Add a test that constructs the owned variant, calls
   `deinitUndelivered`, and passes under `std.testing.allocator`.
