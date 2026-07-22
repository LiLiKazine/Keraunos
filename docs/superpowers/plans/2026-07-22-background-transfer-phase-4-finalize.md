# Background Transfer — Phase 4 (core): Integrity check, disk guard & merge-finalize — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Take `.readyToMerge` jobs to `.completed` — verifying part-file integrity, guarding against insufficient disk, then finalizing (progressive = move the part into the `DownloadStore`; adaptive = mux the two parts via `MediaMerging`), setting `savedFilename`, and deleting the parts — as pure, simulator-free `KeraunosCore` code.

**Architecture:** A new `actor TransferFinalizer` picks up where `TransferCoordinator` stops. It is seamed on the existing `MediaMerging` protocol and `DownloadStore`, plus a new `DiskSpaceProbing` seam so the space guard is deterministic in tests. The Photos save and the `UIApplication.beginBackgroundTask` assertion wrapping a merge are app-target glue (Phase 3/4-glue) that will wrap this finalizer — they are out of Core.

**Tech Stack:** Swift 6, Swift Testing, `Foundation`, existing `MediaMerging` / `MockMerger`, `DownloadStore`, `PartFile`.

**Spec:** `docs/superpowers/specs/2026-07-21-background-transfer-design.md` ("Adaptive orchestration & merge", "Disk-space guard"; phasing step 4, core portion).

## Global Constraints

- Swift 6 language mode; package default isolation `nonisolated`; Swift Testing only.
- All logic in `KeraunosCore`.
- **Track-complete / integrity rule** matches Phase 2: a track's part file length must equal `totalBytes`. A mismatch is `.failed(.integrityCheckFailed)` — fail loudly here, never produce an opaque merge error.
- **Merge is passthrough remux** (reuse `MediaMerging`); no transcoding.
- The finalizer sets `savedFilename` (relative name); the absolute destination is computed at finalize time via `DownloadStore.uniqueDestination` — never persisted (container drift, per Phase 1).
- Run tests: `swift test --package-path app/KeraunosCore`.

## What this phase (core) deliberately does NOT do

- **No `UIApplication.beginBackgroundTask`, no Photos save** — app glue. `autoSaveToPhotos` stays on the job; the glue reads it after `.completed`.
- **No S2 "try-immediately vs always-defer" branch** — that is a device-spike-gated app-glue decision; the finalizer just finalizes when asked.

---

## File Structure

- `app/KeraunosCore/Sources/KeraunosCore/DiskSpaceProbing.swift` — the `DiskSpaceProbing` seam + a real `VolumeDiskSpace` implementation.
- `app/KeraunosCore/Sources/KeraunosCore/TransferFinalizer.swift` — `actor TransferFinalizer`: integrity check, disk guard, finalize.
- `app/KeraunosCore/Tests/KeraunosCoreTests/TransferFinalizerTests.swift`

---

### Task 1: `DiskSpaceProbing` seam

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/DiskSpaceProbing.swift`

**Interfaces:**
- Produces: `protocol DiskSpaceProbing: Sendable { func availableCapacity(at url: URL) -> Int64? }`, and `struct VolumeDiskSpace: DiskSpaceProbing`.

- [ ] **Step 1: Write it** (no dedicated test — it's a thin `resourceValues` wrapper exercised via the finalizer)

```swift
import Foundation

/// Probes free space so the finalizer can refuse a merge that would run the volume out of
/// space mid-write (ENOSPC) instead of failing opaquely. Seamed so tests are deterministic.
public protocol DiskSpaceProbing: Sendable {
    /// Bytes available for "important" usage on `url`'s volume, or nil if unknown.
    func availableCapacity(at url: URL) -> Int64?
}

/// The real probe: asks the volume how much space is available for important usage.
public struct VolumeDiskSpace: DiskSpaceProbing {
    public init() {}
    public func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
```

- [ ] **Step 2: Build + commit**

```bash
swift build --package-path app/KeraunosCore
git add app/KeraunosCore/Sources/KeraunosCore/DiskSpaceProbing.swift
git commit -m "feat(transfer): DiskSpaceProbing seam"
```

---

### Task 2: `TransferFinalizer` — integrity, disk guard, finalize

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/TransferFinalizer.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TransferFinalizerTests.swift`

**Interfaces:**
- Consumes: `TransferJobStore`, `TransferJob`, `PartFile` (Phase 1); `MediaMerging`/`MockMerger`, `DownloadStore`; `DiskSpaceProbing` (Task 1).
- Produces:
  - `actor TransferFinalizer`:
    - `init(store: TransferJobStore, merger: any MediaMerging, downloadStore: DownloadStore, disk: any DiskSpaceProbing = VolumeDiskSpace())`
    - `@discardableResult func finalizeReadyJobs() async -> [UUID]` — finalizes every `.readyToMerge` job, returns the ids that reached `.completed`.
    - `func finalize(id: UUID) async` — finalize one job.

- [ ] **Step 1: Write the failing test**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/TransferFinalizerTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct TransferFinalizerTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func track(part: String, total: Int64) -> TrackJob {
        TrackJob(remoteURL: URL(string: "https://cdn.example/\(part)")!, urlExpiresAt: nil,
                 chunkSize: nil, partFileName: part, bytesWritten: total, totalBytes: total,
                 resumeData: nil, taskIdentifier: nil)
    }
    private func job(kind: TransferJob.Kind, filename: String = "Clip.mp4") -> TransferJob {
        TransferJob(id: UUID(), sourcePageURL: URL(string: "https://ex.com")!,
                    formatSelection: FormatSelection(formatID: "x", height: nil, isAdaptive: false),
                    credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
                    state: .readyToMerge, kind: kind, suggestedFilename: filename,
                    savedFilename: nil, autoSaveToPhotos: false)
    }
    /// A probe returning a fixed capacity.
    struct FixedDisk: DiskSpaceProbing { let cap: Int64?; func availableCapacity(at url: URL) -> Int64? { cap } }

    @Test func progressiveMovesPartIntoStoreAndCompletes() async throws {
        let base = tempDir()
        let store = try TransferJobStore(directory: base.appendingPathComponent("transfers"))
        let downloads = DownloadStore(directory: base.appendingPathComponent("downloads"))
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)))
        try await store.upsert(j)
        try Data(repeating: 1, count: 500).write(to: store.partFileURL(for: "p.part"))

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        let done = await store.job(id: j.id)!
        #expect(done.state == .completed)
        #expect(done.savedFilename == "Clip.mp4")
        #expect(FileManager.default.fileExists(atPath: downloads.directory.appendingPathComponent("Clip.mp4").path))
        #expect(!FileManager.default.fileExists(atPath: store.partFileURL(for: "p.part").path))  // part cleaned up
    }

    @Test func adaptiveMergesBothPartsAndCompletes() async throws {
        let base = tempDir()
        let store = try TransferJobStore(directory: base.appendingPathComponent("transfers"))
        let downloads = DownloadStore(directory: base.appendingPathComponent("downloads"))
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)))
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))

        let merger = MockMerger()
        let fin = TransferFinalizer(store: store, merger: merger,
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        _ = await fin.finalizeReadyJobs()

        let done = await store.job(id: j.id)!
        #expect(done.state == .completed)
        #expect(done.savedFilename == "Clip.mp4")                 // base + .mp4
        #expect(merger.received != nil)
        #expect(!FileManager.default.fileExists(atPath: store.partFileURL(for: "v.part").path))
        #expect(!FileManager.default.fileExists(atPath: store.partFileURL(for: "a.part").path))
    }

    @Test func truncatedPartFailsIntegrityCheck() async throws {
        let base = tempDir()
        let store = try TransferJobStore(directory: base.appendingPathComponent("transfers"))
        let downloads = DownloadStore(directory: base.appendingPathComponent("downloads"))
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)))
        try await store.upsert(j)
        try Data(repeating: 1, count: 400).write(to: store.partFileURL(for: "p.part"))  // short!

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        _ = await fin.finalizeReadyJobs()
        #expect(await store.job(id: j.id)!.state == .failed(.integrityCheckFailed))
    }

    @Test func insufficientDiskFailsBeforeMerge() async throws {
        let base = tempDir()
        let store = try TransferJobStore(directory: base.appendingPathComponent("transfers"))
        let downloads = DownloadStore(directory: base.appendingPathComponent("downloads"))
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)))
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))

        let merger = MockMerger()
        let fin = TransferFinalizer(store: store, merger: merger,
                                    downloadStore: downloads, disk: FixedDisk(cap: 100))  // < 400 needed
        _ = await fin.finalizeReadyJobs()
        #expect(await store.job(id: j.id)!.state == .failed(.insufficientSpace))
        #expect(merger.received == nil)                            // never attempted the merge
    }

    @Test func mergeFailureIsReportedAndPartsRetained() async throws {
        let base = tempDir()
        let store = try TransferJobStore(directory: base.appendingPathComponent("transfers"))
        let downloads = DownloadStore(directory: base.appendingPathComponent("downloads"))
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)))
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))

        let merger = MockMerger(); merger.shouldFail = true
        let fin = TransferFinalizer(store: store, merger: merger,
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        _ = await fin.finalizeReadyJobs()
        #expect(await store.job(id: j.id)!.state == .failed(.integrityCheckFailed))
        // Parts retained for retry until the user deletes.
        #expect(FileManager.default.fileExists(atPath: store.partFileURL(for: "v.part").path))
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `swift test --package-path app/KeraunosCore --filter TransferFinalizerTests` → "cannot find 'TransferFinalizer'".

- [ ] **Step 3: Write the finalizer**

Create `app/KeraunosCore/Sources/KeraunosCore/TransferFinalizer.swift`:

```swift
import Foundation

/// Takes `.readyToMerge` jobs to `.completed`. Verifies each part file's length matches its
/// recorded `totalBytes` (a truncated part fails loudly, not as an opaque merge error),
/// refuses to start a merge that would exhaust the volume, then finalizes: a progressive job
/// moves its single part into the `DownloadStore`; an adaptive job muxes its two parts. The
/// Photos save and the background-task assertion are app-target glue that wrap this actor.
public actor TransferFinalizer {
    private let store: TransferJobStore
    private let merger: any MediaMerging
    private let downloadStore: DownloadStore
    private let disk: any DiskSpaceProbing

    public init(store: TransferJobStore, merger: any MediaMerging,
                downloadStore: DownloadStore, disk: any DiskSpaceProbing = VolumeDiskSpace()) {
        self.store = store
        self.merger = merger
        self.downloadStore = downloadStore
        self.disk = disk
    }

    @discardableResult
    public func finalizeReadyJobs() async -> [UUID] {
        var completed: [UUID] = []
        for job in await store.all() where job.state == .readyToMerge {
            if await finalize(job) { completed.append(job.id) }
        }
        return completed
    }

    public func finalize(id: UUID) async {
        guard let job = await store.job(id: id) else { return }
        _ = await finalize(job)
    }

    /// Returns true iff the job reached `.completed`.
    private func finalize(_ job: TransferJob) async -> Bool {
        guard job.state == .readyToMerge else { return false }

        // 1. Integrity: every part file's length must equal its recorded total.
        for track in job.tracks {
            let length = PartFile(url: store.partFileURL(for: track.partFileName)).length()
            guard let total = track.totalBytes, length == total else {
                try? await store.update(id: job.id) { $0.state = .failed(.integrityCheckFailed) }
                return false
            }
        }

        // 2. Disk guard: the finalized output needs ~sum(track totals) of new space.
        let required = job.tracks.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        if let available = disk.availableCapacity(at: downloadStore.directory), available < required {
            try? await store.update(id: job.id) { $0.state = .failed(.insufficientSpace) }
            return false
        }

        try? await store.update(id: job.id) { $0.state = .merging }

        do {
            let destination: URL
            switch job.kind {
            case .progressive(let track):
                destination = downloadStore.uniqueDestination(for: job.suggestedFilename)
                let part = store.partFileURL(for: track.partFileName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: part, to: destination)
            case .adaptive(let video, let audio):
                let base = (job.suggestedFilename as NSString).deletingPathExtension
                destination = downloadStore.uniqueDestination(for: "\(base).mp4")
                try await merger.merge(video: store.partFileURL(for: video.partFileName),
                                       audio: store.partFileURL(for: audio.partFileName),
                                       into: destination)
            }
            // Success: record the saved name, drop the parts, complete.
            let savedName = destination.lastPathComponent
            try? await store.update(id: job.id) { $0.savedFilename = savedName; $0.state = .completed }
            for track in job.tracks {
                try? FileManager.default.removeItem(at: store.partFileURL(for: track.partFileName))
            }
            return true
        } catch {
            // Merge/move failed after the integrity check — a real mux error. Retain parts
            // for retry; surface as integrityCheckFailed (the only durable "bad output" reason).
            try? await store.update(id: job.id) { $0.state = .failed(.integrityCheckFailed) }
            return false
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — expected PASS (5 tests).
- [ ] **Step 5: Run whole suite** — `swift test --package-path app/KeraunosCore`.
- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferFinalizer.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferFinalizerTests.swift
git commit -m "feat(transfer): TransferFinalizer (integrity + disk guard + merge)"
```

---

## Notes for later phases

- **Phase 4-glue (app target):** wrap `finalize` in a `UIApplication.beginBackgroundTask` assertion; after `.completed`, if `autoSaveToPhotos`, call the app's `PhotoSaving` on the destination (guarded by `PhotosCompatibility.canSave`). S2 spike decides whether to attempt immediately on a background-launch or always defer to foreground.
- **Progressive move is same-volume** (Application Support parts → Documents downloads, one container) so it is a rename needing no extra space — only adaptive is disk-guarded.
