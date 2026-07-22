# Background Transfer — Phase 6: Downloads-list queue UI & progress reconnection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the single inline "Downloading" card with a live, relaunch-reconnecting **transfer queue** driven by the background engine: a Core progress bus, a `@MainActor @Observable DownloadsViewModel`, a Download-tab queue rendering all nine row states, pause/resume/cancel/retry per-row actions, a coalescing "Saved to Library" toast, and an enqueue-first start flow that pushes jobs onto `TransferEngine.shared.coordinator`.

**Architecture:** Progress is reconstructed, never held in a fragile closure. A Core `actor TransferProgress` holds `[JobID: ProgressSnapshot]`; the `TransferCoordinator` and `TransferFinalizer` publish snapshots on every state change, and the app-target session delegate publishes live byte deltas. The UI reads via an `AsyncStream` from that bus and re-derives each row's *variant* from the persisted `TransferJob` (so it reconnects after relaunch from `store + getAllTasks()`), while the *body* (fraction/bytes) comes from the live snapshot. Row-state mapping and the enqueue job-builder are pure Core functions (TDD, simulator-free); the SwiftUI layer reuses the existing Refined-Native components and is compile-verified.

**Tech Stack:** Swift 6 (language mode v6), Swift Testing, SwiftUI, `Foundation`. Core stays `nonisolated`-default and simulator-free; app target is `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.

**Spec:** `docs/superpowers/specs/2026-07-21-background-transfer-design.md` — sections "Progress plumbing", "UI / UX" (Information architecture, Queue list, Row state catalog, Interaction, iPad, "Saved to Library" toast, Start flow & quality picker); phasing step 6. Design distilled in `Foundations.dc.html` / `Transfers.dc.html` / `TransferStates.dc.html` (Keraunos Claude Design, project `117a4f30-…`, via the `DesignSync` MCP) — the theme/components layer already implements those tokens; reuse, don't reinvent.

## Global Constraints

- **Swift 6 language mode** everywhere; package default isolation stays `nonisolated`, app target stays `MainActor`.
- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest. `try!` is allowed **only** in test fixtures.
- **NEVER `try?`. NEVER an empty/no-op `catch {}`.** Every error is either propagated or recorded to `TransferDiagnostics`/`FailureLog` (then recovery relies on the crash-consistent retry). Enforced by `.claude/hooks/swift-error-handling.sh` — self-police, the hook may not be live until `/hooks` is opened.
- **All new pure logic lives in `KeraunosCore`** so it stays `swift test`-able: the progress bus, row-state mapping, pause/resume, and the enqueue job-builder are Core. SwiftUI views/view-models are app-target and **compile-verified only** (no simulator unit tests added).
- **Types behind the `nonisolated TransferSession` seam and everything in `KeraunosCore` must be `nonisolated`/actor-isolated as appropriate** — never `@MainActor` in Core.
- **Persist relative part-file NAMES, never absolute URLs.** Crash-consistency ordering (append→fsync→persist→truncate-on-resume) is load-bearing — do not touch it.
- **Reuse the existing design system.** Tokens: `Color.Theme.*`, `Space`, `Radius`, `Stroke.hairline`, `Font.Theme.*`, `.card()`/`.sectionLabelStyle()`/`.tabularNumbers()`. Components: `ProgressBar(value:)`, `NoticeCard(tone:…)`, `EmptyStateView`, `Thumbnail`, `SectionHeader`, `CompactHeader`/`PaneTitle`, `Toast`/`ToastData`/`ToastCenter`, `PrimaryButtonStyle`/`GhostButtonStyle` (`.primary`/`.ghost`). No new visual language.
- **Verify commands.** Core: `swift test --package-path app/KeraunosCore` (currently 150 tests pass — keep them green). App build: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build` (needs `Python.xcframework` restored into `app/Keraunos/PythonResources/` — see that dir's README).
- Commit per task, TDD-first for Core tasks.

## What this phase deliberately does NOT do

- **No authenticated-in-background.** `credentialRef` stays `nil`; the "Needs sign-in" row renders and routes to the existing foreground login, but Keychain-backed background auth is a deferred follow-on.
- **No enqueue-first pipelining** (resolving as a queue row so several pastes queue without waiting). Starts stay **serial**: one foreground resolve/pick at a time. Transfers run concurrently once enqueued.
- **No device-tuned constants** (S1 background chunk size, S2 try-immediately merge) — those need a real device and are separate.
- **No chaos-flag code** — Phase 7.
- **No local notification** for completion while fully backgrounded — the toast covers foreground/relaunched only.

---

## File Structure

**KeraunosCore (new / modified — pure, TDD):**
- Create `app/KeraunosCore/Sources/KeraunosCore/TransferProgress.swift` — `ProgressSnapshot` value + `actor TransferProgress` (the progress bus + `AsyncStream`). One responsibility: hold and broadcast per-job progress.
- Create `app/KeraunosCore/Sources/KeraunosCore/TransferRowState.swift` — `enum TransferRowState` + `TransferJob.rowState` pure mapping. One responsibility: map durable state → the nine UI row states.
- Create `app/KeraunosCore/Sources/KeraunosCore/TransferJobFactory.swift` — pure builder: `ResolvedMedia` + `FormatSelection` + flags → `TransferJob`. One responsibility: construct a durable job from an extraction result.
- Modify `app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift` — add `JobState.paused`.
- Modify `app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift` — publish progress on state changes; add `taskDidWriteData`, `pause`, `resume`; `reassociateAndResume` skips `.paused`.
- Modify `app/KeraunosCore/Sources/KeraunosCore/TransferFinalizer.swift` — publish `.merging`/terminal snapshots to the bus.

**App target (new / modified — compile-verified):**
- Modify `app/Keraunos/Keraunos/Transfer/BackgroundTransferService.swift` — add the `didWriteData` delegate → `coordinator.taskDidWriteData`.
- Modify `app/Keraunos/Keraunos/Transfer/TransferEngine.swift` — own a `TransferProgress`, wire it into coordinator + finalizer, expose enqueue + queue-action API, prune completed jobs, announce Library saves.
- Create `app/Keraunos/Keraunos/UI/DownloadsViewModel.swift` — `@MainActor @Observable`; merges store + progress into `[QueueItem]`; issues pause/resume/cancel/retry; drives the coalescing toast.
- Create `app/Keraunos/Keraunos/Components/TransferQueueRow.swift` — one row, switching on `TransferRowState`.
- Modify `app/Keraunos/Keraunos/UI/HomeScreen.swift` — Download tab = hero + live queue rendered as a themed **`List`** (lazy rows + native swipe); remove the "Recent" section and the inline single-download card; add the cancelable "Resolving…" hero state.
- Modify `app/Keraunos/Keraunos/UI/AppShell.swift` — active-count badge on the Download tab item and the iPad sidebar item.
- Modify `app/Keraunos/Keraunos/UI/AppSection.swift` — (if needed) nothing structural; badge count is passed in.

---

# SLICE A — Progress plumbing (Core bus + coordinator/finalizer publish + delegate)

### Task A1: `ProgressSnapshot` + `TransferProgress` store

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/TransferProgress.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferProgressTests.swift`

**Interfaces:**
- Produces:
  - `public struct ProgressSnapshot: Sendable, Equatable { public let state: JobState; public let receivedBytes: Int64; public let totalBytes: Int64?; public var fraction: Double? }`
  - `public actor TransferProgress` with `func current() -> [UUID: ProgressSnapshot]`, `func snapshot(for id: UUID) -> ProgressSnapshot?`, `func set(_ snapshot: ProgressSnapshot, for id: UUID)`, `func remove(_ id: UUID)`.

- [ ] **Step 1: Write the failing test**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/TransferProgressTests.swift`:

```swift
import Testing
import Foundation
@testable import KeraunosCore

@Suite struct TransferProgressTests {
    private func snap(_ received: Int64, _ total: Int64?, _ state: JobState = .downloading) -> ProgressSnapshot {
        ProgressSnapshot(state: state, receivedBytes: received, totalBytes: total)
    }

    @Test func fractionIsReceivedOverTotal() {
        #expect(snap(50, 200).fraction == 0.25)
    }

    @Test func fractionIsNilWhenTotalUnknownOrZero() {
        #expect(snap(50, nil).fraction == nil)
        #expect(snap(50, 0).fraction == nil)
    }

    @Test func setAndReadBack() async {
        let bus = TransferProgress()
        let id = UUID()
        await bus.set(snap(10, 100), for: id)
        #expect(await bus.snapshot(for: id) == snap(10, 100))
        #expect(await bus.current()[id]?.receivedBytes == 10)
    }

    @Test func removeDropsTheEntry() async {
        let bus = TransferProgress()
        let id = UUID()
        await bus.set(snap(10, 100), for: id)
        await bus.remove(id)
        #expect(await bus.snapshot(for: id) == nil)
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferProgressTests`
Expected: FAIL — `cannot find 'ProgressSnapshot'` / `'TransferProgress'` in scope.

- [ ] **Step 3: Write the minimal implementation**

Create `app/KeraunosCore/Sources/KeraunosCore/TransferProgress.swift`:

```swift
import Foundation

/// A point-in-time view of one job's transfer progress, published on the `TransferProgress`
/// bus. `fraction` is derived (received / total), nil when the total is unknown — the UI
/// then shows an indeterminate bar (see the spec's "Waiting (background)" / early-adaptive
/// cases). `state` mirrors the durable `JobState` so the bus alone can drive most of the row.
public struct ProgressSnapshot: Sendable, Equatable {
    public let state: JobState
    public let receivedBytes: Int64
    public let totalBytes: Int64?

    public init(state: JobState, receivedBytes: Int64, totalBytes: Int64?) {
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    /// 0...1 whole-file fraction, or nil when the total isn't known yet (or is zero).
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(receivedBytes) / Double(totalBytes)
    }
}

/// The progress event bus. A Core `actor` holding the live `[JobID: ProgressSnapshot]` map,
/// written by the coordinator/finalizer (state changes) and the session delegate (byte
/// deltas), read by the UI via `updates()`. Because it is reconstructed from the persisted
/// store + live task reassociation, the UI reconnects after relaunch with no surviving
/// closure. (`updates()` is added in Task A2.)
public actor TransferProgress {
    private var snapshots: [UUID: ProgressSnapshot] = [:]

    public init() {}

    public func current() -> [UUID: ProgressSnapshot] { snapshots }

    public func snapshot(for id: UUID) -> ProgressSnapshot? { snapshots[id] }

    public func set(_ snapshot: ProgressSnapshot, for id: UUID) {
        snapshots[id] = snapshot
    }

    public func remove(_ id: UUID) {
        snapshots[id] = nil
    }
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferProgressTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferProgress.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferProgressTests.swift
git commit -m "feat(transfer): ProgressSnapshot + TransferProgress bus"
```

---

### Task A2: `TransferProgress.updates()` broadcast stream

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/TransferProgress.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferProgressTests.swift`

**Interfaces:**
- Consumes: `TransferProgress` (Task A1).
- Produces: `public func updates() -> AsyncStream<[UUID: ProgressSnapshot]>` — emits the current map immediately on subscribe, then again on every `set`/`remove`. Multiple concurrent subscribers each get their own stream.

- [ ] **Step 1: Add the failing test** (append to `TransferProgressTests`)

```swift
    @Test func updatesEmitsCurrentThenOnEachChange() async {
        let bus = TransferProgress()
        let id = UUID()
        await bus.set(snap(10, 100), for: id)   // pre-existing entry

        var iterator = bus.updates().makeAsyncIterator()
        let first = await iterator.next()        // immediate current snapshot
        #expect(first?[id]?.receivedBytes == 10)

        await bus.set(snap(60, 100), for: id)
        let second = await iterator.next()
        #expect(second?[id]?.receivedBytes == 60)

        await bus.remove(id)
        let third = await iterator.next()
        #expect(third?[id] == nil)
    }
```

- [ ] **Step 2: Run it, verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferProgressTests/updatesEmitsCurrentThenOnEachChange`
Expected: FAIL — `value of type 'TransferProgress' has no member 'updates'`.

- [ ] **Step 3: Implement `updates()` with fan-out**

In `TransferProgress.swift`, add a continuation registry and broadcast on mutation:

```swift
    private var continuations: [UUID: AsyncStream<[UUID: ProgressSnapshot]>.Continuation] = [:]

    /// A stream of the full snapshot map: the current value immediately, then a fresh map on
    /// every `set`/`remove`. Each caller gets an independent stream; the registration is torn
    /// down when the consumer stops iterating.
    public func updates() -> AsyncStream<[UUID: ProgressSnapshot]> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(snapshots)               // seed with the current state
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropContinuation(token) }
            }
        }
    }

    private func dropContinuation(_ token: UUID) {
        continuations[token] = nil
    }

    private func broadcast() {
        for continuation in continuations.values { continuation.yield(snapshots) }
    }
```

Then call `broadcast()` at the end of both `set(_:for:)` and `remove(_:)`:

```swift
    public func set(_ snapshot: ProgressSnapshot, for id: UUID) {
        snapshots[id] = snapshot
        broadcast()
    }

    public func remove(_ id: UUID) {
        snapshots[id] = nil
        broadcast()
    }
```

- [ ] **Step 4: Run it, verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferProgressTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferProgress.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferProgressTests.swift
git commit -m "feat(transfer): TransferProgress.updates() broadcast stream"
```

---

### Task A3: Coordinator publishes progress + `taskDidWriteData` ingress

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift`

**Interfaces:**
- Consumes: `TransferProgress` (A1/A2), the existing `ScriptedTransferSession`.
- Produces:
  - `TransferCoordinator.init(store:session:now:diagnostics:progress:)` — a new trailing optional `progress: TransferProgress? = nil`.
  - `func taskDidWriteData(taskIdentifier: Int, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) async` — live byte-delta ingress.
  - Progress is published (a `ProgressSnapshot` per job) whenever the coordinator changes a job's state or advances its bytes: in `start`, `beginTrack`, `taskDidFinishDownloading` (200/206/refresh/failure), `completeTrack`, `refresh`, and `reassociateAndResume`.

**Progress math (whole-file):** `receivedBytes = Σ track.bytesWritten (+ liveReceived for the in-flight track)`; `totalBytes = Σ track.totalBytes` **iff every track total is known, else nil**; `fraction` is derived by `ProgressSnapshot`. This matches the spec's "report indeterminate until totals are known."

- [ ] **Step 1: Write failing tests** (append to `TransferCoordinatorTests`; reuse its existing `track`/`job` helpers)

```swift
    @Test func publishesDownloadingSnapshotOnStart() async throws {
        let store = try makeStore()
        let session = ScriptedTransferSession()
        let bus = TransferProgress()
        let coord = TransferCoordinator(store: store, session: session, progress: bus)
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil)))
        try await store.upsert(j)
        try await coord.start(j)
        let snap = await bus.snapshot(for: j.id)
        #expect(snap?.state == .downloading)
    }

    @Test func liveByteDeltaUpdatesReceivedBytes() async throws {
        let store = try makeStore()
        let session = ScriptedTransferSession()
        let bus = TransferProgress()
        let coord = TransferCoordinator(store: store, session: session, progress: bus)
        // Chunked track: 4 MB total, 1 MB already written, 1 MB chunk size.
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 1_048_576,
                                              bytesWritten: 1_048_576, totalBytes: 4_194_304)),
                    state: .downloading)
        try await store.upsert(j)
        try await coord.start(j)
        let taskID = await session.started.last!.id
        await coord.taskDidWriteData(taskIdentifier: taskID,
                                     totalBytesWritten: 524_288, totalBytesExpectedToWrite: 1_048_576)
        let snap = await bus.snapshot(for: j.id)
        // persisted 1 MB + 0.5 MB live = 1.5 MB of 4 MB.
        #expect(snap?.receivedBytes == 1_572_864)
        #expect(snap?.totalBytes == 4_194_304)
    }

    @Test func unknownTaskDeltaIsIgnored() async throws {
        let store = try makeStore()
        let session = ScriptedTransferSession()
        let bus = TransferProgress()
        let coord = TransferCoordinator(store: store, session: session, progress: bus)
        await coord.taskDidWriteData(taskIdentifier: 999, totalBytesWritten: 1, totalBytesExpectedToWrite: 2)
        #expect(await bus.current().isEmpty)
    }
```

> If `makeStore()` / `job` / `track` helpers differ in the existing suite, use the suite's own helpers — do not duplicate them. `track(part:chunkSize:bytesWritten:totalBytes:)` and `job(kind:state:)` already exist per `TransferCoordinatorTests.swift:17-26`.

- [ ] **Step 2: Run it, verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferCoordinatorTests`
Expected: FAIL — `extra argument 'progress' in call` and `no member 'taskDidWriteData'`.

- [ ] **Step 3: Implement**

In `TransferCoordinator.swift`:

Add the stored property and init parameter:

```swift
    private let progress: TransferProgress?
```

```swift
    public init(store: TransferJobStore, session: any TransferSession,
                now: @Sendable @escaping () -> Date = { Date() },
                diagnostics: (any TransferDiagnostics)? = nil,
                progress: TransferProgress? = nil) {
        self.store = store
        self.session = session
        self.now = now
        self.diagnostics = diagnostics
        self.progress = progress
    }
```

Add the publish helper and snapshot math (place in the `// MARK: - Helpers` section):

```swift
    /// Publishes a fresh snapshot for `jobID` from its persisted state, optionally folding in
    /// `liveReceived` bytes for the in-flight track (delegate byte deltas). No-op without a bus.
    private func publish(_ jobID: UUID, liveReceived: Int64 = 0) async {
        guard let progress, let job = await store.job(id: jobID) else { return }
        await progress.set(Self.snapshot(for: job, liveReceived: liveReceived), for: jobID)
    }

    /// Whole-file snapshot: summed offsets (+ live chunk bytes), and a summed total only when
    /// EVERY track total is known (else indeterminate).
    static func snapshot(for job: TransferJob, liveReceived: Int64 = 0) -> ProgressSnapshot {
        let received = job.tracks.reduce(Int64(0)) { $0 + $1.bytesWritten } + liveReceived
        let totals = job.tracks.map(\.totalBytes)
        let total: Int64? = totals.contains(where: { $0 == nil })
            ? nil
            : totals.compactMap { $0 }.reduce(0, +)
        return ProgressSnapshot(state: job.state, receivedBytes: received, totalBytes: total)
    }
```

Add the ingress method (place in `// MARK: - Event ingress`):

```swift
    /// A live byte-progress callback from the session delegate. Republishes the owning job's
    /// snapshot with the in-flight chunk's received bytes folded in. Unknown task → ignored
    /// (launch race / stale), exactly like the completion ingress.
    public func taskDidWriteData(taskIdentifier: Int, totalBytesWritten: Int64,
                                 totalBytesExpectedToWrite: Int64) async {
        guard let owner = owners[taskIdentifier] else { return }
        await publish(owner.jobID, liveReceived: totalBytesWritten)
    }
```

Now add `await publish(<id>)` at each state transition. Insert after the corresponding `store.update`/`persist`:
- `start(_:)` — after `beginTrack(...)` (and in the `readyToMerge` early-return branch): `await publish(job.id)`.
- `refresh(...)` — after the final `beginTrack`: `await publish(jobID)`.
- `reassociateAndResume()` — after each `beginTrack`/`persist` transition inside the loop: `await publish(job.id)`.
- `taskDidFinishDownloading(...)` — after the 200 `completeTrack`, after the 206 `completeTrack`/`beginTrack`, in the `.needsRefresh` branch, and in the `catch` after `persist(...download_failed)`: `await publish(owner.jobID)`.
- `completeTrack(...)` — after the `readyToMerge` update and after `beginTrack(next)`: `await publish(jobID)`.
- `beginTrack(...)` — after setting the task identifier and in the `.needsRefresh` early-return: `await publish(jobID)`.

> Every one of these is an existing non-throwing or already-`throws` context — adding `await publish(...)` cannot swallow an error (it records nothing and returns; the bus write is best-effort UI state, and the durable store already persisted). Do **not** wrap `publish` in `try?`.

- [ ] **Step 4: Run it, verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferCoordinatorTests`
Expected: PASS — the new tests plus all pre-existing coordinator tests (progress is additive; the default `progress: nil` keeps old tests untouched).

- [ ] **Step 5: Full core suite**

Run: `swift test --package-path app/KeraunosCore`
Expected: PASS — ≥ 150 + new tests.

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift
git commit -m "feat(transfer): coordinator publishes progress snapshots + taskDidWriteData"
```

---

### Task A4: Session-delegate byte callback + engine wires the bus

**Files:**
- Modify: `app/Keraunos/Keraunos/Transfer/BackgroundTransferService.swift`
- Modify: `app/Keraunos/Keraunos/Transfer/TransferEngine.swift`
- Modify: `app/KeraunosCore/Sources/KeraunosCore/TransferFinalizer.swift` (+ its test)

**Interfaces:**
- Consumes: `TransferCoordinator.taskDidWriteData` (A3), `TransferProgress` (A1).
- Produces:
  - `BackgroundTransferService.urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)` forwarding to the coordinator.
  - `TransferEngine.progress: TransferProgress` (a stored, shared instance) wired into both `coordinator` and `finalizer`.
  - `TransferFinalizer.init(...progress: TransferProgress? = nil)` publishing `.merging`, `.completed`, and `.failed(...)` snapshots.

- [ ] **Step 1 (TDD Core): failing finalizer-publish test** (append to `TransferFinalizerTests.swift`)

```swift
    @Test func publishesMergingThenCompleted() async throws {
        let store = try makeStore()                       // suite helper
        let bus = TransferProgress()
        let merger = StubMerger()                         // suite's existing successful stub
        let downloads = DownloadStore(directory: tempDir())// suite helper
        let fin = TransferFinalizer(store: store, merger: merger, downloadStore: downloads, progress: bus)
        let j = readyProgressiveJob(part: "done.part", bytes: 1_000)  // suite helper: writes a matching part file
        try await store.upsert(j)
        _ = await fin.finalizeReadyJobs()
        #expect(await bus.snapshot(for: j.id)?.state == .completed)
    }
```

> Use the finalizer suite's existing helpers (`makeStore`, `StubMerger`, `readyProgressiveJob`, `tempDir`). If a helper of that exact name is absent, mirror the pattern already in `TransferFinalizerTests.swift`.

- [ ] **Step 2: Run it, verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferFinalizerTests`
Expected: FAIL — `extra argument 'progress' in call`.

- [ ] **Step 3: Implement finalizer publish**

In `TransferFinalizer.swift`, add `private let progress: TransferProgress?`, a `progress: TransferProgress? = nil` trailing init parameter (assign it), and in `persist(_:_:_:)` publish the just-written state after a successful `store.update`:

```swift
    private func persist(_ id: UUID, _ context: String,
                         _ mutate: @escaping @Sendable (inout TransferJob) -> Void) async {
        do {
            let updated = try await store.update(id: id, mutate)
            if let progress, let updated {
                await progress.set(TransferCoordinator.snapshot(for: updated), for: id)
            }
        } catch {
            diagnostics?.record(kind: "transfer_persist_failed", detail: "\(context) job \(id): \(error)")
        }
    }
```

(`TransferCoordinator.snapshot(for:)` is the shared static from A3 — reuse it, don't duplicate the math.)

- [ ] **Step 4: Run it, verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferFinalizerTests` → PASS. Then `swift test --package-path app/KeraunosCore` → full suite PASS.

- [ ] **Step 5 (App target): add the delegate byte callback**

In `BackgroundTransferService.swift`, under `// MARK: URLSessionDownloadDelegate`, add:

```swift
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        Task { [coordinator] in
            await coordinator?.taskDidWriteData(taskIdentifier: id,
                                                totalBytesWritten: totalBytesWritten,
                                                totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
    }
```

- [ ] **Step 6 (App target): wire the shared bus in the engine**

In `TransferEngine.swift`, add a stored `let progress: TransferProgress`, create it in `init` before the coordinator, and pass it to both:

```swift
    let progress: TransferProgress
```

```swift
        progress = TransferProgress()
        coordinator = TransferCoordinator(store: store, session: service,
                                          diagnostics: diagnostics, progress: progress)
        finalizer = TransferFinalizer(store: store, merger: AVFoundationMerger(),
                                      downloadStore: downloadStore, diagnostics: diagnostics,
                                      progress: progress)
```

- [ ] **Step 7: Build the app, verify it compiles**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `BUILD SUCCEEDED`. (Restore `Python.xcframework` first if missing.)

- [ ] **Step 8: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferFinalizer.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferFinalizerTests.swift app/Keraunos/Keraunos/Transfer/BackgroundTransferService.swift app/Keraunos/Keraunos/Transfer/TransferEngine.swift
git commit -m "feat(transfer): live byte progress delegate + shared progress bus wiring"
```

---

# SLICE B — Queue UI, row states, IA refactor, Library toast

### Task B1: `.paused` state + coordinator pause/resume

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift`
- Modify: `app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift`

**Rationale:** `JobState` has no paused case today; the row catalog and per-row actions require one. Pause = cancel the in-flight task and mark `.paused` (bounded waste of ≤ 1 chunk, exactly the spec's allowance); resume = `.downloading` + `beginTrack` from `bytesWritten`/`resumeData`. `reassociateAndResume` must **not** auto-resume a `.paused` job.

**Interfaces:**
- Produces:
  - `JobState.paused` (Codable/Equatable — an added enum case).
  - `TransferCoordinator.pause(jobID: UUID) async` and `resume(jobID: UUID) async throws`.

- [ ] **Step 1: Write failing tests** (append to `TransferCoordinatorTests`)

```swift
    @Test func pauseCancelsInFlightAndMarksPaused() async throws {
        let store = try makeStore()
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: 1_048_576,
                                              bytesWritten: 0, totalBytes: 4_194_304)),
                    state: .downloading)
        try await store.upsert(j)
        try await coord.start(j)
        let taskID = await session.started.last!.id
        await coord.pause(jobID: j.id)
        #expect(await session.cancelled.contains(taskID))
        #expect(await store.job(id: j.id)?.state == .paused)
    }

    @Test func resumeReturnsToDownloadingAndStartsTask() async throws {
        let store = try makeStore()
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: 1_048_576,
                                              bytesWritten: 1_048_576, totalBytes: 4_194_304)),
                    state: .paused)
        try await store.upsert(j)
        try await coord.resume(jobID: j.id)
        #expect(await store.job(id: j.id)?.state == .downloading)
        #expect(await session.started.last?.request.value(forHTTPHeaderField: "Range") == "bytes=1048576-2097151")
    }

    @Test func reassociateDoesNotResumePausedJobs() async throws {
        let store = try makeStore()
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil,
                                              bytesWritten: 10, totalBytes: 100)),
                    state: .paused)
        try await store.upsert(j)
        await coord.reassociateAndResume()
        #expect(await session.started.isEmpty)
        #expect(await store.job(id: j.id)?.state == .paused)
    }
```

- [ ] **Step 2: Run it, verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferCoordinatorTests`
Expected: FAIL — `type 'JobState' has no member 'paused'` and `no member 'pause'`.

- [ ] **Step 3: Implement**

In `TransferJob.swift`, add the case to `JobState`:

```swift
    case queued
    case downloading
    case paused
    case needsRefresh
    ...
```

In `TransferCoordinator.swift`, add to `// MARK: - Control`:

```swift
    /// Pauses a downloading job: cancels the in-flight task (chunked resumes cleanly from the
    /// persisted `bytesWritten`; single-shot keeps the returned resume data) and marks it
    /// `.paused` so `reassociateAndResume` won't auto-kick it. Bounded waste: at most one chunk.
    public func pause(jobID: UUID) async {
        guard let job = await store.job(id: jobID), job.state == .downloading,
              let index = Self.firstIncompleteTrackIndex(job) else { return }
        let track = job.tracks[index]
        var resume: Data? = nil
        if let tid = track.taskIdentifier {
            resume = await session.cancelTask(tid)
            owners[tid] = nil
        }
        await persist(jobID, "pause") {
            Self.mutateTrack(&$0, at: index) { $0.resumeData = resume; $0.taskIdentifier = nil }
            $0.state = .paused
        }
        await publish(jobID)
    }

    /// Resumes a paused job from its persisted offset (chunked) or resume data (single-shot).
    public func resume(jobID: UUID) async throws {
        guard let job = await store.job(id: jobID), job.state == .paused,
              let index = Self.firstIncompleteTrackIndex(job) else { return }
        try await store.update(id: jobID) { $0.state = .downloading }
        try await beginTrack(jobID: jobID, trackIndex: index)
        await publish(jobID)
    }
```

The `reassociateAndResume` loop already guards `where job.state == .downloading`, so `.paused` jobs are skipped automatically — no change needed there. Confirm that guard is intact.

- [ ] **Step 4: Run it, verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferCoordinatorTests` → PASS. Then full suite `swift test --package-path app/KeraunosCore` → PASS (the added enum case is exhaustive-switch-safe: check `TransferFinalizer`/`TransferCoordinator` switches on `JobState` still compile — they switch on specific cases with no `default` only where noted; add cases if a switch breaks).

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift
git commit -m "feat(transfer): .paused state + coordinator pause/resume"
```

---

### Task B2: `TransferRowState` mapping (pure)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/TransferRowState.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferRowStateTests.swift`

**Interfaces:**
- Produces:
  - `public enum TransferRowState: Sendable, Equatable { case downloading, paused, queued, waitingBackground, merging, refreshing, needsSignIn, failed(FailureReason) }`
  - `public extension TransferJob { var rowState: TransferRowState? }` — nil for `.completed`/`.cancelled` (hidden from the queue).

**Mapping (1:1 with the spec's catalog):**
- `.queued` → `.queued`
- `.downloading` → current incomplete track's `taskIdentifier == nil` ? `.waitingBackground` : `.downloading`
- `.paused` → `.paused`
- `.needsRefresh` → `credentialRef == nil` ? `.refreshing` : `.needsSignIn`
- `.readyToMerge`, `.merging` → `.merging`
- `.failed(reason)` → `.failed(reason)`
- `.completed`, `.cancelled` → `nil`

- [ ] **Step 1: Write the failing test**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/TransferRowStateTests.swift`:

```swift
import Testing
import Foundation
@testable import KeraunosCore

@Suite struct TransferRowStateTests {
    private func track(taskID: Int? = nil, bytes: Int64 = 0, total: Int64? = 100) -> TrackJob {
        TrackJob(remoteURL: URL(string: "https://ex/x")!, urlExpiresAt: nil, chunkSize: nil,
                 partFileName: "x.part", bytesWritten: bytes, totalBytes: total,
                 resumeData: nil, taskIdentifier: taskID)
    }
    private func job(state: JobState, credentialRef: String? = nil,
                     track t: TrackJob? = nil) -> TransferJob {
        TransferJob(id: UUID(), sourcePageURL: URL(string: "https://ex")!,
                    formatSelection: FormatSelection(formatID: "22", height: 720, isAdaptive: false),
                    credentialRef: credentialRef, createdAt: Date(), state: state,
                    kind: .progressive(t ?? track()), suggestedFilename: "v.mp4",
                    savedFilename: nil, autoSaveToPhotos: false)
    }

    @Test func queuedMapsToQueued() { #expect(job(state: .queued).rowState == .queued) }

    @Test func downloadingWithLiveTaskIsDownloading() {
        #expect(job(state: .downloading, track: track(taskID: 7)).rowState == .downloading)
    }

    @Test func downloadingWithNoTaskIsWaitingBackground() {
        #expect(job(state: .downloading, track: track(taskID: nil)).rowState == .waitingBackground)
    }

    @Test func pausedMapsToPaused() { #expect(job(state: .paused).rowState == .paused) }

    @Test func needsRefreshAnonymousIsRefreshing() {
        #expect(job(state: .needsRefresh, credentialRef: nil).rowState == .refreshing)
    }

    @Test func needsRefreshAuthenticatedIsNeedsSignIn() {
        #expect(job(state: .needsRefresh, credentialRef: "kc://x").rowState == .needsSignIn)
    }

    @Test func readyToMergeAndMergingBothMerging() {
        #expect(job(state: .readyToMerge).rowState == .merging)
        #expect(job(state: .merging).rowState == .merging)
    }

    @Test func failedCarriesReason() {
        #expect(job(state: .failed(.insufficientSpace)).rowState == .failed(.insufficientSpace))
        #expect(job(state: .failed(.network)).rowState == .failed(.network))
    }

    @Test func completedAndCancelledAreHidden() {
        #expect(job(state: .completed).rowState == nil)
        #expect(job(state: .cancelled).rowState == nil)
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferRowStateTests`
Expected: FAIL — `cannot find 'TransferRowState'` / no member `rowState`.

- [ ] **Step 3: Implement**

Create `app/KeraunosCore/Sources/KeraunosCore/TransferRowState.swift`:

```swift
import Foundation

/// The nine presentation states of a queue row (from the design's `TransferStates.dc.html`),
/// derived purely from a `TransferJob`. Kept in Core (no SwiftUI) so the mapping is
/// `swift test`-able and stays the single source of truth for JobState → row.
public enum TransferRowState: Sendable, Equatable {
    case downloading         // active, receiving bytes
    case paused              // user-paused
    case queued              // waiting its turn
    case waitingBackground   // .downloading but no in-flight task (iOS-deferred / between resumes)
    case merging             // readyToMerge or merging — automatic
    case refreshing          // .needsRefresh, anonymous — silent re-extraction, automatic
    case needsSignIn         // .needsRefresh, credentialed — needs foreground re-auth
    case failed(FailureReason)
}

public extension TransferJob {
    /// The row this job renders as, or nil if it should not appear in the queue
    /// (`.completed`/`.cancelled` move to Library / disappear).
    var rowState: TransferRowState? {
        switch state {
        case .queued:
            return .queued
        case .downloading:
            let hasLiveTask = tracks.first(where: { track in
                guard let total = track.totalBytes else { return true }
                return track.bytesWritten < total
            })?.taskIdentifier != nil
            return hasLiveTask ? .downloading : .waitingBackground
        case .paused:
            return .paused
        case .needsRefresh:
            return credentialRef == nil ? .refreshing : .needsSignIn
        case .readyToMerge, .merging:
            return .merging
        case .failed(let reason):
            return .failed(reason)
        case .completed, .cancelled:
            return nil
        }
    }
}
```

- [ ] **Step 4: Run it, verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferRowStateTests` → PASS (10 tests). Full suite → PASS.

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferRowState.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferRowStateTests.swift
git commit -m "feat(transfer): pure TransferJob.rowState mapping"
```

---

### Task B3: `DownloadsViewModel` (queue merge + actions + toast) and engine action API

**Files:**
- Modify: `app/Keraunos/Keraunos/Transfer/TransferEngine.swift`
- Create: `app/Keraunos/Keraunos/UI/DownloadsViewModel.swift`

**Interfaces:**
- Consumes: `TransferEngine.shared` (store, coordinator, progress, finalizer), `TransferJob.rowState`, `ProgressSnapshot`.
- Produces:
  - `TransferEngine` action API: `func enqueue(_ job: TransferJob) async`, `func pause(_ id: UUID) async`, `func resume(_ id: UUID) async`, `func cancel(_ id: UUID) async`, `func retry(_ id: UUID) async`, `func remove(_ id: UUID) async`, and `var activeCount: Int` derivation is done in the VM (not the engine).
  - `struct QueueItem: Identifiable` (app target): `id`, `title`, `sourceHost`, `qualityLabel`, `rowState: TransferRowState`, `fraction: Double?`, `receivedBytes`, `totalBytes`.
  - `@MainActor @Observable final class DownloadsViewModel` exposing `private(set) var items: [QueueItem]`, `var activeCount: Int`, action methods, and `savedToLibraryToast: ToastData?`-style output for the coalescing toast.

- [ ] **Step 1: Add the engine action + cancel/retry/remove API**

In `TransferEngine.swift`, add (cancel produces resume data via the coordinator's pause path repurposed, or a dedicated cancel):

```swift
    // MARK: - Queue actions (Phase 6)

    /// Enqueues a freshly built job and starts its first track.
    func enqueue(_ job: TransferJob) async {
        do {
            try await coordinator.start(job)
        } catch {
            diagnostics.record(kind: "transfer_enqueue_failed", detail: "job \(job.id): \(error)")
        }
    }

    func pause(_ id: UUID) async { await coordinator.pause(jobID: id) }

    func resume(_ id: UUID) async {
        do { try await coordinator.resume(jobID: id) }
        catch { diagnostics.record(kind: "transfer_resume_failed", detail: "job \(id): \(error)") }
    }

    /// Cancels a job: marks `.cancelled`, cancels any in-flight task, drops it from the store
    /// (which deletes its part files). Terminal — the row disappears.
    func cancel(_ id: UUID) async {
        await coordinator.pause(jobID: id)          // stop the in-flight task first (bounded)
        await removeFromStoreAndBus(id)
    }

    /// Retry a failed job: reset the failed track offset conservatively and re-drive.
    func retry(_ id: UUID) async {
        do {
            try await store.update(id: id) { $0.state = .downloading }
            await coordinator.reassociateAndResume()
        } catch {
            diagnostics.record(kind: "transfer_retry_failed", detail: "job \(id): \(error)")
        }
    }

    /// Dismiss a terminal (failed/completed) row.
    func remove(_ id: UUID) async { await removeFromStoreAndBus(id) }

    private func removeFromStoreAndBus(id: UUID) async {
        do { try await store.remove(id: id) }
        catch { diagnostics.record(kind: "transfer_remove_failed", detail: "job \(id): \(error)") }
        await progress.remove(id)
    }
```

> **Design note for the executor:** `cancel`'s reuse of `pause` (cancel-in-flight) then store removal is deliberate — it avoids a second cancel API on the coordinator. If a device spike shows retry needs to truncate the part to `bytesWritten` first, revisit `retry`; for now `reassociateAndResume` re-kicks from the persisted offset.

- [ ] **Step 2: Make the finalize pass prune + announce completions**

In `runFinalizePass()`, after a job saves successfully, record its title for the toast and remove it from the store so it does not linger in the queue. Add a `@MainActor` observable announcer field on `TransferEngine`:

```swift
    /// Titles of jobs that landed in Library since the UI last consumed them (drives the
    /// coalescing "Saved to Library" toast). The VM reads and clears this.
    private(set) var recentlySavedTitles: [String] = []

    func consumeRecentlySaved() -> [String] {
        let titles = recentlySavedTitles
        recentlySavedTitles = []
        return titles
    }
```

In the `for id in completed` loop of `runFinalizePass`, after the Photos block:

```swift
            if let name = await store.job(id: id)?.savedFilename {
                recentlySavedTitles.append((name as NSString).deletingPathExtension)
            }
            await removeFromStoreAndBus(id)
```

- [ ] **Step 3: Write the view model**

Create `app/Keraunos/Keraunos/UI/DownloadsViewModel.swift`:

```swift
import Foundation
import Observation
import KeraunosCore

/// One queue row's display payload — the durable job's identity/quality plus the live
/// progress snapshot, flattened for SwiftUI.
struct QueueItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let sourceHost: String?
    let qualityLabel: String
    let rowState: TransferRowState
    let fraction: Double?
    let receivedBytes: Int64
    let totalBytes: Int64?
}

/// The Download tab's live queue. Reconstructs rows from the persisted `TransferJobStore`
/// (identity + row *variant*) merged with the `TransferProgress` bus (live fraction/bytes),
/// so it reconnects after relaunch. Ordered active → queued → attention, per the spec.
@MainActor
@Observable
final class DownloadsViewModel {
    private(set) var items: [QueueItem] = []

    private let engine: TransferEngine
    private var streamTask: Task<Void, Never>?

    /// Ordering rank: active (downloading/waiting/merging/refreshing) → paused/queued → attention.
    private static func rank(_ s: TransferRowState) -> Int {
        switch s {
        case .downloading, .waitingBackground, .merging, .refreshing: return 0
        case .paused, .queued:                                        return 1
        case .needsSignIn, .failed:                                   return 2
        }
    }

    init(engine: TransferEngine = .shared) {
        self.engine = engine
    }

    var activeCount: Int {
        items.filter { Self.rank($0.rowState) == 0 || $0.rowState == .paused || $0.rowState == .queued }.count
    }

    /// Subscribes to the progress bus; every emission triggers a full rebuild from the store
    /// (tiny) so state transitions the bus reflects are picked up. Call from `.task`.
    func start() {
        streamTask?.cancel()
        streamTask = Task { [engine] in
            for await snapshots in await engine.progress.updates() {
                await self.rebuild(snapshots: snapshots)
            }
        }
    }

    func stop() { streamTask?.cancel(); streamTask = nil }

    /// Rebuilds `items` from persisted jobs (source of row variant + identity) and the live
    /// snapshot map (fraction/bytes). Also fires the "Saved to Library" toast for jobs the
    /// engine has just moved to Library.
    func rebuild(snapshots: [UUID: ProgressSnapshot]) async {
        let jobs = await engine.store.all()
        let rows: [QueueItem] = jobs.compactMap { job in
            guard let rowState = job.rowState else { return nil }
            let snap = snapshots[job.id]
            return QueueItem(
                id: job.id,
                title: (job.suggestedFilename as NSString).deletingPathExtension,
                sourceHost: job.sourcePageURL.host,
                qualityLabel: Self.qualityLabel(job.formatSelection),
                rowState: rowState,
                fraction: snap?.fraction,
                receivedBytes: snap?.receivedBytes ?? job.tracks.reduce(0) { $0 + $1.bytesWritten },
                totalBytes: snap?.totalBytes)
        }
        items = rows.sorted {
            let (a, b) = (Self.rank($0.rowState), Self.rank($1.rowState))
            return a != b ? a < b : $0.id.uuidString < $1.id.uuidString
        }
        savedTitles = engine.consumeRecentlySaved()   // consumed by the view's onChange
    }

    /// Set to the newly-saved titles on each rebuild; the screen coalesces these into a toast.
    private(set) var savedTitles: [String] = []

    static func qualityLabel(_ f: FormatSelection) -> String {
        f.height.map { "\($0)p" } ?? (f.isAdaptive ? "Adaptive" : "Video")
    }

    // MARK: Actions
    func pause(_ id: UUID)  { Task { await engine.pause(id) } }
    func resume(_ id: UUID) { Task { await engine.resume(id) } }
    func cancel(_ id: UUID) { Task { await engine.cancel(id) } }
    func retry(_ id: UUID)  { Task { await engine.retry(id) } }
    func dismiss(_ id: UUID){ Task { await engine.remove(id) } }
}
```

> Make `TransferEngine.store` and `progress` accessible to the VM — they are already `let` on the `@MainActor` class; if they are not `internal`-visible, leave them as-is (same module). `recentlySavedTitles`/`consumeRecentlySaved` are `@MainActor`, matching the engine.

- [ ] **Step 4: Build the app, verify it compiles**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/Transfer/TransferEngine.swift app/Keraunos/Keraunos/UI/DownloadsViewModel.swift
git commit -m "feat(transfer): DownloadsViewModel + engine queue-action API"
```

---

### Task B4: `TransferQueueRow` view (nine states)

**Files:**
- Create: `app/Keraunos/Keraunos/Components/TransferQueueRow.swift`

**Interfaces:**
- Consumes: `QueueItem`, `TransferRowState`, design components (`ProgressBar`, `NoticeCard`, `Thumbnail`), tokens.
- Produces: `struct TransferQueueRow: View` taking a `QueueItem` and per-action closures (`onPause`, `onResume`, `onCancel`, `onRetry`, `onSignIn`, `onManageStorage`, `onDismiss`).

- [ ] **Step 1: Write the view** (complete, matches the row-state catalog and existing card idiom)

Create `app/Keraunos/Keraunos/Components/TransferQueueRow.swift`:

```swift
import SwiftUI
import KeraunosCore

/// One queue row. The header (thumbnail + title + source·quality) is shared; the body and
/// actions switch on the nine `TransferRowState`s from the design's `TransferStates.dc.html`.
/// Terminal rows put their primary recovery inline (Retry / Sign in / Manage storage).
struct TransferQueueRow: View {
    let item: QueueItem
    var onPause: () -> Void = {}
    var onResume: () -> Void = {}
    var onCancel: () -> Void = {}
    var onRetry: () -> Void = {}
    var onSignIn: () -> Void = {}
    var onManageStorage: () -> Void = {}
    var onDismiss: () -> Void = {}

    var body: some View {
        switch item.rowState {
        case .failed(let reason): failedCard(reason)
        case .needsSignIn:        signInCard
        default:                  standardCard
        }
    }

    // MARK: Active / paused / queued / waiting / merging / refreshing

    private var standardCard: some View {
        VStack(spacing: Space.md) {
            HStack(spacing: Space.md) {
                Thumbnail(size: CGSize(width: 50, height: 50), cornerRadius: 10)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.Theme.bodyStrong).foregroundStyle(Color.Theme.text1).lineLimit(1)
                    Text(subtitle).font(.Theme.caption).foregroundStyle(Color.Theme.text3).lineLimit(1)
                }
                Spacer(minLength: Space.sm)
                trailingControls
            }
            if showsBar { bar }
            statusLine
        }
        .card()
    }

    private var subtitle: String {
        [item.sourceHost, item.qualityLabel].compactMap { $0 }.joined(separator: " · ")
    }

    /// Determinate bar for downloading/paused; indeterminate for waiting/merging/refreshing.
    private var showsBar: Bool {
        switch item.rowState {
        case .downloading, .paused, .waitingBackground, .merging, .refreshing: return true
        case .queued, .needsSignIn, .failed: return false
        }
    }

    @ViewBuilder private var bar: some View {
        if let fraction = item.fraction, item.rowState == .downloading || item.rowState == .paused {
            ProgressBar(value: fraction)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(fraction * 100)) percent")
        } else {
            IndeterminateBar()   // waiting/merging/refreshing, or size not yet known
        }
    }

    @ViewBuilder private var statusLine: some View {
        HStack {
            Text(statusText).font(.Theme.figure).tabularNumbers().foregroundStyle(statusColor)
            Spacer()
        }
    }

    private var statusText: String {
        switch item.rowState {
        case .downloading:
            if let f = item.fraction { return "\(Int(f * 100))%" }
            return "Downloading…"
        case .paused:
            return item.fraction.map { "Paused · \(Int($0 * 100))%" } ?? "Paused"
        case .queued:             return "◷ Queued · \(item.qualityLabel)"
        case .waitingBackground:  return "Waiting to resume…"
        case .merging:            return "Merging video + audio…"
        case .refreshing:         return "Refreshing link…"
        case .needsSignIn, .failed: return ""
        }
    }

    private var statusColor: Color {
        item.rowState == .downloading ? Color.Theme.accent : Color.Theme.text3
    }

    @ViewBuilder private var trailingControls: some View {
        switch item.rowState {
        case .downloading:
            iconButton("pause.fill", action: onPause)
            iconButton("xmark", action: onCancel)
        case .paused:
            iconButton("play.fill", action: onResume)
            iconButton("xmark", action: onCancel)
        case .queued:
            iconButton("xmark", action: onCancel)
        case .waitingBackground:
            iconButton("xmark", action: onCancel)
        case .merging, .refreshing, .needsSignIn, .failed:
            EmptyView()   // automatic or handled by the notice card
        }
    }

    private func iconButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.Theme.text2)
                .frame(width: 34, height: 34)
                .background(Color.Theme.surface2, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Needs sign-in

    private var signInCard: some View {
        NoticeCard(tone: .warning, title: "Sign in to continue",
                   message: "\(item.title) needs you to sign in to \(item.sourceHost ?? "this site").",
                   primaryTitle: "Sign in to \(item.sourceHost ?? "site")", primaryAction: onSignIn,
                   secondaryTitle: "Remove", secondaryAction: onDismiss)
    }

    // MARK: Failed (network / no-space / other)

    private func failedCard(_ reason: FailureReason) -> some View {
        let (title, message, primaryTitle, primaryAction): (String, String, String, () -> Void) = {
            switch reason {
            case .insufficientSpace:
                return ("Not enough storage",
                        "\(item.title) needs more space than is available.",
                        "Manage storage", onManageStorage)
            case .network:
                return ("Couldn’t finish — network", "\(item.title) stopped downloading.", "Retry", onRetry)
            case .refreshFailed:
                return ("Couldn’t refresh link", "The download link for \(item.title) expired and couldn’t be renewed.", "Retry", onRetry)
            case .integrityCheckFailed:
                return ("File check failed", "The downloaded data for \(item.title) was incomplete.", "Retry", onRetry)
            }
        }()
        return NoticeCard(tone: .error, title: title, message: message,
                          primaryTitle: primaryTitle, primaryAction: primaryAction,
                          secondaryTitle: "Dismiss", secondaryAction: onDismiss)
    }
}

/// An indeterminate progress bar matching `ProgressBar`'s track, for waiting/merging/refreshing.
private struct IndeterminateBar: View {
    @State private var phase: CGFloat = 0
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.Theme.surface2)
                Capsule().fill(Color.Theme.accent)
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: (geo.size.width * 1.35) * phase - geo.size.width * 0.35)
            }
        }
        .frame(height: 7)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}
```

> `TransferRowState` is `Equatable`, so the `== .downloading` comparisons compile. `NoticeCard`'s `secondaryTitle`/`secondaryAction` (ghost link) is reused for "Remove"/"Dismiss" per `NoticeCard.swift:47`.

- [ ] **Step 2: Build the app, verify it compiles**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add app/Keraunos/Keraunos/Components/TransferQueueRow.swift
git commit -m "feat(transfer): TransferQueueRow view for all nine states"
```

---

### Task B5: Download-tab queue + IA refactor (remove Recent, add badge) + Library toast

**Files:**
- Modify: `app/Keraunos/Keraunos/UI/HomeScreen.swift`
- Modify: `app/Keraunos/Keraunos/UI/AppShell.swift`

**Interfaces:**
- Consumes: `DownloadsViewModel`, `TransferQueueRow`, `ToastCenter`.
- Produces: `HomeScreen` renders the hero + live queue (no more "Recent"/inline card); `AppShell` shows an active-count badge on the Download tab item and iPad sidebar item and owns a `DownloadsViewModel`.

- [ ] **Step 1: Own the queue VM in `AppShell` and pass it + badge count**

In `AppShell.swift`, add:

```swift
    @State private var downloads = DownloadsViewModel()
```

Pass `downloads` into both `HomeScreen(...)` call sites. Add the badge to the Download `tabItem` (compact) and the sidebar `navItem` (regular). For the tab bar:

```swift
            HomeScreen(model: model, downloads: downloads, cookieStore: cookieStore,
                       selection: $selection, onSettings: { showSettings = true })
                .tabItem { Label(AppSection.download.title, systemImage: AppSection.download.symbol) }
                .badge(downloads.activeCount == 0 ? 0 : downloads.activeCount)
                .tag(AppSection.download)
```

(`.badge(0)` renders nothing, so no conditional needed — but keep it explicit for clarity.) For the iPad sidebar `navItem(.download)`, overlay a small count pill when `selection`-independent `downloads.activeCount > 0`; pass `activeCount` into `SidebarView`.

- [ ] **Step 2: Rework `HomeScreen` — a `List` of hero + queue, drop Recent/inline card**

**Rendering container: `List`, not `ScrollView`/`VStack`.** The queue is an unbounded, growing collection, so it must render lazily and recycle rows — a plain `VStack` inflates every row eagerly and can't host `swipeActions`. Convert the whole Download screen body to a single `List`: the header, hero, resolving/error affordances, and the queue all become list rows, so everything is lazy and terminal rows get native swipe-to-dismiss. Style it to disappear into the theme (no default list chrome).

In `HomeScreen.swift`:
- Add `let downloads: DownloadsViewModel` to the struct's stored properties.
- Replace the `ScrollView { VStack { … } }` body with a themed `List` (below).
- Delete `recentList`, `libraryPreviewGrid`, `recent`, `recentRow`, `contentSection`, and `downloadingSection` (the single inline card). The Download tab no longer previews Library (Library is the sole archive).
- Drive the VM lifecycle with `.task { downloads.start() }`.

Body — a plain, theme-backed `List`. Each non-queue element is a chrome-free row (`.listRowSeparator(.hidden)`, `.listRowBackground(Color.clear)`, explicit insets); the queue rows carry the swipe action:

```swift
    var body: some View {
        List {
            headerRow
            heroCard.plainQueueRow()
            if model.isWorking, let status = model.statusText {
                resolvingRow(status).plainQueueRow()
            }
            if let error = model.errorMessage {
                errorNotice(error).plainQueueRow()
            }
            queueRows
        }
        .listStyle(.plain)
        .environment(\.defaultMinListRowHeight, 0)
        .scrollContentBackground(.hidden)
        .background(Color.Theme.bg.ignoresSafeArea())
        .onOpenURL { model.openIncoming($0) }
        .qualityPicker(model: model)
        .loginSheet(model: model, cookieStore: cookieStore, showLogin: $showLogin, loginStatus: $loginStatus)
        .task { downloads.start() }
        .onChange(of: downloads.savedTitles) { _, titles in
            guard !titles.isEmpty else { return }
            if titles.count == 1 {
                toasts.show(ToastData(icon: "checkmark", title: "Saved to Library",
                                      subtitle: titles[0], actionTitle: "Show",
                                      action: { selection = .library }))
            } else {
                toasts.show(ToastData(icon: "checkmark",
                                      title: "\(titles.count) videos saved to Library",
                                      actionTitle: "Show", action: { selection = .library }))
            }
        }
    }

    @ViewBuilder private var headerRow: some View {
        Group {
            if isRegular { PaneTitle(title: "Download") }
            else { CompactHeader(title: "Keraunos", brand: true, onSettings: onSettings) }
        }
        .plainQueueRow()
    }

    // MARK: - Queue

    @ViewBuilder private var queueRows: some View {
        if downloads.items.isEmpty {
            EmptyStateView(symbol: "arrow.down.to.line",
                           title: "No active downloads",
                           message: "Paste a link above to start. Finished videos move straight to your Library.")
                .frame(maxWidth: .infinity)
                .padding(.top, Space.xl)
                .plainQueueRow()
        } else {
            SectionHeader("Transfers").plainQueueRow()
            ForEach(downloads.items) { item in
                TransferQueueRow(
                    item: item,
                    onPause:  { downloads.pause(item.id) },
                    onResume: { downloads.resume(item.id) },
                    onCancel: { downloads.cancel(item.id) },
                    onRetry:  { downloads.retry(item.id) },
                    onSignIn: { showLogin = true },
                    onManageStorage: { onSettings?() ?? (selection = .settings) },
                    onDismiss: { downloads.dismiss(item.id) })
                .plainQueueRow()
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if isTerminal(item.rowState) {
                        Button(role: .destructive) { downloads.dismiss(item.id) } label: {
                            Label("Remove", systemImage: "xmark")
                        }
                    }
                }
            }
        }
    }

    private func isTerminal(_ s: TransferRowState) -> Bool {
        if case .failed = s { return true }
        return s == .needsSignIn
    }

    private func resolvingRow(_ status: String) -> some View {
        HStack(spacing: Space.sm) {
            ProgressView().tint(Color.Theme.accent)
            Text(status).font(.Theme.caption).foregroundStyle(Color.Theme.text3)
            Spacer()
            Button("Cancel") { model.cancel() }.buttonStyle(.ghost)
        }
        .card(padding: 14)
    }
```

> `heroCard` and `errorNotice(_:)` are the existing helpers — keep them (Slice C refines the hero). The old `.quickLookPreview`/`.deleteConfirmation`/`.saveMessageToast`/`onChange(of: model.lastSavedName)` modifiers were for the removed "Recent" list — delete them from `HomeScreen`; the queue + the Library-save toast above replace that path. `saveMessageToast` stays on `LibraryScreen` (its Save-to-Photos actions).

> **Coalescing note:** `ToastCenter.show` already replaces the current toast (single, never a stack) and auto-dismisses (~2.8 s). `savedTitles` is the batch consumed on one rebuild, so simultaneous completions in a single finalize pass arrive as one `titles` array → the count branch fires directly. Sequential completions across passes replace the pill; this satisfies "never a stack" and the count-up intent per pass. A cross-pass running counter is a deferred refinement.

- [ ] **Step 3: Add the `plainQueueRow()` row-style helper**

Add a small `View` extension (in `HomeScreen.swift` or a shared file) that strips every element of default list chrome and applies the shared horizontal inset — so the `List` looks identical to the old card stack while staying lazy:

```swift
private extension View {
    /// Chrome-free list row on the theme background with the screen's horizontal inset —
    /// makes a `List` render like a stack of cards while keeping lazy row recycling.
    func plainQueueRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: Space.xs, leading: 20, bottom: Space.xs, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
```

> Native swipe-to-dismiss now works because the rows live in a `List` (spec: "swipe-to-dismiss (or a context-menu 'Remove')"). The `NoticeCard`'s inline "Dismiss"/"Remove" from B4 remains as the discoverable, non-swipe affordance — the two are complementary, not redundant.

- [ ] **Step 4: iPad single reading column**

Per the spec, cap the queue at a **~720 pt single reading column**, left-aligned. With a `List`, constrain each row's *content* rather than the list: change `plainQueueRow()` to accept the size class and cap width when regular —

```swift
    func plainQueueRow(maxWidth: CGFloat = .infinity) -> some View {
        self
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .listRowInsets(EdgeInsets(top: Space.xs, leading: 20, bottom: Space.xs, trailing: 20))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
```

and pass `maxWidth: isRegular ? 720 : .infinity` at each `.plainQueueRow(...)` call site (or read the size class inside via an `@Environment` wrapper). Same flat active → queued → attention order and identical row states as iPhone — no grid, no detail pane.

- [ ] **Step 5: Build the app, verify it compiles**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `BUILD SUCCEEDED`. Fix any references to the deleted `recentList`/`downloadingSection`.

- [ ] **Step 6: Commit**

```bash
git add app/Keraunos/Keraunos/UI/HomeScreen.swift app/Keraunos/Keraunos/UI/AppShell.swift
git commit -m "feat(transfer): Download-tab live queue, active-count badge, Library toast; drop Recent"
```

---

# SLICE C — Enqueue-first start flow

### Task C1: `TransferJobFactory` (ResolvedMedia → TransferJob)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/TransferJobFactory.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobFactoryTests.swift`

**Interfaces:**
- Consumes: `ResolvedMedia`, `MediaTrack`, `FormatSelection`.
- Produces:
  - `public enum TransferJobFactory { public static func make(id: UUID, from media: ResolvedMedia, sourcePageURL: URL, selection: FormatSelection, autoSaveToPhotos: Bool, credentialRef: String?, createdAt: Date, partPrefix: String) -> TransferJob }`
  - Maps `MediaTrack.httpHeaders` → `TrackJob.requestHeaders`, `MediaTrack.chunkSize` → `TrackJob.chunkSize`, `.url` → `remoteURL`; deterministic part-file names `"<partPrefix>-video.part"`/`"-audio.part"`/`"-media.part"`; state `.queued`; `bytesWritten = 0`, `totalBytes = nil`, no task/resume yet.

- [ ] **Step 1: Write the failing test**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobFactoryTests.swift`:

```swift
import Testing
import Foundation
@testable import KeraunosCore

@Suite struct TransferJobFactoryTests {
    private let page = URL(string: "https://site.example/watch?v=1")!
    private let sel = FormatSelection(formatID: "22", height: 720, isAdaptive: false)

    private func track(_ url: String, headers: [String: String] = ["User-Agent": "yt"], chunk: Int? = nil) -> MediaTrack {
        MediaTrack(url: URL(string: url)!, httpHeaders: headers, codec: "h264", fileExtension: "mp4", chunkSize: chunk)
    }

    @Test func progressiveCarriesHeadersAndChunkAndName() {
        let media = ResolvedMedia(kind: .progressive(track("https://cdn/v.mp4", chunk: 1_048_576)),
                                  title: "T", suggestedFilename: "T.mp4")
        let id = UUID()
        let job = TransferJobFactory.make(id: id, from: media, sourcePageURL: page, selection: sel,
                                          autoSaveToPhotos: true, credentialRef: nil,
                                          createdAt: Date(), partPrefix: id.uuidString)
        guard case .progressive(let t) = job.kind else { Issue.record("expected progressive"); return }
        #expect(job.state == .queued)
        #expect(job.autoSaveToPhotos == true)
        #expect(t.requestHeaders["User-Agent"] == "yt")
        #expect(t.chunkSize == 1_048_576)
        #expect(t.partFileName == "\(id.uuidString)-media.part")
        #expect(t.bytesWritten == 0)
        #expect(t.totalBytes == nil)
    }

    @Test func adaptiveMakesTwoNamedTracks() {
        let media = ResolvedMedia(kind: .adaptive(video: track("https://cdn/v.m4s", chunk: 2),
                                                  audio: track("https://cdn/a.m4s")),
                                  title: "T", suggestedFilename: "T.mp4")
        let id = UUID()
        let job = TransferJobFactory.make(id: id, from: media, sourcePageURL: page, selection: sel,
                                          autoSaveToPhotos: false, credentialRef: nil,
                                          createdAt: Date(), partPrefix: id.uuidString)
        guard case .adaptive(let v, let a) = job.kind else { Issue.record("expected adaptive"); return }
        #expect(v.partFileName == "\(id.uuidString)-video.part")
        #expect(a.partFileName == "\(id.uuidString)-audio.part")
        #expect(v.chunkSize == 2)
        #expect(a.chunkSize == nil)
    }
}
```

- [ ] **Step 2: Run it, verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferJobFactoryTests`
Expected: FAIL — `cannot find 'TransferJobFactory'`.

- [ ] **Step 3: Implement**

Create `app/KeraunosCore/Sources/KeraunosCore/TransferJobFactory.swift`:

```swift
import Foundation

/// Builds a durable `TransferJob` from a foreground extraction result. Pure and Core-side so
/// enqueue logic is `swift test`-able: it copies each `MediaTrack`'s replayable request
/// headers and chunk-size hint onto the persisted `TrackJob`, assigns deterministic part-file
/// NAMES (never absolute URLs), and starts the job `.queued` with a zero offset.
public enum TransferJobFactory {
    public static func make(id: UUID, from media: ResolvedMedia, sourcePageURL: URL,
                            selection: FormatSelection, autoSaveToPhotos: Bool,
                            credentialRef: String?, createdAt: Date, partPrefix: String) -> TransferJob {
        let kind: TransferJob.Kind
        switch media.kind {
        case .progressive(let t):
            kind = .progressive(trackJob(t, name: "\(partPrefix)-media.part"))
        case .adaptive(let v, let a):
            kind = .adaptive(video: trackJob(v, name: "\(partPrefix)-video.part"),
                             audio: trackJob(a, name: "\(partPrefix)-audio.part"))
        }
        return TransferJob(id: id, sourcePageURL: sourcePageURL, formatSelection: selection,
                           credentialRef: credentialRef, createdAt: createdAt, state: .queued,
                           kind: kind, suggestedFilename: media.suggestedFilename,
                           savedFilename: nil, autoSaveToPhotos: autoSaveToPhotos)
    }

    private static func trackJob(_ t: MediaTrack, name: String) -> TrackJob {
        TrackJob(remoteURL: t.url, urlExpiresAt: MediaURLExpiry.expiry(of: t.url),
                 chunkSize: t.chunkSize, partFileName: name, bytesWritten: 0, totalBytes: nil,
                 resumeData: nil, taskIdentifier: nil, requestHeaders: t.httpHeaders)
    }
}
```

> Uses `MediaURLExpiry.expiry(of:)` from Phase 5 to seed `urlExpiresAt` from a googlevideo `expire=` param. Confirm that API name against `MediaURLExpiry.swift`; if it differs (e.g. `parseExpiry(from:)`), call the actual one — do not invent.

- [ ] **Step 4: Run it, verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferJobFactoryTests` → PASS. Full suite → PASS.

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferJobFactory.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobFactoryTests.swift
git commit -m "feat(transfer): TransferJobFactory builds jobs from ResolvedMedia"
```

---

### Task C2: Switch start flow to enqueue; cancelable "Resolving…" hero

**Files:**
- Modify: `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`
- Modify: `app/Keraunos/Keraunos/UI/HomeScreen.swift`

**Interfaces:**
- Consumes: `TransferJobFactory`, `TransferEngine.shared.enqueue`, the existing extractor + quality-picker sheet.
- Produces: on resolve/pick, `DownloadViewModel` builds a `TransferJob` and calls `engine.enqueue(_:)` instead of running the foreground `assembler.assemble`; the hero shows a cancelable "Resolving…" state; the picker is unchanged; the chosen `FormatSelection` is persisted on the job.

**Design:** Keep `DownloadViewModel` as the paste/resolve/pick surface (it already runs `extractor.listFormats`/`resolve` and honors the "Highest" preference and picker). Change **only** the terminal action: instead of `assembleAndRecord(media)` (foreground download), map the `ResolvedMedia` (+ chosen `FormatOption`) into a `FormatSelection`, build a job via `TransferJobFactory`, and `enqueue`. The transfer, merge, Photos-save, and Library-landing are then owned by the engine + queue.

- [ ] **Step 1: Add a `FormatSelection` from the picked option and an enqueue path**

In `DownloadViewModel.swift`:
- Add `private let engine: TransferEngine` (default `.shared`) to `init`.
- Add a helper mapping the resolved media + chosen format to a `FormatSelection`. For the "Highest"/auto path, use `bestOption`; for the picker path, use the tapped `FormatOption`:

```swift
    private func selection(from option: FormatOption) -> FormatSelection {
        FormatSelection(formatID: option.formatID, height: option.height, isAdaptive: option.isAdaptive)
    }
```

- Replace the body of `assembleAndRecord(_:)` **usage** at the two call sites (`startDownload` `.ready`/auto-`best`, and `resolveSelected`) with an enqueue. Introduce:

```swift
    /// Enqueues a resolved media onto the background engine instead of downloading in the
    /// foreground. The job's FormatSelection is persisted so a `.needsRefresh` re-extraction
    /// re-picks the SAME format — the picker is never shown again.
    private func enqueue(_ media: ResolvedMedia, from url: URL, selection: FormatSelection) async {
        let id = UUID()
        let job = TransferJobFactory.make(
            id: id, from: media, sourcePageURL: url, selection: selection,
            autoSaveToPhotos: preferences.autoSaveToPhotos, credentialRef: nil,
            createdAt: Date(), partPrefix: id.uuidString)
        await engine.enqueue(job)
    }
```

Wire it:
- In `startDownload`, `.ready(let media)`: we need a `FormatSelection`. A `.ready` result has no `FormatOption`; synthesize one from the media (progressive → `isAdaptive:false`; adaptive → `true`; `formatID` unknown → use `""` and `height: nil`). Prefer: when `.ready`, build `FormatSelection(formatID: "", height: nil, isAdaptive: <media is adaptive>)`. (A single-format source never re-picks meaningfully.)
- In the auto-"Highest" branch (`extractor.resolve(url, option: best)`), after resolving: `await enqueue(media, from: url, selection: selection(from: best))`.
- In `resolveSelected(url:option:)`, after resolving: `await enqueue(media, from: url, selection: selection(from: option))`.

Remove/retire the foreground download side effects (`assembleAndRecord` → `assembler.assemble`, `lastSavedName`, `downloadProgress`) from the enqueue path. The `assembler`/`store`/`photoSaver` may become unused here; leave them if other code (Library) still needs `store.savedFiles()` via this VM — `LibraryScreen` reads `model.savedFiles`. **Keep `DownloadViewModel`'s Library-facing API intact**; only the *start* behavior changes.

- [ ] **Step 2: Cancelable "Resolving…" hero**

The VM already sets `statusText = "Resolving…"` and `isWorking = true` during extraction, and `cancel()` cancels `currentTask`. In `HomeScreen.heroCard`, show a resolving affordance when `model.isWorking` (before enqueue), with a Cancel:

```swift
            if model.isWorking, let status = model.statusText {
                HStack(spacing: Space.sm) {
                    ProgressView().tint(Color.Theme.accent)
                    Text(status).font(.Theme.caption).foregroundStyle(Color.Theme.text3)
                    Spacer()
                    Button("Cancel") { model.cancel() }.buttonStyle(.ghost)
                }
                .padding(.top, Space.xs)
            }
```

Because enqueue is near-instant (no foreground transfer), `isWorking` now spans only extraction/pick — exactly the spec's "Resolving…" window. On enqueue, the new row appears in the queue below.

- [ ] **Step 3: Build the app, verify it compiles**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Sanity-run existing app tests (no regressions in `DownloadViewModelTests`)**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' test -only-testing:KeraunosTests/DownloadViewModelTests`
Expected: PASS, or update the tests that asserted foreground-download side effects to assert enqueue instead (inject a stub engine — extract a small `enqueue` seam if the singleton is awkward to test; a `protocol JobEnqueuing { func enqueue(_:) async }` with `TransferEngine` conforming keeps the VM testable).

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/UI/DownloadViewModel.swift app/Keraunos/Keraunos/UI/HomeScreen.swift app/Keraunos/Keraunos/KeraunosTests 2>/dev/null; git add -A
git commit -m "feat(transfer): enqueue-first start flow + cancelable Resolving hero"
```

---

## Self-Review

**Spec coverage (§ "Progress plumbing", "UI / UX"):**
- `actor TransferProgress` holding `[JobID: ProgressSnapshot]`, written by coordinator + finalizer (state) and delegate (bytes), read via `AsyncStream` → A1, A2, A3, A4. ✔
- UI reconnects after relaunch (reconstructed from store + reassociation, no surviving closure) → VM rebuilds from `store.all()` + bus on every emission; coordinator's `reassociateAndResume` republishes → A3, B3. ✔
- `DownloadViewModel` single-shot `currentTask` retired in favor of the queue → C2 changes start behavior to enqueue; the queue owns transfer state. ✔ (The VM object remains as the paste/Library surface — its *transfer* role is retired, matching the spec's intent.)
- IA refactor: Download tab = hero + queue with active-count badge; Library = sole archive; Recent removed; completed auto-move with a self-dismissing toast; only failed/needs-sign-in/no-space persist → B5. ✔
- Flat list ordered active → queued → attention, one row/job → B3 `rank` + sort, B5 render. ✔
- Row state catalog (all 9) with bodies + actions → B2 mapping + B4 view. ✔
- Interaction: inline pause/resume + cancel; terminal rows inline recovery + native swipe-to-dismiss + inline "Dismiss"/"Remove"; refreshing/merging actionless → B4, B5. ✔ (The whole Download screen is a `List` — lazy row rendering + recycling for a growing queue, and `swipeActions` works natively.)
- Pause semantics (chunked: stop after chunk via cancel; single-shot: cancel w/ resumeData) → B1. ✔
- iPad single 720 pt reading column → B5 step 4. ✔
- "Saved to Library" toast (success-only, coalescing, "Show", placement) → B5. ⚠ Coalescing is per-finalize-pass batch, not a cross-pass running counter — flagged as a deferred refinement; single/count branches both implemented.
- Start flow: up-front resolve + pick, "Highest" auto, "Ask" picker, persisted `formatSelection`, cancelable "Resolving…", never re-show picker → C1, C2. ✔

**Placeholder scan:** No `TODO`/`TBD`/"handle errors appropriately". Two explicit *executor judgement* callouts (swipe-vs-inline dismiss; `MediaURLExpiry` API name) are flagged with the concrete fallback, not left open. ✔

**Type consistency:** `ProgressSnapshot(state:receivedBytes:totalBytes:)`, `TransferProgress.set/remove/updates/snapshot/current`, `TransferCoordinator.snapshot(for:liveReceived:)` (shared by finalizer), `taskDidWriteData(taskIdentifier:totalBytesWritten:totalBytesExpectedToWrite:)`, `pause(jobID:)`/`resume(jobID:)`, `TransferRowState` cases, `TransferJob.rowState`, `QueueItem`, `TransferJobFactory.make(id:from:sourcePageURL:selection:autoSaveToPhotos:credentialRef:createdAt:partPrefix:)` — names are used identically across tasks. ✔

**Known risks to watch during execution:**
- Adding `JobState.paused` may break exhaustive `switch`es in `TransferFinalizer`/`TransferCoordinator`/any UI — B1 step 4 checks the full build.
- `TransferEngine.store`/`progress` visibility to the VM (same module — should be fine as `let`).
- `.badge` on `tabItem` and the sidebar pill are the two badge surfaces (AppShell) — verify both update from `downloads.activeCount`.
