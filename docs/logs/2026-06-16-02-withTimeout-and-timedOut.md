# 2026-06-16-02: withTimeout helper and KeraunosError.timedOut

**Status:** Implemented (gap closed — see Python watchdog follow-up below)

## Context

Phase A of bounding extraction: yt-dlp network calls can block indefinitely
(slow DNS, stalled TLS handshake, pathological playlist). The app must never
hang — users need a recoverable error they can retry. A wall-clock timeout
wrapper that works with any `async throws` operation was needed before
integrating it at the `PythonExtractor` call site.

## Options

| Approach | Pros | Cons |
|----------|------|------|
| `withThrowingTaskGroup` race (chosen) | Pure Swift Concurrency; structured; cancels loser automatically when `defer { group.cancelAll() }` runs | Cancellation is cooperative — CPython C calls inside Python won't respond to it |
| `Task` + `Task.sleep` + manual cancel | Same semantics, more boilerplate | No benefit over task group; harder to read |
| `withCheckedThrowingContinuation` + `DispatchWorkItem` | Could force-interrupt C code via thread termination | Extremely unsafe; violates Swift 6 isolation model; ruled out immediately |
| Timeout inside Python (signal/asyncio) | Python-native; could interrupt C extensions | Embedded CPython has no `fork`/signals in iOS sandbox; asyncio conflicts with yt-dlp's sync API |

## Decision

Use `withThrowingTaskGroup` to race the operation against `Task.sleep(for:)`,
throwing `KeraunosError.timedOut` if the timer wins.

## Rationale

The task group approach is idiomatic Swift 6, requires zero locks or GCD, and
composes naturally with any `async throws` callee. The cooperative-cancellation
limitation (CPython won't stop mid-C-call) is real but manageable: callers that
wrap blocking Python work must run it on a dedicated executor (not a shared
thread pool thread) so an orphaned call cannot starve other work. That
constraint is documented in `Timeout.swift`'s docstring and will be enforced at
`PythonExtractor` in a follow-up task.

## What Changed

- `KeraunosCore/Sources/KeraunosCore/KeraunosError.swift` — added `case timedOut`
  after `mergeFailed`; added `errorDescription` branch returning
  "Extraction took too long and was stopped."
- `KeraunosCore/Sources/KeraunosCore/Timeout.swift` — new file; public
  `withTimeout<T: Sendable>(_:_:)` free function.
- `KeraunosCore/Tests/KeraunosCoreTests/TimeoutTests.swift` — new file; 4 Swift
  Testing tests written before implementation (TDD).
- `app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift` — wrapped
  `resolve(_:)` in `withTimeout(timeout)`; extracted the blocking C call to a
  private actor-isolated `blockingExtract(_:cookiePath:)` method; added
  `timeout: Duration` property (default 45 s, injectable via `init`).

## What Was Discovered

- The `defer { group.cancelAll() }` pattern inside `withThrowingTaskGroup`
  cleanly handles all three outcomes (value returned, operation throws, timer
  fires) without any special-casing — the group's `next()` propagates whichever
  error arrives first, and `defer` cancels the surviving task.
- `group.next()` returning `nil` is technically unreachable here (two tasks are
  always added), but the guard-throw keeps the compiler and future readers happy.
- CPython cooperative-cancellation gap is a known limitation; it must be
  addressed at `PythonExtractor` (dedicated executor), not here.
- `blockingExtract` must remain actor-isolated (not `nonisolated`): calling
  `await blockingExtract(...)` from inside the (non-isolated) `withTimeout`
  task-group closure causes a hop onto the actor's serial `DispatchSerialQueue`
  executor, which preserves single-interpreter serialization. Marking it
  `nonisolated` would skip the hop and allow two callers to reach CPython
  concurrently.
- On timeout the C call is orphaned on the actor's serial executor until it
  returns naturally; the next `resolve` queues behind it. This is acceptable
  because the dedicated executor means no shared thread-pool starvation.

## Python Watchdog Follow-up (branch feat/authenticated-extraction)

The cooperative-cancellation gap described above was confirmed on-device:
Instagram reels and YouTube hangs bypass `socket_timeout` (DNS stalls, retry
loops, JS eval chains are not individual socket reads). `withTimeout` never
fires because `withThrowingTaskGroup` awaits all children — a blocked C call
in the non-cancellable child means the timeout task wins the race but the
`group.cancelAll()` defer still blocks waiting for the C child to return.

**Fix:** Moved the body of `extract()` to `_extract_impl()` (verbatim, no
behaviour change). The new `extract()` runs `_extract_impl` in a daemon
thread and `Thread.join(overall_timeout=30)`. `Thread.join` releases the GIL
while waiting, so it always returns at the deadline regardless of what the
worker thread is doing — even if the worker holds the GIL or is blocked in a
native network call. On timeout, `_err("timeout", ...)` is returned
immediately; the worker is abandoned (daemon thread). The Swift actor
serializes calls, so abandoned threads don't pile up. The `"timeout"` error
kind is now mapped to `KeraunosError.timedOut` in the Swift bridge.

**Why `Thread.join` not `signal`/`asyncio`:** iOS sandbox has no
`fork`/`SIGALRM`; asyncio conflicts with yt-dlp's synchronous API.

**Why the worker is abandoned, not killed:** Python has no safe
`Thread.kill` API. Daemon flag ensures the thread doesn't prevent process
exit. Single-interpreter serialization via the Swift actor means the next
extraction queues behind any orphan, bounding the practical worst case.

## What Changed (updated)

- `keraunos_extract.py` — added `import threading`, `_OVERALL_TIMEOUT = 30`;
  renamed `extract` body to `_extract_impl(url, socket_timeout, cookiefile)`;
  new `extract()` wraps it with a daemon-thread watchdog.
- `KeraunosCore/Sources/KeraunosCore/KeraunosError.swift` — added
  `case "timeout": self = .timedOut` in `init(errorKind:)`.
- `test_extract.py` — added `test_overall_timeout_bounds_a_nonresponsive_host`
  (socket_timeout=30 so only watchdog can fire; asserts elapsed < 10s).
- `KeraunosErrorTests.swift` — added `"timeout"` assertion to `mapsKnownErrorKinds`.

## Commits

| SHA | Description |
|-----|-------------|
| 29eca8e | feat(core): add withTimeout helper and KeraunosError.timedOut |
| 555bd87 | feat(app): bound extraction with an overall wall-clock timeout |
| 8100fb0 | fix(python): bound extraction with an overall watchdog timeout so the bridge never hangs |
