# Background Transfer — Phase 2: TransferSession seam & TransferCoordinator — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the event-driven transfer engine — a `TransferSession` protocol seam plus a `TransferCoordinator` actor that drives single-shot and sequential-chunked track downloads to completion, resumes vanished tasks from `bytesWritten`/resume-data, and reassociates live tasks on relaunch — as pure, simulator-free `KeraunosCore` code driven entirely by a scripted mock session.

**Architecture:** The real background `URLSession` is task-based and event-driven: you start a download task and later receive delegate callbacks. Phase 2 abstracts that as `TransferSession` (start-task / cancel-with-resume-data / enumerate-live-tasks) and models the delegate callbacks as two ingress methods on `TransferCoordinator` (`taskDidFinishDownloading`, `taskDidFail`). The coordinator owns the task→(job,track) routing, ports today's `Downloader.downloadChunked` corruption guards onto download tasks, and enforces the Phase-1 crash-consistency ordering (append→fsync via `PartFile.append`, then persist `bytesWritten` via `store.update`, then truncate-to-offset on resume). Download completion advances a job to `.readyToMerge`; the actual merge/finalize is Phase 4.

**Tech Stack:** Swift 6 (language mode v6), Swift Testing, `Foundation` (`URLRequest`, `FileManager`, `FileHandle`).

**Spec:** `docs/superpowers/specs/2026-07-21-background-transfer-design.md` (sections "The transfer engine", "Architecture & the core/app boundary → KeraunosCore"; phasing step 2).

## Global Constraints

- **Swift 6 language mode**, package default isolation stays `nonisolated`.
- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- **All new logic lives in `KeraunosCore`** so it stays simulator-free; the scripted mock session lives in the test target.
- **No real `URLSession`, no delegate, no background config** — that is Phase 3. The coordinator only ever talks to the `TransferSession` seam.
- **Crash-consistency ordering is load-bearing:** `PartFile.append` (fsync) → `store.update` (persist `bytesWritten`) → on resume `PartFile.truncate(to: bytesWritten)` before the next ranged request. Never reorder.
- **Port, do not reinvent, the chunked corruption guards** from `Downloader.downloadChunked` (`Downloader.swift:59-108`): HTTP 200 is the whole file and valid only at offset 0; 206 is partial (parse total from `Content-Range`); terminate on a short/empty chunk or `bytesWritten >= totalBytes`; any other status is a network failure.
- **Sequential only** — one task in flight per job at a time (adaptive: video track fully, then audio track). No parallel chunks.
- Run tests from the repo root with `swift test --package-path app/KeraunosCore`.

## What this phase deliberately does NOT do (later phases)

- **No `URLSession`/delegate/background config/app-delegate glue/Keychain** — Phase 3.
- **No merge, no pre-merge integrity check, no disk-space guard, no Photos, no move-to-DownloadStore** — Phase 4. Download completion stops at `.readyToMerge`.
- **No `403`/`410`/`expire=` handling, no `.needsRefresh`** — Phase 5. Non-2xx is `.failed(.network)` for now.
- **No `TransferProgress` store / UI** — Phase 6. The coordinator tracks bytes but publishes no progress stream yet.
- **Auto-retry-on-reachability policy** is glue (Phase 3/6). A failed task leaves the job `.downloading` with intact offset; `reassociateAndResume()` is the re-kick entry point.

---

## File Structure

- `app/KeraunosCore/Sources/KeraunosCore/TransferSession.swift` — the `TransferSession` protocol seam. One responsibility: abstract the task-based session API.
- `app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift` — `actor TransferCoordinator`: task↔job/track routing, single-shot + sequential-chunked drivers, resume + reassociation. One responsibility: drive jobs to `.readyToMerge`.
- `app/KeraunosCore/Tests/KeraunosCoreTests/ScriptedTransferSession.swift` — a mock `TransferSession` (test target) that records started tasks and tracks a live set, so tests can script delegate-style event orderings.
- `app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift` — the coordinator behavior suite.

---

### Task 1: The `TransferSession` seam

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/TransferSession.swift`
- Create (test target): `app/KeraunosCore/Tests/KeraunosCoreTests/ScriptedTransferSession.swift`

**Interfaces:**
- Produces:
  - `protocol TransferSession: Sendable` with:
    - `func startDownloadTask(for request: URLRequest) async throws -> Int`
    - `func startDownloadTask(withResumeData resumeData: Data) async throws -> Int`
    - `@discardableResult func cancelTask(_ identifier: Int) async -> Data?`
    - `func liveTaskIdentifiers() async -> [Int]`
  - `actor ScriptedTransferSession: TransferSession` (test target) exposing `started: [(id: Int, request: URLRequest)]`, `startedResumeData: [(id: Int, data: Data)]`, `cancelled: [Int]`, a mutable `live: Set<Int>`, and `func lastRange() -> String?`.

- [ ] **Step 1: Write the seam and the mock**

Create `app/KeraunosCore/Sources/KeraunosCore/TransferSession.swift`:

```swift
import Foundation

/// The task-based session API the `TransferCoordinator` drives, seamed so the engine is
/// testable without a real background `URLSession`. The app target (Phase 3) provides a
/// concrete implementation wrapping `URLSession(configuration: .background(withIdentifier:))`;
/// tests provide a scripted mock. All methods are `async` because the concrete type is an
/// actor around a session it must not race.
public protocol TransferSession: Sendable {
    /// Starts a download task for `request` and returns the assigned task identifier.
    func startDownloadTask(for request: URLRequest) async throws -> Int
    /// Starts a download task from previously-captured resume data (single-shot resume).
    func startDownloadTask(withResumeData resumeData: Data) async throws -> Int
    /// Cancels the task, returning resume data if the session can produce it (single-shot).
    @discardableResult func cancelTask(_ identifier: Int) async -> Data?
    /// Identifiers of tasks currently in flight — used for relaunch reassociation.
    func liveTaskIdentifiers() async -> [Int]
}
```

Create `app/KeraunosCore/Tests/KeraunosCoreTests/ScriptedTransferSession.swift`:

```swift
import Foundation
import KeraunosCore

/// A scriptable `TransferSession` double. It hands out monotonic task identifiers, records
/// every started request (so a test can read the `Range` header the coordinator built), and
/// keeps a mutable `live` set a test can mutate to simulate tasks the OS killed while the
/// app was suspended. Events are delivered by the test calling the coordinator's ingress
/// methods directly with an id this session handed out.
actor ScriptedTransferSession: TransferSession {
    private(set) var started: [(id: Int, request: URLRequest)] = []
    private(set) var startedResumeData: [(id: Int, data: Data)] = []
    private(set) var cancelled: [Int] = []
    var live: Set<Int> = []
    var resumeDataOnCancel: Data?
    private var nextID = 0

    func startDownloadTask(for request: URLRequest) async throws -> Int {
        nextID += 1
        started.append((nextID, request))
        live.insert(nextID)
        return nextID
    }

    func startDownloadTask(withResumeData resumeData: Data) async throws -> Int {
        nextID += 1
        startedResumeData.append((nextID, resumeData))
        live.insert(nextID)
        return nextID
    }

    @discardableResult
    func cancelTask(_ identifier: Int) async -> Data? {
        cancelled.append(identifier)
        live.remove(identifier)
        return resumeDataOnCancel
    }

    func liveTaskIdentifiers() async -> [Int] { Array(live) }

    /// The `Range` header of the most recently started (ranged) task, for assertions.
    func lastRange() -> String? { started.last?.request.value(forHTTPHeaderField: "Range") }
    func setLive(_ ids: Set<Int>) { live = ids }
}
```

- [ ] **Step 2: Verify it builds**

Run: `swift build --package-path app/KeraunosCore`
Expected: builds clean (no tests reference the coordinator yet).

- [ ] **Step 3: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferSession.swift app/KeraunosCore/Tests/KeraunosCoreTests/ScriptedTransferSession.swift
git commit -m "feat(transfer): TransferSession seam + scripted mock"
```

---

### Task 2: `TransferCoordinator` — single-shot & progressive completion

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift`

**Interfaces:**
- Consumes: `TransferJobStore`, `TransferJob`, `TrackJob`, `PartFile` (Phase 1); `TransferSession` (Task 1).
- Produces:
  - `actor TransferCoordinator` with:
    - `init(store: TransferJobStore, session: any TransferSession)`
    - `func start(_ job: TransferJob) async throws` — persists the job as `.downloading` and begins its first not-yet-complete track.
    - `func taskDidFinishDownloading(taskIdentifier: Int, to stagedFile: URL, statusCode: Int, contentRangeTotal: Int64?) async` — success ingress carrying a staged temp file.
    - `func taskDidFail(taskIdentifier: Int, resumeData: Data?, isCancelled: Bool) async` — failure ingress.
    - `func reassociateAndResume() async` — rebind live tasks; resume vanished ones.
  - Rule used across the suite: **a track is complete ⟺ `totalBytes != nil && bytesWritten >= totalBytes`**; the engine sets `totalBytes = bytesWritten` at termination when it was still `nil`.

- [ ] **Step 1: Write the failing test (progressive single-shot success + adaptive sequencing + unknown-task)**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct TransferCoordinatorTests {
    // MARK: fixtures
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func stage(_ data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! data.write(to: url)
        return url
    }
    private func track(part: String, chunkSize: Int?, bytesWritten: Int64 = 0,
                       totalBytes: Int64? = nil, resumeData: Data? = nil) -> TrackJob {
        TrackJob(remoteURL: URL(string: "https://cdn.example/\(part)")!,
                 urlExpiresAt: nil, chunkSize: chunkSize, partFileName: part,
                 bytesWritten: bytesWritten, totalBytes: totalBytes,
                 resumeData: resumeData, taskIdentifier: nil)
    }
    private func job(id: UUID = UUID(), kind: TransferJob.Kind, state: JobState = .queued) -> TransferJob {
        TransferJob(id: id, sourcePageURL: URL(string: "https://ex.com")!,
                    formatSelection: FormatSelection(formatID: "x", height: nil, isAdaptive: false),
                    credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
                    state: state, kind: kind, suggestedFilename: "f.mp4",
                    savedFilename: nil, autoSaveToPhotos: false)
    }

    @Test func progressiveSingleShotCompletesToReadyToMerge() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil)))

        try await coord.start(j)
        #expect(await session.started.count == 1)
        #expect(await session.lastRange() == nil)               // single-shot: no Range

        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 500)),
                                             statusCode: 200, contentRangeTotal: nil)

        let reloaded = try TransferJobStore(directory: dir)
        let done = await reloaded.job(id: j.id)!
        #expect(done.state == .readyToMerge)
        #expect(done.tracks[0].bytesWritten == 500)
        #expect(done.tracks[0].totalBytes == 500)
        #expect(store.partFileURL(for: "p.part").pathExists)
        #expect(FileManager.default.fileSize(store.partFileURL(for: "p.part")) == 500)
    }

    @Test func adaptiveDownloadsVideoThenAudioSequentially() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .adaptive(video: track(part: "v.part", chunkSize: nil),
                                    audio: track(part: "a.part", chunkSize: nil)))
        try await coord.start(j)
        #expect(await session.started.count == 1)               // only video started

        let vid = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: vid, to: stage(Data(repeating: 2, count: 300)),
                                             statusCode: 200, contentRangeTotal: nil)
        #expect(await session.started.count == 2)               // audio now started
        // job not ready yet
        #expect(await store.job(id: j.id)!.state == .downloading)

        let aud = await session.started[1].id
        await coord.taskDidFinishDownloading(taskIdentifier: aud, to: stage(Data(repeating: 3, count: 100)),
                                             statusCode: 200, contentRangeTotal: nil)
        let done = await store.job(id: j.id)!
        #expect(done.state == .readyToMerge)
        #expect(FileManager.default.fileSize(store.partFileURL(for: "v.part")) == 300)
        #expect(FileManager.default.fileSize(store.partFileURL(for: "a.part")) == 100)
    }

    @Test func unknownTaskDiscardsStagedFileWithoutCrashing() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let coord = TransferCoordinator(store: store, session: ScriptedTransferSession())
        let staged = stage(Data([9, 9, 9]))
        await coord.taskDidFinishDownloading(taskIdentifier: 999, to: staged,
                                             statusCode: 200, contentRangeTotal: nil)
        #expect(!staged.pathExists)                             // GC'd
        #expect(await store.all().isEmpty)
    }
}

private extension URL { var pathExists: Bool { FileManager.default.fileExists(atPath: path) } }
private extension FileManager { func fileSize(_ url: URL) -> Int64 {
    ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) }) ?? -1 } }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferCoordinatorTests`
Expected: FAIL — "cannot find 'TransferCoordinator' in scope".

- [ ] **Step 3: Write the coordinator (full implementation, all paths)**

Create `app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift`:

```swift
import Foundation

/// The event-driven transfer engine. Drives `TransferJob`s against a `TransferSession`,
/// porting the chunked corruption guards from the old `Downloader.downloadChunked` onto
/// background-capable download tasks and enforcing the Phase-1 crash-consistency ordering.
/// Download completion advances a job to `.readyToMerge`; merging is Phase 4.
public actor TransferCoordinator {
    private let store: TransferJobStore
    private let session: any TransferSession
    /// Live task id → which job/track it is fetching. Rebuilt on relaunch by `reassociateAndResume`.
    private var owners: [Int: Owner] = [:]

    private struct Owner: Sendable { let jobID: UUID; let trackIndex: Int }

    public init(store: TransferJobStore, session: any TransferSession) {
        self.store = store
        self.session = session
    }

    // MARK: - Control

    /// Persists `job` as `.downloading` and begins its first not-yet-complete track.
    public func start(_ job: TransferJob) async throws {
        var job = job
        job.state = .downloading
        try await store.upsert(job)
        guard let index = Self.firstIncompleteTrackIndex(job) else {
            try await store.update(id: job.id) { $0.state = .readyToMerge }
            return
        }
        try await beginTrack(jobID: job.id, trackIndex: index)
    }

    /// Rebinds still-live tasks to their jobs and resumes any `.downloading` job whose
    /// current track's task has vanished (killed while suspended). Call on launch and on
    /// regained reachability.
    public func reassociateAndResume() async {
        let live = Set(await session.liveTaskIdentifiers())
        owners = owners.filter { live.contains($0.key) }
        for job in await store.all() where job.state == .downloading {
            guard let index = Self.firstIncompleteTrackIndex(job) else {
                try? await store.update(id: job.id) { $0.state = .readyToMerge }
                continue
            }
            let track = job.tracks[index]
            if let tid = track.taskIdentifier, live.contains(tid) {
                owners[tid] = Owner(jobID: job.id, trackIndex: index)   // still running — rebind
            } else {
                try? await beginTrack(jobID: job.id, trackIndex: index) // vanished — resume
            }
        }
    }

    // MARK: - Event ingress (called by the session delegate in the app target)

    /// A download task delivered a staged temp file (its bytes are already safe on disk).
    public func taskDidFinishDownloading(taskIdentifier: Int, to stagedFile: URL,
                                         statusCode: Int, contentRangeTotal: Int64?) async {
        guard let owner = owners.removeValue(forKey: taskIdentifier),
              let job = await store.job(id: owner.jobID), job.state == .downloading else {
            try? FileManager.default.removeItem(at: stagedFile)   // launch race / stale — discard
            return
        }
        let track = job.tracks[owner.trackIndex]
        let chunked = (track.chunkSize ?? 0) > 0
        defer { try? FileManager.default.removeItem(at: stagedFile) }

        do {
            if statusCode == 200 {
                // Server ignored Range (or single-shot): the body IS the whole file — only
                // valid at offset 0, else appending would corrupt a partially-written file.
                guard track.bytesWritten == 0 else { throw KeraunosError.downloadNetwork }
                let part = PartFile(url: store.partFileURL(for: track.partFileName))
                try part.truncate(to: 0)
                let length = try part.append(Data(contentsOf: stagedFile))
                try await store.update(id: owner.jobID) {
                    Self.mutateTrack(&$0, at: owner.trackIndex) { $0.bytesWritten = length; $0.totalBytes = length }
                }
                try await completeTrack(jobID: owner.jobID, trackIndex: owner.trackIndex)
            } else if statusCode == 206 {
                let part = PartFile(url: store.partFileURL(for: track.partFileName))
                let chunk = try Data(contentsOf: stagedFile)
                let length = try part.append(chunk)              // fsync BEFORE persisting offset
                let total = contentRangeTotal ?? track.totalBytes
                try await store.update(id: owner.jobID) {
                    Self.mutateTrack(&$0, at: owner.trackIndex) { $0.bytesWritten = length; $0.totalBytes = total }
                }
                let requested = track.chunkSize ?? 0
                let ended = chunk.isEmpty || chunk.count < requested || (total.map { length >= $0 } ?? false)
                if ended {
                    if total == nil {   // server never reported a total — freeze it at what we wrote
                        try await store.update(id: owner.jobID) {
                            Self.mutateTrack(&$0, at: owner.trackIndex) { $0.totalBytes = length }
                        }
                    }
                    try await completeTrack(jobID: owner.jobID, trackIndex: owner.trackIndex)
                } else {
                    try await beginTrack(jobID: owner.jobID, trackIndex: owner.trackIndex)
                }
            } else {
                throw KeraunosError.downloadNetwork              // Phase 5 splits 403/410 → needsRefresh
            }
        } catch {
            try? await store.update(id: owner.jobID) { $0.state = .failed(.network) }
        }
    }

    /// A download task failed (network drop) or was cancelled. The offset is intact, so the
    /// job stays `.downloading`; `reassociateAndResume` re-kicks it. Single-shot resume data
    /// is stashed on the track.
    public func taskDidFail(taskIdentifier: Int, resumeData: Data?, isCancelled: Bool) async {
        guard let owner = owners.removeValue(forKey: taskIdentifier) else { return }
        try? await store.update(id: owner.jobID) {
            Self.mutateTrack(&$0, at: owner.trackIndex) { $0.resumeData = resumeData; $0.taskIdentifier = nil }
        }
    }

    // MARK: - Track driving

    /// Begins (or resumes) the track at `trackIndex`: truncates the part file to the recorded
    /// offset (chunked resume safety), then starts the next task.
    private func beginTrack(jobID: UUID, trackIndex: Int) async throws {
        guard let job = await store.job(id: jobID) else { return }
        let track = job.tracks[trackIndex]
        let chunked = (track.chunkSize ?? 0) > 0
        let taskID: Int
        if chunked {
            // Discard any un-recorded tail written before a crash, so the ranged request
            // that follows can't double-append. `bytesWritten` is authoritative.
            try PartFile(url: store.partFileURL(for: track.partFileName)).truncate(to: track.bytesWritten)
            var request = URLRequest(url: track.remoteURL)
            let upper = track.bytesWritten + Int64(track.chunkSize!) - 1
            request.setValue("bytes=\(track.bytesWritten)-\(upper)", forHTTPHeaderField: "Range")
            taskID = try await session.startDownloadTask(for: request)
        } else if let resume = track.resumeData {
            taskID = try await session.startDownloadTask(withResumeData: resume)
        } else {
            taskID = try await session.startDownloadTask(for: URLRequest(url: track.remoteURL))
        }
        owners[taskID] = Owner(jobID: jobID, trackIndex: trackIndex)
        try await store.update(id: jobID) {
            Self.mutateTrack(&$0, at: trackIndex) { $0.taskIdentifier = taskID }
        }
    }

    /// Marks the current track done and either starts the next track (adaptive) or advances
    /// the whole job to `.readyToMerge`.
    private func completeTrack(jobID: UUID, trackIndex: Int) async throws {
        guard let job = await store.job(id: jobID) else { return }
        if let next = Self.firstIncompleteTrackIndex(job) {
            try await beginTrack(jobID: jobID, trackIndex: next)
        } else {
            try await store.update(id: jobID) { $0.state = .readyToMerge }
        }
        _ = trackIndex
    }

    // MARK: - Helpers

    /// Index of the first track that isn't fully downloaded, or nil if all are complete.
    /// A track is complete ⟺ `totalBytes != nil && bytesWritten >= totalBytes`.
    static func firstIncompleteTrackIndex(_ job: TransferJob) -> Int? {
        job.tracks.firstIndex { track in
            guard let total = track.totalBytes else { return true }
            return track.bytesWritten < total
        }
    }

    /// Applies `mutate` to the track at `index` inside a job's `kind` (0 = progressive/video,
    /// 1 = audio).
    static func mutateTrack(_ job: inout TransferJob, at index: Int, _ mutate: (inout TrackJob) -> Void) {
        switch job.kind {
        case .progressive(var t):
            mutate(&t); job.kind = .progressive(t)
        case .adaptive(var v, var a):
            if index == 0 { mutate(&v) } else { mutate(&a) }
            job.kind = .adaptive(video: v, audio: a)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferCoordinatorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift
git commit -m "feat(transfer): TransferCoordinator single-shot + adaptive sequencing"
```

---

### Task 3: Chunked (sequential ranged) driver

**Files:**
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift` (add to the suite)

*(The implementation already covers the chunked path; this task locks it with the adversarial-ordering tests the spec demands.)*

**Interfaces:**
- Consumes: `TransferCoordinator` (Task 2).

- [ ] **Step 1: Add the chunked tests**

Add to `TransferCoordinatorTests`:

```swift
    @Test func chunked206SequenceAdvancesOffsetAndRanges() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        #expect(await session.lastRange() == "bytes=0-99")

        var id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: 250)
        #expect(await store.job(id: j.id)!.tracks[0].bytesWritten == 100)
        #expect(await store.job(id: j.id)!.tracks[0].totalBytes == 250)
        #expect(await session.lastRange() == "bytes=100-199")

        id = await session.started[1].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: 250)
        #expect(await session.lastRange() == "bytes=200-299")

        id = await session.started[2].id                        // short final chunk (50 of 100)
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 50)),
                                             statusCode: 206, contentRangeTotal: 250)
        let done = await store.job(id: j.id)!
        #expect(done.state == .readyToMerge)
        #expect(done.tracks[0].bytesWritten == 250)
        #expect(FileManager.default.fileSize(store.partFileURL(for: "c.part")) == 250)
    }

    @Test func chunkedTerminatesOnShortChunkWithUnknownTotal() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "u.part", chunkSize: 100)))
        try await coord.start(j)

        var id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: nil)   // total unknown
        id = await session.started[1].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 40)),
                                             statusCode: 206, contentRangeTotal: nil)   // short → end
        let done = await store.job(id: j.id)!
        #expect(done.state == .readyToMerge)
        #expect(done.tracks[0].bytesWritten == 140)
        #expect(done.tracks[0].totalBytes == 140)               // frozen at what we wrote
    }

    @Test func status200AfterNonZeroOffsetFailsAsCorruption() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        // Track already 100 bytes in, total 250.
        let j = job(kind: .progressive(track(part: "x.part", chunkSize: 100,
                                             bytesWritten: 100, totalBytes: 250)))
        try await coord.start(j)
        #expect(await session.lastRange() == "bytes=100-199")

        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 250)),
                                             statusCode: 200, contentRangeTotal: nil)   // whole file at offset 100
        #expect(await store.job(id: j.id)!.state == .failed(.network))
    }

    @Test func nonSuccessStatusFailsJob() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "e.part", chunkSize: 100)))
        try await coord.start(j)
        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data()),
                                             statusCode: 500, contentRangeTotal: nil)
        #expect(await store.job(id: j.id)!.state == .failed(.network))
    }
```

- [ ] **Step 2: Run to verify pass**

Run: `swift test --package-path app/KeraunosCore --filter TransferCoordinatorTests`
Expected: PASS (7 tests).

- [ ] **Step 3: Commit**

```bash
git add app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift
git commit -m "test(transfer): chunked driver 206/200/short-chunk/failure guards"
```

---

### Task 4: Resume & relaunch reassociation

**Files:**
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift` (add to the suite)

*(Implementation already present in Task 2's `reassociateAndResume` / `taskDidFail`; this task locks the behaviors.)*

- [ ] **Step 1: Add the resume/reassociation tests**

Add to `TransferCoordinatorTests`:

```swift
    @Test func singleShotFailureKeepsDownloadingAndStashesResumeData() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil)))
        try await coord.start(j)
        let id = await session.started[0].id

        await coord.taskDidFail(taskIdentifier: id, resumeData: Data([7, 7]), isCancelled: false)
        let after = await store.job(id: j.id)!
        #expect(after.state == .downloading)
        #expect(after.tracks[0].resumeData == Data([7, 7]))

        await session.setLive([])                               // task is gone
        await coord.reassociateAndResume()
        #expect(await session.startedResumeData.map(\.data) == [Data([7, 7])])
    }

    @Test func reassociateResumesChunkedFromOffsetAndTruncatesTail() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        var id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: 250)
        // task for the 2nd chunk (100-199) is now live; simulate a crash that wrote an
        // un-recorded tail into the part file before dying.
        id = await session.started[1].id
        try Data(repeating: 9, count: 30).write(to: {
            let h = try! FileHandle(forWritingTo: store.partFileURL(for: "c.part")); defer { try? h.close() }
            try! h.seekToEnd(); try! h.write(contentsOf: Data(repeating: 9, count: 30)); return store.partFileURL(for: "c.part")
        }())
        #expect(FileManager.default.fileSize(store.partFileURL(for: "c.part")) == 130)

        // Fresh coordinator (in-memory owners lost), task 2 vanished.
        let coord2 = TransferCoordinator(store: store, session: session)
        await session.setLive([])
        await coord2.reassociateAndResume()
        #expect(FileManager.default.fileSize(store.partFileURL(for: "c.part")) == 100)   // tail truncated
        #expect(await session.lastRange() == "bytes=100-199")
    }

    @Test func reassociateRebindsLiveTaskWithoutStartingNew() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        let id = await session.started[0].id                    // task 1 live, mid-first-chunk

        let coord2 = TransferCoordinator(store: store, session: session)
        await coord2.reassociateAndResume()                     // task 1 still live
        #expect(await session.started.count == 1)               // NO new task started
        // Delivering the event to the rebound coordinator still completes the chunk.
        await coord2.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 50)),
                                              statusCode: 206, contentRangeTotal: 50)
        #expect(await store.job(id: j.id)!.state == .readyToMerge)
    }
```

- [ ] **Step 2: Run to verify pass**

Run: `swift test --package-path app/KeraunosCore --filter TransferCoordinatorTests`
Expected: PASS (10 tests).

- [ ] **Step 3: Run the whole package suite**

Run: `swift test --package-path app/KeraunosCore`
Expected: PASS — all pre-existing tests plus the new coordinator suite.

- [ ] **Step 4: Commit**

```bash
git add app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift
git commit -m "test(transfer): resume + relaunch reassociation"
```

---

## Notes for later phases (carry forward)

- **Phase 3** provides the concrete `TransferSession` (background `URLSession`) and the `URLSessionDownloadDelegate` that stages the temp file synchronously then calls `taskDidFinishDownloading`/`taskDidFail` on the coordinator. It also injects auth headers/credentials at request-construction time — Phase 2 builds bare `URLRequest`s (url + Range only); Phase 3 adds a request decorator.
- **Phase 4** consumes `.readyToMerge`: pre-merge integrity check (`part length == totalBytes` per track), disk-space guard, merge with foreground fallback, move to `DownloadStore`, Photos, then `.completed`.
- **Phase 5** changes `taskDidFinishDownloading`'s "any other status" branch: `403`/`410` → `.needsRefresh` (not `.failed(.network)`), and adds `expire=`-deadline detection.
- The **track-complete rule** (`totalBytes != nil && bytesWritten >= totalBytes`) is shared with Phase 4's integrity check — keep them consistent.
