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

Run it from a repository checkout with `zig build run-owned_task_result`.

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
   undelivered results on runtime, after worker-side context cleanup completes,
   then unbind the task cancellation connection from Requests.
5. Drain already-posted messages, then release unapplied runtime-thread
   completions through their `Effects` owner.
6. Clean remaining foreground/clipboard effects and run `App.deinit`, followed
   by terminal and image-registry cleanup.

`TerminalSession` keeps the TTY, Vaxis, reader, resize thread, and suspension
atomic at stable addresses. Setup errors stop the reader and release only
initialized resources. Program retains the ordering of producer cancellation,
queue drains, App cleanup, image cleanup, and terminal cleanup. Foreground
effects map results into Msgs outside the session; a fatal terminal restore
disposes the callback Msg as undelivered before unwinding the runtime.

OSC 52 clipboard responses are a separate terminal-internal ownership case.
Chasen exposes clipboard writes, not clipboard-read requests, and deliberately
omits libvaxis' allocator-owning `.paste` field from its internal event union.
libvaxis therefore frees an unsolicited OSC 52 response synchronously instead
of attempting to transfer it through the bounded event queue. Ordinary user
paste still reaches `Event.paste`: Chasen assembles it from bracketed-paste
markers and owns the temporary buffer for that one dispatch. Chasen pins a
libvaxis revision whose parser also frees the decode buffer when malformed
base64 fails before an event can be constructed.

The internal `Events` owner retains bracketed-paste bytes until synchronous
`handleEvent` and any resulting `update` return, including errors. An app must
copy text it wants to keep beyond that dispatch. Failed accumulation swallows
the remaining paste keys through the end marker; foreground handoff cancels
an unfinished paste. The shared message-dispatch helper never destroys a Msg
after transferring it to `update`.

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

The internal `TaskRuntime(Msg)` owns the stable nodes and supervisor Futures.
Requests owns only pending entries and the borrowed cancellation connection;
it does not store the live-task registry. Program requests shutdown before any
producer join and keeps this owner in place until joining has removed the
connection.

A supervisor waits for publication of its optional worker Future, then for
completion or a cancellation request, and alone awaits/cancels that Future.
Runtime reaps only completed supervisors during ordinary effect drain; a last
completion may wait for the next event or shutdown. Each started task costs two
Io concurrency units. Threaded retains its peak thread pool until backend deinit;
reclaimed task nodes do not imply reclaimed threads. This cost applies to plain
tasks too, without requiring extra caller bookkeeping.

### Queueing an owned task

Inside `init` or `update`, after creating a typed `task` context and callbacks:

```zig
// Transfer an owned typed context only after successful admission.
const task_id = ctx.task().spawnOwned(task, .{
    .run = Task.run,
    .failed = Task.failed,
    .cleanup = Task.destroy,
}) catch |err| {
    Task.destroy(task, ctx.allocator()); // admission failed: caller still owns it
    return err;
};
// Notify without waiting for the task to finish.
ctx.task().requestCancel(task_id);
```

The caller destroys the context only when admission fails. After successful
admission, the runtime owns cleanup even if cancellation or shutdown follows.

## Tests and migration

Initialize `TestCtx` in its final storage with an allocator and a valid Io:

```zig
var tc: chasen.testing.TestCtx(App.Msg) = undefined;
tc.init(std.testing.allocator, std.testing.io);
defer tc.deinit();
try app.update(msg, &tc.ctx);
```

Do not move the fixture after initialization: its `Ctx` borrows its production
`Requests` owner. Empty literals and private-field injection are no longer
supported. Custom Io and failing allocators are supplied through the same init.

`tickAt`, `everyAt`, `cancelAt`, `foregroundAt`, and `clipboardAt` return optional
read-only observations. Their IDs, text, argv, cwd, and environment are borrowed
until the next owner mutation/reset/deinit; do not free or close them. Views give
no callback or cleanup authority.

`takeTask(index)` removes one task, preserves the order of the rest, and returns
an optional test-owned handle. Keep one owner and `defer task.deinit()` immediately.
`task.run()` or `task.fail(error.OutOfMemory)` consumes it before invoking user
code; a second consumption returns `AlreadyConsumed`. Canceled tasks return
`Canceled` and clean their context without a failed callback. `deinit` discards
only an unconsumed context and is otherwise a no-op. Detached handles survive
fixture reset and use the allocator/Io captured when taken.

`completeForeground(index, outcome)` and `completeClipboard(index, outcome)`
remove the request before making its callback Msg and freeing request resources.
They simulate no terminal execution. A Msg returned by run/fail/complete belongs
to the test: pass it to `App.update` or use `tc.discardMessage(&msg)` with the root
Msg's undelivered policy. Do not discard it again after transfer to update.

`tc.discardPendingTasks()` and `tc.discardPendingEffects()` clean only their
respective task/non-task groups through production ownership code, without
synthetic callback messages. `resetTransient()` cleans both groups and clears
frame/redraw requests, preserving quit and ID sequences. `deinit()` destroys
the owner. Neither owns detached task handles. `fillTaskSlots(count)` submits
real discard-only tasks for admission-limit tests; accepted prefixes remain
owned if the call returns a limit error. Do not run/fail these saturation tasks.

Runtime consumers detach each request kind into an independent fixed-capacity
batch. `next()` transfers one entry to its consumer; batch cleanup handles only
the unconsumed suffix. New pending requests remain separately owned. Timer
notices remain non-owning and are discarded without invoking a callback or Msg destructor.
Batch cleanup does not run tasks or produce result messages, but it does invoke
owned-task cleanup callbacks. Runtime foreground abandonment separately produces
and disposes its required result. The Ctx entry/take/cleanup bridge has been
removed. Arbitrary byte copies cannot enforce linear ownership: forging entries
or consuming copied handles twice remains outside the contract.

Direct `Requests` consumers should replace `removeTaskAt`,
`removeForegroundCommandAt`, and `removeClipboardCopyAt` with the corresponding
`take...At` methods. Each transfers ownership of the returned entry to the caller.
Effect views expose their borrowed owner as `requests` instead of `ctx`;
ordinary calls such as `ctx.task().spawn(...)` are unchanged.

Replace the old untyped context submission with spawnOwned and typed callbacks;
move repeated run/failed destruction into cleanup. Preserve admission-error
cleanup in the caller. Replace old task failure unions with TaskStartError and
remove abandonment-only message branches. Do not remove unrelated foreground
command terminals with similar names. The replaced task API is removed without
a compatibility period. See [Queueing an owned task](#queueing-an-owned-task)
for admission-error handling.

### Runnable owned search

The [task_cancellation example](../examples/task_cancellation/main.zig) combines a
typed owned query, a cancellable standard-Io wait, a result that takes the query
buffer, and generation checks for late messages. Run `zig build run-task_cancellation`.

- Space creates a search; after three seconds its result appears and cleanup has
  consumed the context. The displayed result buffer remains application-owned.
- Space again while waiting requests cancellation and starts a new generation.
  Press p immediately: the independent counter responds without joining either
  task. Only the latest generation can replace the displayed result.
- x closes the search and invalidates its generation. Press p to refresh the
  cleanup count; cancellation itself does not promise an immediate completion
  event or redraw.
- q during the wait returns through Chasen's shutdown barrier. The final terminal
  line reports created/cleaned context counts; they must match. Repeat after a
  normal completion to check application-owned result cleanup.

The example's shared cleanup counter is atomic because normal context cleanup
runs on a worker. Production apps need no such counter to use cancellation.
No network, Git operation, external file or application setting is needed.

### Migration checklist

| Old task usage | Replacement |
| --- | --- |
| `try spawn(...)` returning void | `const id = try spawn(...)`, or `_ = try` if unused |
| `spawnWith` and callback casts | `spawnOwned(context, options)` with typed `*T` callbacks |
| Run/failed each destroy context | One cleanup callback; clear fields moved into Msg |
| `TaskFailure.start_failed` | `TaskStartError` in failed; task work errors stay in Msg |
| Abandonment makes a throwaway failure Msg | Pending discard invokes cleanup only |
| Manual pending cleanup in tests | `tc.discardPendingTasks()` or `tc.resetTransient()` |
| Empty `Ctx`/`TestCtx` literals and raw pending arrays | In-place `tc.init(allocator, io)` and observation methods |
| Raw task entry/take access | `tc.takeTask(index)` and one consuming `TestTask` handle |

A caller cleans up only if admission fails. After successful admission, neither
later update errors nor cancel requests give that ownership back to the caller.
Ordinary applications only need spawn/spawnOwned and, when useful, the returned
TaskId. Runtime ownership entry points live on Requests, not the app facade.

## Runtime-thread callbacks

Task/timer start failures and terminal image load callbacks are produced on the
runtime thread. They must not be posted back into the same bounded queue that
the runtime thread consumes: a full queue would self-deadlock. Chasen stores
them in the `Effects` owner's preallocated bounded completion buffer and applies
them at the start of the next effect-drain round. On update error, the delivered
message stays app-owned and the unapplied suffix is destroyed once. A coalesced
continuation event schedules another main loop turn after eight synchronous
rounds; a full queue already guarantees another turn. Its capacity is derived
from the largest producer set in one pass: 16 tasks + 8 ticks + 8 repeating
timers + 8 image loads = 40 messages. Fired timer notices travel through the
event queue and do not consume this failure buffer.

Terminal image callback messages carry registry handles, not independent image
allocations. `deinitUndelivered` must not unload such a handle during shutdown;
the runtime image registry releases all remaining handles after app cleanup.

## Timer Notice ownership

Timers accept a dedicated non-owning Notice and a mandatory callback, rather
than a root Msg template. Declare `pub const TimerNotice = ...` inside Msg, or
omit it to use `void`. Notice must differ from the root Msg type. Values can be
nested structs, tagged unions, arrays, and optionals; bare pointers/slices are
rejected recursively. Use an explicit `chasen.Borrowed(Ref)` for a reference:

```zig
pub const TimerNotice = struct {
    generation: u64,
    label: chasen.Borrowed([]const u8),
};
// Inside init/update, with a callback supplied by the application:
try ctx.timer().tick("reload", 0, .{
    .generation = generation,
    .label = chasen.Borrowed([]const u8).init("reload"),
}, timerNotice);
```

Borrowed accepts pointer/slice types and provides only `value` and `init`.
It does not allocate, clone, free, extend a lifetime, synchronize access, or
provide a snapshot/deep const. Mutable referents and other aliases require
application synchronization. Use `?Borrowed(*T)` for an optional reference.
The wrapper's exact type is recognized; copying its marker declarations into
another type does not bypass validation. Integer handles can still encode
ownership that the compiler cannot infer; transfer owned work through tasks.

Keep referents alive while pending/running timers, queued notices, **and any
messages constructed from them** can use them. Cancel acceptance, cancel
completion, or freeing a timer node does not revoke notices/messages already
in the queue. IDs control replacement/cancellation; generations and identity
inside Notice control application acceptance of stale results.

The callback signature is
`fn (Notice, chasen.TimerOutcome, std.mem.Allocator) ?Msg`. Both `.fired` and
`.failed(TimerStartError)` run on the runtime thread outside init/update.
Callbacks must finish promptly, avoid blocking I/O/waits and effect/runtime
reentry, and clean up temporary ownership they do not return. A callback may
allocate an owned Msg with the supplied allocator; it handles allocation
failure itself. Returning null is an explicit decision after seeing the
outcome. A callback and its failure handling cannot be omitted.

| Boundary | Ownership/action |
| --- | --- |
| Admission error | No callback; existing pending/running timer unchanged |
| Accepted request | Requests owns one typed node with copied ID and non-owning Notice |
| Same-kind pending replacement | Reuse the node; copy the new Notice/callback/duration |
| Running replacement/cancel | Cancel and join before destroying the old node; no failed callback |
| Tracking/start failure | Runtime invokes callback with registered Notice and failure; destroys node |
| Fired worker event | Queue owns a Notice/callback value, independent of node and ID |
| Normal event dispatch | Runtime invokes callback and passes any Msg directly to update |
| Queue drain on shutdown/unwind | Drop Notice without callback; no owned Msg is constructed |
| Failure Msg in completion buffer | Runtime owns it until update, or destroys it as undelivered |

Tracking capacity is reserved before the worker starts. A registration cannot
both fire and report a tracking/start failure. If the defensive completion
limit check fails, the generated Msg is destroyed before error propagation;
the node and remaining detached requests are also cleaned up. The callback
never sends owned Msgs from a worker or back into the runtime's own full queue.
Once update begins, the app owns the Msg even if update returns an error.
Root `.deinit` and owned task results are fully compatible with this contract.

Completed one-shot nodes are joined and freed at the next effect-drain entrance.
The terminal worker publishes completion before one nonblocking wake attempt;
a full queue already supplies another turn. Runtime distinguishes the helper
flag from backend completion and awaits the Future before freeing the node/ID.
Active timers are skipped. Queued notices and their borrowed referents remain
independent of node reclamation. See
[Timers and Frames](RUNTIME.md#timers-and-frames) for idle progress and delay
conditions, including foreground commands and long application callbacks.

### Testing real timer delivery

`TestCtx.tickAt/everyAt` expose only borrowed ID, duration, and non-owning Notice.
For a real consumer test, initialize `chasen.testing.TimerDriver(Msg)` in final
storage with `try driver.init(&tc)`. It borrows that TestCtx's allocator/Io and
owns a real TimerRuntime, headless event loop, and failure completion buffer.
`try driver.drain()` reaps completed timers and applies cancel/tick/every stages.
`try driver.nextMessage()` consumes completion wakes through the same reaper and
polls completions before queued notifications and returns an optional Msg,
owned by the test: pass it to update or use `tc.discardMessage(&msg)`.

Deinitialize the driver before TestCtx. It joins workers, drops queued notices
without callbacks, and destroys unapplied Msgs; it does not free already
returned Msgs. Keep TestCtx and driver at their initialized addresses, do not
drive them concurrently, and do not reset the borrowed TestCtx while in use.
This is a Timer test driver, not a task runner or a full application runtime.

## Review checklist

When adding a new asynchronously produced message variant:

1. Identify whether its payload owns memory or merely borrows/references
   runtime-owned state.
2. Add the owned case to `deinitUndelivered` before wiring the producer.
3. Keep the normal `update` cleanup path separate; the runtime hook is never
   called after `update` has accepted the message.
4. Verify stale-result branches also release their payloads.
5. Keep Timer Notice non-owning; declare generated owned Msg cleanup separately.
6. Add a test that constructs the owned variant, calls
   `deinitUndelivered`, and passes under `std.testing.allocator`.

## Related Guides

- [Runtime and Effects](RUNTIME.md): event flow, timers, terminal effects, and options.
- [Development and Testing](DEVELOPMENT.md): local checks and Linux PTY tests.
