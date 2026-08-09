# 2026-08-08-01: Test harness for download progress reporting

**Status:** Implemented

## Commits

| Commit | Scope |
|--------|-------|
| `ded0dcf` | Aggregation math (`snapshot(for:)`) + the queue-row mapping seam |
| `3e64d2a` | Publication invariant across all coordinator transitions — found and fixed a missing `publish` in `taskDidFail` |
| `332e4d4` | Single-shot tracks learn their total from the delegate, so the bar is determinate before completion |
| `0c1f9cf` | Carry yt-dlp's per-format size as a display-only estimate, closing the adaptive video phase |
| (this) | Expand reusable domain/component harnesses and harden crash-safe transfer ownership |

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

---

## Follow-up: gap 2 — the publication invariant, and the bug it found

### Context

The coordinator calls `publish` from 18 places; only 4 were asserted. Every transition *was*
tested, but only for its effect on the store — and the store is always right, because that's
what the transition writes. Nothing checked the bus, which is what the UI actually watches.

### Decision

A `TransferProgressPublicationTests` suite that drives each transition through the public
ingress with a bus attached, and asserts a single invariant via a shared helper: **the bus
snapshot's state equals the persisted job's state, and its bytes equal the summed track
offsets.** 15 tests, one per transition (start-on-complete, pause, resume, refresh keeping vs
resetting the offset, unexpected status, corruption at a non-zero offset, 403, expired URL,
mid-sequence chunk, final chunk, task failure, and the three `reassociateAndResume` branches).

Considered and rejected: adding a bus to the existing state-persistence tests (would have
churned ~20 tests and conflated two concerns), and one table-driven parameterized test (each
transition needs different setup, so `@Test(arguments:)` would have carried a payload of
setup closures — less readable than 15 short tests).

### What Changed

- `KeraunosCore/TransferCoordinator.swift` — **`taskDidFail` now publishes.** One-line fix.
- `KeraunosCoreTests/TransferProgressPublicationTests.swift` (new, 15 tests).

### What Was Discovered

- **A real bug, found by the second test written: `taskDidFail` never published.** On a network
  drop the coordinator clears the track's `taskIdentifier` and persists — which flips the row
  from "Downloading" to "Waiting (background)" — but emitted nothing. Since
  `DownloadsViewModel.start()` rebuilds *only* on a bus emission, the row kept rendering a live
  download with a frozen progress bar until some unrelated job happened to publish. On a
  single-download queue (the common case) that means until the next launch or foreground
  activation. This is precisely the failure class the audit predicted for the unasserted
  publish sites.
- **The state-equality invariant alone could not have caught it.** `taskDidFail` leaves the
  state at `.downloading`; only the *row variant* changes. The test seeds the bus with a
  snapshot the coordinator could never derive (999999 of 1000000 bytes) and asserts it gets
  overwritten — a positive probe for "an emission happened" that needs no stream timing or
  timeout. Worth reusing for any transition that publishes without changing state.
- `taskDidFail`'s `isCancelled` parameter is dead: a user-initiated pause clears
  `owners[tid]` before cancelling, so the cancellation callback hits the no-owner guard and
  returns. Left alone — it documents the delegate contract — but it is not a live input.
- The other 14 transitions all published correctly. As with the aggregation math, the value
  here is the guard, not the repair — except for the one that wasn't.


---

## Follow-up: the reported progress was *accurate* but almost never determinate

### Context

With the plumbing verified, the obvious next question — "is the download list showing correct
progress now?" — turned up a bigger gap than any missing `publish`. Nothing displayed a wrong
number, but a **percentage almost never appeared at all**:

- `TransferJobFactory.trackJob` seeds `totalBytes: nil`, so a track only learns its size from a
  response.
- **Chunked (206)** learns it from `Content-Range` on the first chunk.
- **Single-shot (200)** recorded it only at *completion* — so for the entire download the bus
  published `totalBytes: nil`, `fraction` was nil, and `TransferQueueRow` fell through to
  `IndeterminateBar()` + "Downloading…" instead of a percentage. That is **every site except
  YouTube's chunk-hinted formats**.
- Meanwhile `taskDidWriteData` was handed `totalBytesExpectedToWrite` — the real
  `Content-Length` — on every callback and discarded it.

### Options

| Approach | Pros | Cons |
|----------|------|------|
| Seed `totalBytes` at enqueue from yt-dlp's size (`FormatOption.approxBytes` exists but never reaches `MediaTrack`) | determinate from byte zero; the only fix that helps the adaptive video phase | `approx_bytes` can be a bitrate estimate → a bar that overshoots and visibly corrects; needs a `MediaTrack`/`TrackJob` field |
| Publish the delegate's expected size without persisting | no store writes | lost on relaunch, and `snapshot(for:)` derives the total from the persisted job, so it wouldn't feed the bar at all |
| **Persist the delegate's expected size for non-chunked tracks (chosen)** | exact (it *is* the `Content-Length`), no schema change, determinate from the first callback, survives relaunch | doesn't fix adaptive (see below); one store write per track |

### Decision

`taskDidWriteData` adopts `totalBytesExpectedToWrite` as the track's `totalBytes` when the
track is **single-shot** (`chunkSize == nil`), the value is `> 0`, and it differs from what's
already recorded.

### What Changed

- `KeraunosCore/TransferCoordinator.swift` — new `learnTotalIfSingleShot(_:expected:)`, called
  from `taskDidWriteData` before `publish`.
- `KeraunosCoreTests/TransferProgressPublicationTests.swift` — 6 tests (TDD: the two
  behavioral ones were red first); `Rig` now carries its directory for the persistence check.

### What Was Discovered

- **Two values must never be adopted, and both are easy to hit.** On a *ranged* request
  `totalBytesExpectedToWrite` is the CHUNK's length — adopting it would peg a multi-GB YouTube
  track's total at one chunk and show a bar that fills and resets every chunk. And a response
  with no `Content-Length` reports `NSURLSessionTransferSizeUnknown` (**-1**), which as a total
  would poison `fraction`. Both are guarded and tested.
- **Completion stays authoritative**, which is what keeps the finalizer safe: the 200 path
  still overwrites `totalBytes` with the bytes actually written, so a server that lies in
  `Content-Length` can't leave a bogus expected length for the integrity check to compare
  against. Asserted by `completionOverwritesALearnedTotalWithTheActualLength`.
- The write is guarded on a change because the delegate fires far too often to persist per
  callback — in practice one store write per track.
- **Adaptive jobs are still indeterminate through the video phase.** `snapshot(for:)` requires
  *every* track's total, and the audio track's isn't known until audio starts, which is after
  video finishes. So a DASH download shows a real percentage only during the short audio tail.
  Fixing that needs the rejected option above (carry yt-dlp's per-format size onto
  `MediaTrack`/`TrackJob`) — deliberately deferred, since it trades exactness for an estimate
  that can visibly correct itself.
- No effect on completeness logic: single-shot keeps `bytesWritten == 0` until completion, so a
  learned total leaves the track incomplete (`0 < total`) and `firstIncompleteTrackIndex` /
  `rowState` behave exactly as before.

---

## Follow-up: the adaptive video phase — a size estimate that cannot break a download

### Context

After `332e4d4`, single-shot transfers show an exact percentage. Adaptive (DASH) jobs did not:
`snapshot(for:)` needs *every* track's total, tracks download sequentially, and the second
track's size isn't known until it starts — so the entire video phase (the bulk of the bytes)
stayed indeterminate and a real percentage appeared only during the short audio tail.

yt-dlp already reports a per-format size; it just never reached the job. `_track()` in
`keraunos_extract.py` omitted it, `MediaTrack` had no field for it, and
`TransferJobFactory` seeded `totalBytes: nil`.

### Options

| Approach | Pros | Cons |
|----------|------|------|
| Seed the estimate into `TrackJob.totalBytes` | no new field; `snapshot(for:)` works unchanged | **unsafe** — see below |
| Estimate the missing track from the known one (e.g. audio ≈ 10% of video) | no new plumbing at all | invents a number; wrong across codecs and bitrates |
| **New display-only `approxBytes`, preferred per-track only when no real total exists (chosen)** | determinate from byte zero; cannot influence transfer control flow; degrades to today's behavior when yt-dlp reports no size | one additive field through 4 layers; the number can drift, so the UI must hedge it |

### Decision

Carry yt-dlp's `filesize`/`filesize_approx` as `MediaTrack.approxBytes` →
`TrackJob.approxBytes`, a **display-only** value. `snapshot(for:)` takes each track's
`totalBytes ?? approxBytes`, stays nil only when a track has neither, and sets a new
`ProgressSnapshot.isEstimated` when any track fell back. The row renders an estimate as `~42%`,
capped at 99%.

### Rationale

Seeding `totalBytes` looks like the cheap version and is actively dangerous — that field is
load-bearing in three places, and `filesize_approx` is derived from bitrate, so it is routinely
*low*:

1. Chunk termination is `ended = … || (total.map { length >= $0 } ?? false)`. A low total ends
   the transfer mid-file, and the job then finalizes a **truncated video**.
2. `firstIncompleteTrackIndex` compares `bytesWritten < totalBytes` — a low total makes a
   partial track look finished and skips it.
3. `TransferFinalizer` fails a part whose bytes ≠ `totalBytes`, so a stale estimate that never
   got overwritten would surface as a bogus `.integrityCheckFailed`.

A separate field makes all three impossible by construction rather than by care.

### What Changed

- `PythonResources/app/keraunos_extract.py` — `_track()` emits `approx_bytes` via the existing
  `_fmt_size()` helper (`filesize` or `filesize_approx`).
- `KeraunosCore/MediaTrack.swift`, `TransferJob.swift` (`TrackJob`) — new optional
  `approxBytes`, documented as display-only. Additive and Codable-safe: existing persisted jobs
  decode it as nil and simply keep the old indeterminate behavior.
- `KeraunosCore/ResolvedMedia.swift` — decode `approx_bytes` off the wire.
- `KeraunosCore/TransferJobFactory.swift` — carry it onto the `TrackJob` (`totalBytes` stays nil).
- `KeraunosCore/TransferProgress.swift` — `ProgressSnapshot.isEstimated` (defaulted, so existing
  call sites are untouched); documented that `fraction` is deliberately **not** clamped.
- `KeraunosCore/TransferCoordinator.swift` — two-tier total in `snapshot(for:)`.
- `Keraunos/UI/DownloadsViewModel.swift` — `QueueItem.isEstimatedTotal`.
- `Keraunos/Components/TransferQueueRow.swift` — `percent(fraction:isEstimated:)` /
  `percentText(…)`, used by the status line and the bar's accessibility value.
- Tests: 4 Python (payload sizes, per-track not summed), 2 extraction decoding, 1 factory,
  5 aggregation, **2 coordinator safety regressions**, 7 app-side (flag propagation + percent
  formatting). All written before the implementation.

### What Was Discovered

- **The safety tests are the point of this change.** `aLowEstimateDoesNotTerminateAChunkedDownload
  Early` drives a real 400-byte file with a 150-byte estimate and asserts the transfer keeps
  going past 200 bytes and ends on the *real* total; `aTrackPastItsEstimateIsStillIncomplete`
  asserts a job past its estimate still downloads instead of jumping to merging. Without them
  a later "simplification" that folds `approxBytes` into `totalBytes` would silently ship
  truncated videos — and every other test would stay green.
- **Where the estimate actually gets used is narrower than expected**, which is reassuring: a
  chunked track learns its real total from `Content-Range` on chunk 1, and a single-shot track
  from the delegate on the first callback (`332e4d4`). So the estimate covers exactly two
  windows — before the first byte, and a not-yet-started second adaptive track. Both are
  precisely the holes that were indeterminate.
- **A completed job is never flagged estimated**: completion writes real totals for every track,
  so the row can't end on "~100%".
- The percent cap has to be 99, not 100, for estimates: a low `filesize_approx` produces
  `fraction > 1`, and both "137%" and a premature "100%" read as bugs while bytes are still
  arriving. `ProgressBar` already clamped the *bar*; the text did not.
- `_track()` calls `_fmt_size()`, which is defined ~60 lines below it. Fine in Python (name
  resolution happens at call time), and it keeps the helper next to its other caller.

---

## Follow-up: reusable domain/component harnesses and crash-safe ownership

### Context

The progress harnesses proved individual transitions but still left each suite assembling its
own store/session/files, while the app boundary stopped at injected view-model mocks. A broader
review also found that the production lifecycle those tests exercised had unsafe relaunch
windows: `.merging` jobs could strand, background URLSession completion could overtake async
persistence, and persisted filenames/output collisions lacked a durable ownership proof.

### Options

| Approach | Pros | Cons |
|----------|------|------|
| Keep per-test fixtures and add isolated regressions | smallest diff | duplication keeps drifting; cross-component invariants remain hard to state |
| One global app test container | minimal setup at call sites | shared mutable state, simulator coupling, and poor failure isolation |
| **Separate Core/app/lifecycle harnesses (chosen)** | matches dependency direction; Core stays simulator-free; behavior is asserted at durable boundaries | more explicit fixture code and cleanup ownership |
| Copy progressive parts before completion persistence | source always remains after a crash | multi-GB write amplification and temporary duplication |
| Trust recovered outputs by byte length | cheap and simple | can accept an unrelated replacement and delete the trusted source |
| **Atomic promotion plus a retained inode checkpoint (chosen)** | no copy; exact ownership across relaunch and Photos post-processing | requires deterministic owned artifacts and an additive durable phase |

### Decision

Introduce separate reusable harnesses for the transfer domain, app components, and background
lifecycle; make filesystem ownership explicit with validated components, transactional store
updates, deterministic stages, and a hard-link identity checkpoint retained until durable job
removal.

### What Changed

- `TransferDomainHarness.swift` composes a real temporary store, scripted session, progress bus,
  diagnostics, staging, and fresh-store reload helpers. Representative coordinator, persistence,
  progress, and request-header tests now use that vocabulary.
- `AppComponentHarness.swift` owns isolated files/preferences and scripts exact extraction/listing
  commands, enqueue outcomes, queue projection, and cookie behavior.
- `BackgroundTransferService` validates and reconciles its staging root before session creation,
  serializes completion/failure ingress ahead of the OS drain callback, and coalesces progress to
  one latest pending value per task.
- `SafeFileComponent` plus `TransferJobStore` reject traversal, terminal symlinks, duplicate job
  IDs, and case/Unicode ownership aliases. Candidate snapshots reach memory only after atomic
  persistence; orphan reporting reflects actual safe unlink results.
- `TransferFinalizer` persists `preparing`/`readyToPromote`, uses deterministic partial/ready
  stages, promotes without copying, and verifies recovered destinations by device/inode through a
  retained hard-link checkpoint. The checkpoint survives `.completed` and Photos work until
  `TransferJobStore.remove` durably removes the job.
- `AVFoundationMerger` replaces crash-leakable UUID scratch directories with two deterministic,
  job-owned hard-link aliases.

### What Was Discovered

- The first crash fix used `copyItem` so source bytes survived completion-persistence failure. It
  was functionally safe but a serious multi-GB performance regression; same-volume atomic
  promotion plus a hard-link checkpoint provides durability without copying.
- Size equality is not ownership. A same-sized progressive replacement—or any nonempty adaptive
  replacement—could be accepted after a crash. Device/inode identity is the durable proof needed
  before deleting sources or saving to Photos.
- Installing the UIKit background completion before session recreation fixed one race, but the
  delegate still launched untracked Tasks. A single FIFO worker is required so the OS drain signal
  follows coordinator persistence; progress must be coalesced or that FIFO can grow without bound.
- Lexical path containment rejects `../`, but an in-directory symlink still redirects file I/O.
  Terminal object-type validation and safe direct-entry `unlink` are both necessary. A narrow
  check-before-I/O race remains; eliminating it would require descriptor-relative
  `openat(..., O_NOFOLLOW)` operations.
- AVFoundation's media-daemon workaround must remain hard-link based on physical devices, but UUID
  scratch directories leak inodes on process death. Deterministic job-owned aliases bound and
  reconcile the same workaround.
- Final verification: 256 Core tests across 29 suites, 66 app tests (68 invocations), iPhone 17
  simulator build green, and independent closure review with no unresolved Critical/Major issues.
