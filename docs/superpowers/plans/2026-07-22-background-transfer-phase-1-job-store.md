# Background Transfer — Phase 1: Durable Job Model & Store — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the durable, persisted job model and store that every later background-transfer phase depends on — including the crash-consistency and orphan-GC rules — as pure, simulator-free `KeraunosCore` code.

**Architecture:** A value-type job graph (`TransferJob` → `TrackJob`) is persisted as JSON in Application Support by an `actor TransferJobStore`. A separate `PartFile` value type owns the append/fsync/truncate discipline for accumulating chunk bytes. Everything here is pure Swift with no `URLSession`, no UIKit, no simulator — it is fully driven by `swift test`.

**Tech Stack:** Swift 6 (language mode v6), Swift Testing, `Foundation` (`FileManager`, `FileHandle`, `JSONEncoder`/`JSONDecoder`).

**Spec:** `docs/superpowers/specs/2026-07-21-background-transfer-design.md` (sections "Job model & persistence"; this plan implements phasing step 1).

## Global Constraints

- **Swift 6 language mode**, package default isolation stays `nonisolated` (do not add `-default-isolation=MainActor` to the package).
- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- **All new logic lives in `KeraunosCore`** (`app/KeraunosCore/Sources/KeraunosCore/`) so it stays simulator-free.
- **Persisted state lives in Application Support**, never `temporaryDirectory` (must survive relaunch) and never `Documents` (not user-facing files).
- **Persist relative part-file NAMES, not absolute `URL`s.** An iOS app-container absolute path changes across installs/updates; a persisted absolute `URL` would dangle. The store resolves names against its `partsDirectory` at runtime.
- **Crash-consistency ordering is load-bearing:** append chunk → `fsync` (`FileHandle.synchronize()`) → persist offset; on resume, truncate the part file down to the persisted offset. Never reorder these.
- **Atomic JSON writes** (`Data.write(to:options:.atomic)`).
- Package platforms are `iOS(.v26)`, `macOS(.v15)` — do not change them.
- Run tests from the repo root with `swift test --package-path app/KeraunosCore`.

---

## File Structure

- `app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift` — the persisted model: `TransferJob`, `TrackJob`, `FormatSelection`, `JobState`, `FailureReason`, and derived accessors. One responsibility: the data shape.
- `app/KeraunosCore/Sources/KeraunosCore/PartFile.swift` — `PartFile`: append-with-fsync, length, truncate-to-offset. One responsibility: crash-safe byte accumulation on disk.
- `app/KeraunosCore/Sources/KeraunosCore/TransferJobStore.swift` — `actor TransferJobStore`: load/persist, CRUD, part-file resolution, orphan GC. One responsibility: durable ownership of the job set.
- `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobTests.swift`
- `app/KeraunosCore/Tests/KeraunosCoreTests/PartFileTests.swift`
- `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobStoreTests.swift`

---

### Task 1: The persisted job model

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobTests.swift`

**Interfaces:**
- Consumes: nothing (leaf types).
- Produces:
  - `enum FailureReason: String, Codable, Sendable, Equatable { case network, insufficientSpace, refreshFailed, integrityCheckFailed }`
  - `enum JobState: Codable, Sendable, Equatable { case queued, downloading, needsRefresh, readyToMerge, merging, completed, failed(FailureReason), cancelled }`
  - `struct FormatSelection: Codable, Sendable, Equatable { let formatID: String; let height: Int?; let isAdaptive: Bool }`
  - `struct TrackJob: Codable, Sendable, Equatable` with: `let remoteURL: URL; var urlExpiresAt: Date?; let chunkSize: Int?; let partFileName: String; var bytesWritten: Int64; var totalBytes: Int64?; var resumeData: Data?; var taskIdentifier: Int?`
  - `struct TransferJob: Codable, Sendable, Equatable, Identifiable` with: `let id: UUID; let sourcePageURL: URL; let formatSelection: FormatSelection; let credentialRef: String?; let createdAt: Date; var state: JobState; var kind: Kind; let suggestedFilename: String; var savedFilename: String?; let autoSaveToPhotos: Bool` and nested `enum Kind: Codable, Sendable, Equatable { case progressive(TrackJob); case adaptive(video: TrackJob, audio: TrackJob) }`
  - Derived: `var tracks: [TrackJob]` and `var trackPartFileNames: [String]`
  - Note: the spec's `finalDestination: URL?` is intentionally replaced by `savedFilename: String?` (relative name) — container-path drift makes a persisted absolute destination URL unsafe; the final `URL` is computed at merge time (Phase 4) via `DownloadStore.uniqueDestination`.

- [ ] **Step 1: Write the failing test**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct TransferJobTests {
    private func adaptiveJob() -> TransferJob {
        let video = TrackJob(
            remoteURL: URL(string: "https://cdn.example/v?expire=123")!,
            urlExpiresAt: Date(timeIntervalSince1970: 123),
            chunkSize: 10_485_760,
            partFileName: "job-video.part",
            bytesWritten: 20_971_520,
            totalBytes: 104_857_600,
            resumeData: nil,
            taskIdentifier: 7)
        let audio = TrackJob(
            remoteURL: URL(string: "https://cdn.example/a")!,
            urlExpiresAt: nil,
            chunkSize: nil,
            partFileName: "job-audio.part",
            bytesWritten: 0,
            totalBytes: nil,
            resumeData: Data([1, 2, 3]),
            taskIdentifier: nil)
        return TransferJob(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sourcePageURL: URL(string: "https://youtube.com/watch?v=x")!,
            formatSelection: FormatSelection(formatID: "137+140", height: 1080, isAdaptive: true),
            credentialRef: "youtube.com",
            createdAt: Date(timeIntervalSince1970: 1000),
            state: .downloading,
            kind: .adaptive(video: video, audio: audio),
            suggestedFilename: "Clip.mp4",
            savedFilename: nil,
            autoSaveToPhotos: true)
    }

    @Test func codableRoundTripPreservesEverything() throws {
        let job = adaptiveJob()
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: data)
        #expect(decoded == job)
    }

    @Test func failedStateRoundTripsWithReason() throws {
        var job = adaptiveJob()
        job.state = .failed(.insufficientSpace)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.state == .failed(.insufficientSpace))
    }

    @Test func tracksAndPartNamesForAdaptive() {
        let job = adaptiveJob()
        #expect(job.tracks.count == 2)
        #expect(job.trackPartFileNames == ["job-video.part", "job-audio.part"])
    }

    @Test func tracksAndPartNamesForProgressive() {
        let track = TrackJob(
            remoteURL: URL(string: "https://cdn.example/p.mp4")!,
            urlExpiresAt: nil, chunkSize: nil, partFileName: "job-prog.part",
            bytesWritten: 0, totalBytes: nil, resumeData: nil, taskIdentifier: nil)
        let job = TransferJob(
            id: UUID(), sourcePageURL: URL(string: "https://ex.com")!,
            formatSelection: FormatSelection(formatID: "18", height: 360, isAdaptive: false),
            credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
            state: .queued, kind: .progressive(track),
            suggestedFilename: "p.mp4", savedFilename: nil, autoSaveToPhotos: false)
        #expect(job.trackPartFileNames == ["job-prog.part"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferJobTests`
Expected: FAIL — compile error, "cannot find 'TransferJob' in scope" (and the other types).

- [ ] **Step 3: Write the model**

Create `app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift`:

```swift
import Foundation

/// Why a job ended up in `.failed`. Surfaced in the UI and drives the recovery action.
public enum FailureReason: String, Codable, Sendable, Equatable {
    case network
    case insufficientSpace
    case refreshFailed
    case integrityCheckFailed
}

/// The durable state of a transfer job. `failed` carries the reason so the UI can offer
/// the right recovery (retry / manage storage) after a relaunch.
public enum JobState: Codable, Sendable, Equatable {
    case queued
    case downloading
    case needsRefresh
    case readyToMerge
    case merging
    case completed
    case failed(FailureReason)
    case cancelled
}

/// Enough to deterministically re-pick the SAME format on a refresh re-extraction, so a
/// resumed download continues the byte-identical file rather than a different rendition.
public struct FormatSelection: Codable, Sendable, Equatable {
    public let formatID: String
    public let height: Int?
    public let isAdaptive: Bool

    public init(formatID: String, height: Int?, isAdaptive: Bool) {
        self.formatID = formatID
        self.height = height
        self.isAdaptive = isAdaptive
    }
}

/// One downloadable track's durable state. `partFileName` is a NAME resolved against the
/// store's parts directory at runtime — never a persisted absolute URL (the app container
/// path drifts across installs). `bytesWritten` is the authoritative resume offset.
public struct TrackJob: Codable, Sendable, Equatable {
    public let remoteURL: URL
    public var urlExpiresAt: Date?
    public let chunkSize: Int?
    public let partFileName: String
    public var bytesWritten: Int64
    public var totalBytes: Int64?
    public var resumeData: Data?
    public var taskIdentifier: Int?

    public init(remoteURL: URL, urlExpiresAt: Date?, chunkSize: Int?, partFileName: String,
                bytesWritten: Int64, totalBytes: Int64?, resumeData: Data?, taskIdentifier: Int?) {
        self.remoteURL = remoteURL
        self.urlExpiresAt = urlExpiresAt
        self.chunkSize = chunkSize
        self.partFileName = partFileName
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.resumeData = resumeData
        self.taskIdentifier = taskIdentifier
    }
}

/// A durable, queued/in-flight download. Persisted verbatim; the store owns the array.
public struct TransferJob: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: Codable, Sendable, Equatable {
        case progressive(TrackJob)
        case adaptive(video: TrackJob, audio: TrackJob)
    }

    public let id: UUID
    public let sourcePageURL: URL
    public let formatSelection: FormatSelection
    public let credentialRef: String?
    public let createdAt: Date
    public var state: JobState
    public var kind: Kind
    public let suggestedFilename: String
    /// Set on completion (relative name of the file placed in the DownloadStore). The
    /// absolute destination URL is computed at merge time, not persisted (container drift).
    public var savedFilename: String?
    public let autoSaveToPhotos: Bool

    public init(id: UUID, sourcePageURL: URL, formatSelection: FormatSelection,
                credentialRef: String?, createdAt: Date, state: JobState, kind: Kind,
                suggestedFilename: String, savedFilename: String?, autoSaveToPhotos: Bool) {
        self.id = id
        self.sourcePageURL = sourcePageURL
        self.formatSelection = formatSelection
        self.credentialRef = credentialRef
        self.createdAt = createdAt
        self.state = state
        self.kind = kind
        self.suggestedFilename = suggestedFilename
        self.savedFilename = savedFilename
        self.autoSaveToPhotos = autoSaveToPhotos
    }

    /// The job's tracks in a stable order: `[progressive]` or `[video, audio]`.
    public var tracks: [TrackJob] {
        switch kind {
        case .progressive(let track): return [track]
        case .adaptive(let video, let audio): return [video, audio]
        }
    }

    /// Part-file names this job owns — used for cleanup and orphan reconciliation.
    public var trackPartFileNames: [String] { tracks.map(\.partFileName) }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferJobTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobTests.swift
git commit -m "feat(transfer): durable TransferJob/TrackJob model"
```

---

### Task 2: PartFile — crash-safe byte accumulation

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/PartFile.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/PartFileTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct PartFile: Sendable { init(url: URL); func length() -> Int64; @discardableResult func append(_ data: Data) throws -> Int64; func truncate(to offset: Int64) throws }`

- [ ] **Step 1: Write the failing test**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/PartFileTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct PartFileTests {
    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("track.part")
    }

    @Test func appendCreatesFileAndGrowsLength() throws {
        let part = PartFile(url: tempFile())
        #expect(part.length() == 0)
        let afterFirst = try part.append(Data(repeating: 0xAB, count: 100))
        #expect(afterFirst == 100)
        let afterSecond = try part.append(Data(repeating: 0xCD, count: 50))
        #expect(afterSecond == 150)
        #expect(part.length() == 150)
    }

    @Test func truncateDiscardsUnrecordedTail() throws {
        // Simulate a crash: 100 bytes are "committed" (offset persisted elsewhere), then a
        // further 50 are appended but the crash happens before the offset is persisted. On
        // resume we truncate down to the committed offset — the file must end at 100 bytes.
        let url = tempFile()
        let part = PartFile(url: url)
        try part.append(Data(repeating: 0xAB, count: 100))   // committed offset = 100
        try part.append(Data(repeating: 0xFF, count: 50))    // un-recorded tail
        #expect(part.length() == 150)

        try part.truncate(to: 100)

        #expect(part.length() == 100)
        let bytes = try Data(contentsOf: url)
        #expect(bytes == Data(repeating: 0xAB, count: 100))   // only committed bytes survive
    }

    @Test func truncateOnAbsentFileYieldsEmptyFile() throws {
        let url = tempFile()
        try PartFile(url: url).truncate(to: 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(PartFile(url: url).length() == 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter PartFileTests`
Expected: FAIL — "cannot find 'PartFile' in scope".

- [ ] **Step 3: Write PartFile**

Create `app/KeraunosCore/Sources/KeraunosCore/PartFile.swift`:

```swift
import Foundation

/// A single accumulating download part on disk, with the crash-consistency discipline the
/// chunked resume path relies on: `append` flushes to disk (fsync) before returning, so the
/// file is never shorter than a reported length; `truncate(to:)` drops any tail written but
/// not yet recorded before a crash, so a resume from the persisted offset can't double-append.
public struct PartFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Current on-disk byte length (0 if the file is absent). Read fresh each call.
    public func length() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Appends `data`, flushes it to stable storage, and returns the new length.
    @discardableResult
    public func append(_ data: Data) throws -> Int64 {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()   // fsync — bytes are durable before we return the length
        return length()
    }

    /// Truncates the file down to `offset` bytes (creating an empty file if absent).
    public func truncate(to offset: Int64) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.synchronize()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter PartFileTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/PartFile.swift app/KeraunosCore/Tests/KeraunosCoreTests/PartFileTests.swift
git commit -m "feat(transfer): crash-safe PartFile (append/fsync/truncate)"
```

---

### Task 3: TransferJobStore — persistence & CRUD

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/TransferJobStore.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobStoreTests.swift`

**Interfaces:**
- Consumes: `TransferJob` (Task 1).
- Produces: `actor TransferJobStore` with (all instance methods are `async` at the call site because it is an actor):
  - `static var defaultDirectory: URL` (Application Support/`Transfers`)
  - `init(directory: URL? = nil) throws` (synchronous)
  - `let directory: URL`, `let partsDirectory: URL` (immutable `Sendable` — readable without `await`)
  - `func all() -> [TransferJob]`
  - `func job(id: UUID) -> TransferJob?`
  - `func upsert(_ job: TransferJob) throws`
  - `@discardableResult func update(id: UUID, _ mutate: @Sendable (inout TransferJob) -> Void) throws -> TransferJob?`
  - `func remove(id: UUID) throws`
  - `nonisolated func partFileURL(for name: String) -> URL` (reads only the immutable `partsDirectory`, so callers need no `await`)

- [ ] **Step 1: Write the failing test**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobStoreTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct TransferJobStoreTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func progressiveJob(id: UUID = UUID(), partName: String = "p.part",
                                state: JobState = .queued) -> TransferJob {
        let track = TrackJob(
            remoteURL: URL(string: "https://cdn.example/p.mp4")!,
            urlExpiresAt: nil, chunkSize: nil, partFileName: partName,
            bytesWritten: 0, totalBytes: nil, resumeData: nil, taskIdentifier: nil)
        return TransferJob(
            id: id, sourcePageURL: URL(string: "https://ex.com")!,
            formatSelection: FormatSelection(formatID: "18", height: 360, isAdaptive: false),
            credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
            state: state, kind: .progressive(track),
            suggestedFilename: "p.mp4", savedFilename: nil, autoSaveToPhotos: false)
    }

    @Test func upsertPersistsAcrossStoreInstances() async throws {
        let dir = tempDir()
        let job = progressiveJob()
        try await TransferJobStore(directory: dir).upsert(job)

        // A fresh store instance over the same directory rehydrates from disk.
        let reloaded = try TransferJobStore(directory: dir)
        #expect(await reloaded.all() == [job])
        #expect(await reloaded.job(id: job.id) == job)
    }

    @Test func upsertReplacesExistingJobById() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let id = UUID()
        try await store.upsert(progressiveJob(id: id, state: .queued))
        try await store.upsert(progressiveJob(id: id, state: .downloading))
        #expect(await store.all().count == 1)
        #expect(await store.job(id: id)?.state == .downloading)
    }

    @Test func updateMutatesAndPersists() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let job = progressiveJob(state: .downloading)
        try await store.upsert(job)

        let returned = try await store.update(id: job.id) { $0.state = .failed(.network) }
        #expect(returned?.state == .failed(.network))
        let reloadedState = try await TransferJobStore(directory: dir).job(id: job.id)?.state
        #expect(reloadedState == .failed(.network))
    }

    @Test func updateUnknownIdReturnsNil() async throws {
        let store = try TransferJobStore(directory: tempDir())
        let result = try await store.update(id: UUID()) { $0.state = .cancelled }
        #expect(result == nil)
    }

    @Test func removeDeletesJobAndItsPartFiles() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let job = progressiveJob(partName: "p.part")
        try await store.upsert(job)
        // Create the part file this job owns (partFileURL is nonisolated — no await).
        let partURL = store.partFileURL(for: "p.part")
        try Data([1, 2, 3]).write(to: partURL)

        try await store.remove(id: job.id)

        #expect(await store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    @Test func loadsEmptyWhenNoFileYet() async throws {
        let store = try TransferJobStore(directory: tempDir())
        #expect(await store.all().isEmpty)
    }

    @Test func defaultDirectoryIsApplicationSupport() {
        // Check the static path — do NOT construct a default store, which would create a
        // real ~/Library/Application Support/Transfers on the host during tests.
        #expect(TransferJobStore.defaultDirectory.path.contains("Application Support"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferJobStoreTests`
Expected: FAIL — "cannot find 'TransferJobStore' in scope".

- [ ] **Step 3: Write the store**

Create `app/KeraunosCore/Sources/KeraunosCore/TransferJobStore.swift`:

```swift
import Foundation

/// Durable owner of the transfer job set. Persists atomically to Application Support on
/// every mutation and rehydrates on init, so the queue survives suspension, termination,
/// and relaunch. Part files live in a sibling `parts/` directory, addressed by name.
public actor TransferJobStore {
    public let directory: URL
    public let partsDirectory: URL
    private let fileURL: URL
    private var jobs: [TransferJob]

    /// Default base directory: `<Application Support>/Transfers`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfers", isDirectory: true)
    }

    public init(directory: URL? = nil) throws {
        let base = directory ?? Self.defaultDirectory
        self.directory = base
        self.partsDirectory = base.appendingPathComponent("parts", isDirectory: true)
        self.fileURL = base.appendingPathComponent("transfers.json")
        // Creating the parts dir with intermediates also creates `base`.
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        self.jobs = Self.load(fileURL)
    }

    public func all() -> [TransferJob] { jobs }

    public func job(id: UUID) -> TransferJob? { jobs.first { $0.id == id } }

    /// Adds a job, or replaces the existing one with the same id.
    public func upsert(_ job: TransferJob) throws {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[i] = job
        } else {
            jobs.append(job)
        }
        try persist()
    }

    /// Mutates a job in place and persists. Returns the updated job, or nil if not found.
    @discardableResult
    public func update(id: UUID, _ mutate: @Sendable (inout TransferJob) -> Void) throws -> TransferJob? {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&jobs[i])
        try persist()
        return jobs[i]
    }

    /// Removes a job and deletes the part files it owned (best-effort).
    public func remove(id: UUID) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        for name in jobs[i].trackPartFileNames {
            try? FileManager.default.removeItem(at: partFileURL(for: name))
        }
        jobs.remove(at: i)
        try persist()
    }

    /// Resolves a part-file name to its absolute URL. `nonisolated` — it reads only the
    /// immutable `partsDirectory`, so callers don't need to `await`.
    public nonisolated func partFileURL(for name: String) -> URL {
        partsDirectory.appendingPathComponent(name)
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(jobs)
        try data.write(to: fileURL, options: .atomic)
    }

    private static func load(_ url: URL) -> [TransferJob] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TransferJob].self, from: data)) ?? []
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferJobStoreTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferJobStore.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobStoreTests.swift
git commit -m "feat(transfer): TransferJobStore persistence + CRUD"
```

---

### Task 4: Orphan part-file GC

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/TransferJobStore.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobStoreTests.swift` (add to the existing suite)

**Interfaces:**
- Consumes: `TransferJobStore` (Task 3), `TransferJob.trackPartFileNames` (Task 1).
- Produces: `@discardableResult func reconcileOrphanParts() throws -> [String]` on `TransferJobStore` — deletes files in `partsDirectory` not referenced by any current job's track; returns the removed names sorted.

- [ ] **Step 1: Write the failing test**

Add these tests to `TransferJobStoreTests` in `app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobStoreTests.swift`:

```swift
    @Test func reconcileOrphanPartsRemovesUnreferencedFilesOnly() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        try await store.upsert(progressiveJob(partName: "keep.part"))
        // One referenced part, one orphan left behind by a crash between cancel and cleanup.
        try Data([1]).write(to: store.partFileURL(for: "keep.part"))
        try Data([2]).write(to: store.partFileURL(for: "orphan.part"))

        let removed = try await store.reconcileOrphanParts()

        #expect(removed == ["orphan.part"])
        #expect(FileManager.default.fileExists(atPath: store.partFileURL(for: "keep.part").path))
        #expect(!FileManager.default.fileExists(atPath: store.partFileURL(for: "orphan.part").path))
    }

    @Test func reconcileOrphanPartsNoopWhenAllReferenced() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        try await store.upsert(progressiveJob(partName: "p.part"))
        try Data([1]).write(to: store.partFileURL(for: "p.part"))
        let removed = try await store.reconcileOrphanParts()
        #expect(removed.isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --package-path app/KeraunosCore --filter TransferJobStoreTests`
Expected: FAIL — "value of type 'TransferJobStore' has no member 'reconcileOrphanParts'".

- [ ] **Step 3: Add the method**

In `app/KeraunosCore/Sources/KeraunosCore/TransferJobStore.swift`, add this method to the `TransferJobStore` actor (e.g. right after `remove(id:)`):

```swift
    /// Deletes part files with no owning job — e.g. a crash between cancel and cleanup.
    /// Application Support is never auto-purged, so this reconciliation runs on launch.
    /// Returns the removed names (sorted) for logging.
    @discardableResult
    public func reconcileOrphanParts() throws -> [String] {
        let referenced = Set(jobs.flatMap(\.trackPartFileNames))
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: partsDirectory.path)) ?? []
        var removed: [String] = []
        for name in contents where !referenced.contains(name) {
            try? FileManager.default.removeItem(at: partFileURL(for: name))
            removed.append(name)
        }
        return removed.sorted()
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --package-path app/KeraunosCore --filter TransferJobStoreTests`
Expected: PASS (9 tests total in the suite).

- [ ] **Step 5: Run the whole package suite**

Run: `swift test --package-path app/KeraunosCore`
Expected: PASS — all pre-existing tests plus the new `TransferJobTests`, `PartFileTests`, `TransferJobStoreTests`.

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferJobStore.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferJobStoreTests.swift
git commit -m "feat(transfer): orphan part-file reconciliation"
```

---

## What this phase deliberately does NOT do

These belong to later phase plans and must not be pulled forward:

- **No `URLSession`, no delegate, no background config** — Phase 3.
- **No chunk driver / coordinator / state machine** — Phase 2 & 4. (`PartFile` and `bytesWritten` are the primitives it will use; the append→persist→truncate *sequencing* is enforced by the coordinator in Phase 2.)
- **No re-extraction, expiry parsing, or `.needsRefresh` transitions** — Phase 5. (`urlExpiresAt` and the `needsRefresh` case exist in the model but nothing drives them yet.)
- **No UI** — Phase 6.
- **No Keychain / auth wiring** — Phase 3 (`credentialRef` is a plain stored string here).

## Notes for later phases (carry forward)

- The coordinator (Phase 2) must persist `bytesWritten` via `store.update(id:)` **only after** `PartFile.append` returns (post-fsync), and call `PartFile.truncate(to: bytesWritten)` before issuing the next ranged request on resume.
- `reconcileOrphanParts()` should be called once at launch, after the store rehydrates and after task reassociation (Phase 3), so parts belonging to live jobs are never swept.
