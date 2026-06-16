# 2026-06-16-02: withTimeout helper and KeraunosError.timedOut

**Status:** Implemented

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

## What Was Discovered

- The `defer { group.cancelAll() }` pattern inside `withThrowingTaskGroup`
  cleanly handles all three outcomes (value returned, operation throws, timer
  fires) without any special-casing — the group's `next()` propagates whichever
  error arrives first, and `defer` cancels the surviving task.
- `group.next()` returning `nil` is technically unreachable here (two tasks are
  always added), but the guard-throw keeps the compiler and future readers happy.
- CPython cooperative-cancellation gap is a known limitation; it must be
  addressed at `PythonExtractor` (dedicated executor), not here.

## Commits

| SHA | Description |
|-----|-------------|
| 29eca8e | feat(core): add withTimeout helper and KeraunosError.timedOut |
