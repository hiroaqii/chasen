# Development and Testing

Use Zig 0.16.0 and a repository checkout. The fetched library package excludes
`examples/` and `docs/`; run development commands from the cloned repository.
Interactive examples need a terminal. Automated Linux PTY tests create their own
pseudo terminals and do not need an interactive CI session.

## Local Checks

```sh
zig build
TMPDIR="${TMPDIR:-/tmp}" zig build test
zig build check-io-threaded
zig build check-examples
zig build check-runtime-wasm
```

`zig build` alone does not compile the full example suite. Use `check-examples`
to compile all standard examples, including the foreground-command and task
cancellation apps. `check-io-threaded` runs the standard-Io smoke test.
`check-runtime-wasm` compiles a small runtime-only API usage check; it is not a
browser execution test. The optional `anim_transition` example needs a local
`chasen-anim` checkout and is not part of `check-examples`:

```sh
zig build check-anim_transition -Dchasen-anim-path=../chasen-anim
```

## Linux PTY Integration Tests

On Linux, unfiltered `zig build test` includes both integration tests below:

```sh
zig build test-terminal-input
TMPDIR="${TMPDIR:-/tmp}" zig build test-foreground-command
```

`test-terminal-input` checks terminal input through a PTY. The foreground gate
runs the actual Chasen runtime in an isolated PTY and checks terminal handoff,
exit/signals/stops, mode restoration, repeated commands, and cwd/environment
ownership.

The foreground test requires an existing, writable `TMPDIR`. It creates a unique
`foreground-cwd-*` directory and deletes it on normal return or error unwind.
The cwd case opens a directory, queues a command, closes the caller's descriptor,
and renames the directory before execution. A marker file verifies that the
child uses the original directory identity, with an empty replacement environment.
The test resolves its own executable to an absolute path before changing cwd.

macOS `zig build test` does not execute these Linux-only integration gates. To
check their runtime behavior before pushing, use a Linux VM or container with
Zig 0.16.0, procfs, and working PTYs, then run the same commands there. GitHub
Actions is one such environment, not a requirement of the tests.

## Focused and Cross-Compilation Checks

Filter unit tests while working on a specific behavior:

```sh
zig build test -Dtest-filter=foreground
```

A test filter excludes the two PTY gates; run them explicitly when validating
terminal behavior. Cross-compile without trying to execute Linux binaries on
macOS:

```sh
zig build check-foreground-tests -Dtarget=x86_64-linux-gnu
zig build check-task-tests -Dtarget=x86_64-linux-gnu
zig build install-foreground-fixture -Dtarget=x86_64-linux-gnu
```

The first two commands compile unit/consumer test artifacts. The last installs
`zig-out/bin/foreground-command-integration`, the real foreground PTY test helper.
Compilation checks types and linking, but cannot verify signals, terminal
ownership, cwd behavior, or runtime cleanup. Run the integration gates on Linux
for those checks.

## CI Coverage

[CI configuration](../.github/workflows/ci.yml) currently runs on `ubuntu-latest`
with Zig 0.16.0:

1. `zig build`
2. `zig build test`, with `TMPDIR` set to `${{ runner.temp }}`
3. `zig build check-io-threaded`
4. `zig build check-examples`

CI does not currently run a macOS/Windows matrix or `check-runtime-wasm`.
A passing native macOS test run is therefore not equivalent to this Linux gate.

For unit tests that queue tasks without running the terminal, use
`chasen.testing.discardPendingTasks` or `TestCtx.resetTransient` to clean up owned
contexts. See [Runtime Message Ownership](RUNTIME_MESSAGE_OWNERSHIP.md#tests-and-migration)
and [Authoring Components](AUTHORING_COMPONENTS.md#testing-surface-drawing).
