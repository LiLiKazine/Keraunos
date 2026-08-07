# 2026-08-08-01: Test harness for download progress reporting

**Status:** Implemented

## Commits

| Commit | Scope |
|--------|-------|
| (this) | Aggregation math (`snapshot(for:)`) + the queue-row mapping seam |

## Context

An audit of what actually covers download progress reporting found the harness thin and
stopping at the Core boundary. Existing coverage: `TransferProgressTests` (the bus — fraction
math, set/remove, `updates()`), three `TransferCoordinatorTests` publication tests, one
`TransferFinalizerTests` completed-snapshot test, and `TransferRowStateTests` for the
`JobState` → row mapping. All green, but with three real gaps:

1. **Multi-track aggregation had no tests.** `TransferCoordinator.snapshot(for:liveReceived:)`
   sums `bytesWritten` across tracks and returns `totalBytes: nil` if *any* track total is
   unknown. Every existing assertion used a single progressive track, so the adaptive (DASH)
   path — where two tracks download *sequentially* and a naive per-track fraction would run to
   100% at the video handoff and then visibly restart — was unverified.
2. **Only ~4 of the coordinator's 18 `publish` sites were asserted.** Every transition is
   tested for *persisted state*, nothing for what lands on the bus.
3. **`DownloadsViewModel.rebuild` had zero tests** — the layer between a correct bus and a
   correct row: the `snap?.receivedBytes ?? sum(bytesWritten)` fallback, `fraction`
   pass-through, and the active → queued → attention ordering.

This commit closes 1 and 3. Gap 2 follows.

## Options

### Making `DownloadsViewModel` testable

`rebuild` mixed pure mapping with engine I/O, and `TransferEngine` is a `@MainActor final
class` with a `private init` + `static let shared` that builds the real `TransferJobStore`,
`AVFoundationMerger`, and `BackgroundTransferService`, and calls `UIApplication` — so it
cannot be instantiated in a test.

| Approach | Pros | Cons |
|----------|------|------|
| Protocol seam over the engine (`QueueSourcing`) | matches the project's protocol-seamed style; would also cover `start()`'s stream subscription | a new abstraction with one production conformer, to test a function that needs no I/O; the engine surface (`store`, `consumeRecentlySaved`, 5 actions) all has to go through it |
| Make `TransferEngine.init` non-private / injectable | no new protocol | it is a singleton *because* the background `URLSession` must be unique per identifier; a second instance is a real hazard |
| Move the mapping into Core next to `TransferRowState` | simulator-free, matches "keep pure logic in the package" | `QueueItem` is a SwiftUI display type; moving it drags presentation into Core |
| **Extract the pure half as a static func (chosen)** | zero new abstraction, no mocking, `rebuild` drops to two lines, covers exactly the logic that can be wrong | the engine-facing half of `rebuild` (2 lines) stays untested |

### Testing the aggregation math

| Approach | Pros | Cons |
|----------|------|------|
| End-to-end through the coordinator only | exercises the real publish path | slow to enumerate the total-unknown matrix; each case needs a store + scripted session |
| Direct unit tests on the static func only | fast, exhaustive on the matrix | doesn't prove `publish` actually routes through it |
| **Both (chosen)** | matrix cheaply + one real-path proof at the adaptive handoff | slight overlap |

## Decision

Extract `DownloadsViewModel.rows(jobs:snapshots:)` as a pure static function and unit-test it;
cover `TransferCoordinator.snapshot(for:liveReceived:)` with a direct matrix plus one
end-to-end adaptive-handoff assertion on the bus.

## Rationale

The mapping and the aggregation are both *pure functions* that happened to be reachable only
through un-instantiable objects. Extraction buys full coverage of the logic that can produce a
wrong number on screen, at the cost of two untested lines of plumbing — a better trade than a
protocol with a single conformer that exists only for tests. `TransferEngine` stays a singleton
for the reason it always was: one background `URLSession` per identifier.

## What Changed

- `Keraunos/UI/DownloadsViewModel.swift` — pure `static func rows(jobs:snapshots:)` split out
  of `rebuild`; `rebuild` is now the engine fetch + `consumeRecentlySaved()`. `rank` is
  referenced unqualified from the new static context. No behavior change.
- `KeraunosCoreTests/ProgressAggregationTests.swift` (new, 6 tests) — progressive
  pass-through; both adaptive tracks summed; finished-video-with-audio-pending must not read
  100%; one unknown track total makes the whole job indeterminate (in either position);
  `liveReceived` stacking on the summed offsets; state mirroring.
- `KeraunosCoreTests/TransferCoordinatorTests.swift` — `adaptiveHandoffPublishesSummedBytes
  NotAFullBar`: over the real publish path, video-done publishes 300 bytes against a `nil`
  total, then both tracks land as 400/400.
- `KeraunosTests/DownloadsViewModelTests.swift` (new, 11 tests) — labels/host/extension
  stripping, terminal jobs excluded, failure reason carried, bus-wins-over-persisted-offset,
  the no-snapshot fallback to summed offsets, indeterminate snapshots, row variant derived
  from the job (not the snapshot) so `.waitingBackground` survives, and the full ordering
  with `createdAt` tie-breaks.

## What Was Discovered

- **The aggregation math was already correct** — every new test passed on first run. These are
  regression guards on an untested path, not bug fixes. Worth stating plainly: the audit
  predicted the DASH bar could jump to 100% and restart, and it does not.
- `TransferCoordinator.snapshot` is internal, so `ProgressAggregationTests` needs
  `@testable import KeraunosCore`; the existing `TransferCoordinatorTests` uses a plain
  `import`. Both in one target is fine.
- The row's *variant* comes from the persisted job (`job.rowState`) while its *numbers* come
  from the bus. That split matters: a `.downloading` job whose task the OS dropped must render
  `.waitingBackground` even though the bus snapshot still says `.downloading`. Now asserted.
- The app target's test group is a `PBXFileSystemSynchronizedRootGroup`, so a new file under
  `KeraunosTests/` needs no `.pbxproj` edit.
- SourceKit reported "No such module 'Testing'" / "'KeraunosCore'" for the newly created
  files. Stale index noise only — `swift test` (183/183) and `xcodebuild test` (11/11) both
  compile them.
