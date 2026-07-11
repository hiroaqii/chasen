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
delivery. It also keeps `TaskFailure` exhaustive.

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

1. Raise the runtime shutdown flag so worker and timer helpers stop posting.
2. Cancel the already-started tty reader future in place, without allocating a
   shutdown helper. Cancellation interrupts both tty reads and bounded-queue
   condition waits; then drain events left in the queue.
3. Cancel frame and timer futures.
4. Await every started one-shot task future. Deinitialize every
   `.undelivered(Msg)` outcome.
5. Drain messages already transferred to the event queue.
6. Deinitialize runtime-thread completions that were not applied.
7. Consume queued-but-unstarted task contexts through their required failure
   callbacks, then deinitialize the returned messages.
8. Run `App.deinit`, followed by terminal and image-registry cleanup.

OSC 52 clipboard responses are a separate terminal-internal ownership case.
Chasen exposes clipboard writes, not clipboard-read requests, and deliberately
omits libvaxis' allocator-owning `.paste` field from its internal event union.
libvaxis therefore frees an unsolicited OSC 52 response synchronously instead
of attempting to transfer it through the bounded event queue. Ordinary user
paste still reaches `Event.paste`: Chasen assembles it from bracketed-paste
markers and owns the temporary buffer for that one dispatch. Chasen pins a
libvaxis revision whose parser also frees the decode buffer when malformed
base64 fails before an event can be constructed.

Started tasks are awaited rather than force-cancelled because the task API
returns an application message, not a cancellation-aware result. A task that
never returns can therefore block shutdown. Keep task bodies finite and use
request ids or generations to reject stale results during normal operation.

## Task failure callbacks

`chasen.TaskFailure` has two cases:

- `.start_failed: []const u8`: the runtime could not allocate tracking storage
  or start the worker. The callback result is normally delivered to `update`
  through the runtime-thread completion buffer.
- `.runtime_abandoned`: runtime error unwind found a queued task before it was
  transferred to a future. The callback exists to consume `spawnWith` context;
  its returned `Msg` is immediately handled as undelivered and never reaches
  `update`.

Failure callbacks should be exhaustive even when their user-facing text is
only observable for `.start_failed`.

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
