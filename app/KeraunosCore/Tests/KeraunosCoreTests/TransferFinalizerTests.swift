import Testing
import Foundation
import KeraunosCore

private actor SuspendedMerger: MediaMerging {
    private var calls = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func merge(video: URL, audio: URL, into output: URL) async throws {
        calls += 1
        await withCheckedContinuation { continuation = $0 }
        try Data("merged once".utf8).write(to: output)
    }

    func waitUntilStarted() async {
        while calls == 0 { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func callCount() -> Int { calls }
}

struct TransferFinalizerTests {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func track(part: String, total: Int64) -> TrackJob {
        TrackJob(remoteURL: URL(string: "https://cdn.example/\(part)")!, urlExpiresAt: nil,
                 chunkSize: nil, partFileName: part, bytesWritten: total, totalBytes: total,
                 resumeData: nil, taskIdentifier: nil)
    }
    private func job(kind: TransferJob.Kind, filename: String = "Clip.mp4",
                     state: JobState = .readyToMerge, savedFilename: String? = nil,
                     finalizationPhase: TransferJob.FinalizationPhase? = nil) -> TransferJob {
        TransferJob(id: UUID(), sourcePageURL: URL(string: "https://ex.com")!,
                    formatSelection: FormatSelection(formatID: "x", height: nil, isAdaptive: false),
                    credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
                    state: state, kind: kind, suggestedFilename: filename,
                    savedFilename: savedFilename, autoSaveToPhotos: false,
                    finalizationPhase: finalizationPhase)
    }
    /// A probe returning a fixed capacity.
    struct FixedDisk: DiskSpaceProbing { let cap: Int64?; func availableCapacity(at url: URL) -> Int64? { cap } }

    private func makeStores(_ base: URL) throws -> (TransferJobStore, DownloadStore) {
        let store = try TransferJobStore(directory: base.appendingPathComponent("transfers"))
        let downloads = DownloadStore(directory: base.appendingPathComponent("downloads"))
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        return (store, downloads)
    }

    private func installPromotedOutput(_ bytes: Data, for job: TransferJob,
                                       store: TransferJobStore, destination: URL) throws {
        try bytes.write(to: destination)
        try FileManager.default.linkItem(
            at: destination,
            to: store.partFileURL(for: job.finalizationPromotionCheckpointFileName))
    }

    @Test func progressiveMovesPartIntoStoreAndCompletes() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .progressive(track(part: "p.part", total: 500)))
        try await store.upsert(j)
        let source = store.partFileURL(for: "p.part")
        try Data(repeating: 1, count: 500).write(to: source)
        let sourceFileID = try #require(
            FileManager.default.attributesOfItem(atPath: source.path)[.systemFileNumber] as? NSNumber
        )

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        let done = await store.job(id: j.id)!
        #expect(done.state == .completed)
        #expect(done.savedFilename == "Clip.mp4")
        let output = downloads.directory.appendingPathComponent("Clip.mp4")
        #expect(FileManager.default.fileExists(atPath: output.path))
        let outputFileID = try #require(
            FileManager.default.attributesOfItem(atPath: output.path)[.systemFileNumber] as? NSNumber
        )
        #expect(outputFileID == sourceFileID,
                "progressive finalization must atomically move the existing file, not copy it")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func crashAfterProgressivePromotionCompletesWithoutSourceOrDuplicateOutput() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .merging, savedFilename: "Clip.mp4",
                    finalizationPhase: .readyToPromote)
        try await store.upsert(j)
        let destination = downloads.directory.appendingPathComponent("Clip.mp4")
        let bytes = Data(repeating: 6, count: 500)
        try installPromotedOutput(bytes, for: j, store: store, destination: destination)

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 0))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(await store.job(id: j.id)?.state == .completed)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try FileManager.default.contentsOfDirectory(at: downloads.directory,
                                                            includingPropertiesForKeys: nil).count == 1)
    }

    @Test func adaptiveReadyStageSurvivesCollisionWithoutRepeatingMerge() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)),
                    state: .merging, savedFilename: "Clip.mp4",
                    finalizationPhase: .readyToPromote)
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))
        let stagedBytes = Data("already merged".utf8)
        try stagedBytes.write(to: store.partFileURL(for: j.finalizationReadyFileName))
        try Data("incomplete retry".utf8).write(
            to: store.partFileURL(for: j.finalizationPartialFileName))
        let occupied = downloads.directory.appendingPathComponent("Clip.mp4")
        let occupant = Data("unrelated".utf8)
        try occupant.write(to: occupied)

        let merger = MockMerger()
        let fin = TransferFinalizer(store: store, merger: merger,
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(merger.received == nil, "a durable ready stage must not be muxed again")
        #expect(try Data(contentsOf: occupied) == occupant)
        let done = try #require(await store.job(id: j.id))
        #expect(done.savedFilename == "Clip (2).mp4")
        #expect(try Data(contentsOf: downloads.directory.appendingPathComponent("Clip (2).mp4"))
                == stagedBytes)
        #expect(!FileManager.default.fileExists(
            atPath: store.partFileURL(for: j.finalizationReadyFileName).path))
        #expect(!FileManager.default.fileExists(
            atPath: store.partFileURL(for: j.finalizationPartialFileName).path))
    }

    @Test func equalLengthProgressiveReplacementAfterPromotionIsPreserved() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .merging, savedFilename: "Clip.mp4",
                    finalizationPhase: .readyToPromote)
        try await store.upsert(j)
        let ownedBytes = Data(repeating: 1, count: 500)
        let replacement = Data(repeating: 2, count: 500)
        let checkpoint = store.partFileURL(for: j.finalizationPromotionCheckpointFileName)
        try ownedBytes.write(to: checkpoint)
        let occupied = downloads.directory.appendingPathComponent("Clip.mp4")
        try replacement.write(to: occupied)

        let fin = TransferFinalizer(store: store, merger: MockMerger(), downloadStore: downloads)
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(try Data(contentsOf: occupied) == replacement)
        let recovered = downloads.directory.appendingPathComponent("Clip (2).mp4")
        #expect(try Data(contentsOf: recovered) == ownedBytes)
        #expect(await store.job(id: j.id)?.savedFilename == "Clip (2).mp4")
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    @Test func completedAdaptiveReplacementUsesCheckpointBeforeDeletingSources() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)),
                    state: .completed, savedFilename: "Clip.mp4")
        try await store.upsert(j)
        let video = store.partFileURL(for: "v.part")
        let audio = store.partFileURL(for: "a.part")
        try Data(repeating: 3, count: 300).write(to: video)
        try Data(repeating: 4, count: 100).write(to: audio)
        let ownedBytes = Data("owned merged output".utf8)
        let checkpoint = store.partFileURL(for: j.finalizationPromotionCheckpointFileName)
        try ownedBytes.write(to: checkpoint)
        let occupied = downloads.directory.appendingPathComponent("Clip.mp4")
        let replacement = Data("unrelated".utf8)
        try replacement.write(to: occupied)
        let merger = MockMerger()

        let fin = TransferFinalizer(store: store, merger: merger, downloadStore: downloads)
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(merger.received == nil)
        #expect(try Data(contentsOf: occupied) == replacement)
        #expect(try Data(contentsOf: downloads.directory.appendingPathComponent("Clip (2).mp4"))
                == ownedBytes)
        #expect(!FileManager.default.fileExists(atPath: video.path))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    @Test func replacementAfterCompletedBeforeStoreRemovalRecoversFromRetainedIdentity() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)))
        try await store.upsert(j)
        let ownedBytes = Data(repeating: 5, count: 500)
        try ownedBytes.write(to: store.partFileURL(for: "p.part"))
        let fin = TransferFinalizer(store: store, merger: MockMerger(), downloadStore: downloads)
        #expect(await fin.finalizeReadyJobs() == [j.id])
        let checkpoint = store.partFileURL(for: j.finalizationPromotionCheckpointFileName)
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))

        let original = downloads.directory.appendingPathComponent("Clip.mp4")
        try FileManager.default.removeItem(at: original)
        let replacement = Data(repeating: 9, count: 500)
        try replacement.write(to: original)

        let recovered = await fin.finalizeReadyJobs()

        #expect(recovered == [j.id])
        #expect(try Data(contentsOf: original) == replacement)
        #expect(try Data(contentsOf: downloads.directory.appendingPathComponent("Clip (2).mp4"))
                == ownedBytes)
        #expect(FileManager.default.fileExists(atPath: checkpoint.path))
    }

    @Test func completedLegacyEqualLengthReplacementReFinalizesFromRetainedSource() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .completed, savedFilename: "Clip.mp4")
        try await store.upsert(j)
        let sourceBytes = Data(repeating: 7, count: 500)
        let replacement = Data(repeating: 8, count: 500)
        try sourceBytes.write(to: store.partFileURL(for: "p.part"))
        let occupied = downloads.directory.appendingPathComponent("Clip.mp4")
        try replacement.write(to: occupied)

        let fin = TransferFinalizer(store: store, merger: MockMerger(), downloadStore: downloads)
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(try Data(contentsOf: occupied) == replacement)
        #expect(try Data(contentsOf: downloads.directory.appendingPathComponent("Clip (2).mp4"))
                == sourceBytes)
    }

    @Test func adaptiveMergesBothPartsAndCompletes() async throws {
        let (store, downloads) = try makeStores(tempDir())
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
        #expect(done.savedFilename == "Clip.mp4")
        #expect(merger.received != nil)
        #expect(!FileManager.default.fileExists(atPath: store.partFileURL(for: "v.part").path))
        #expect(!FileManager.default.fileExists(atPath: store.partFileURL(for: "a.part").path))
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentFinalizePassesDoNotRepeatAdaptiveMerge() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)))
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))
        let merger = SuspendedMerger()
        let fin = TransferFinalizer(store: store, merger: merger, downloadStore: downloads)

        async let firstPass = fin.finalizeReadyJobs()
        await merger.waitUntilStarted()
        let overlappingPass = await fin.finalizeReadyJobs()
        #expect(overlappingPass.isEmpty)
        #expect(await merger.callCount() == 1)

        await merger.release()
        #expect(await firstPass == [j.id])
        #expect(await merger.callCount() == 1)
    }

    @Test func persistedMergingProgressiveJobRetriesAtReservedDestination() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .merging, savedFilename: "Clip (2).mp4")
        try await store.upsert(j)
        let source = store.partFileURL(for: "p.part")
        try Data(repeating: 1, count: 500).write(to: source)
        // A new collision appearing after the destination was reserved must not cause recovery
        // to choose a third filename.
        try Data("other download".utf8).write(
            to: downloads.directory.appendingPathComponent("Clip.mp4"))

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(await store.job(id: j.id)?.state == .completed)
        #expect(await store.job(id: j.id)?.savedFilename == "Clip (2).mp4")
        #expect(FileManager.default.fileExists(
            atPath: downloads.directory.appendingPathComponent("Clip (2).mp4").path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func persistedProgressiveReadyStageIsPromotedWithoutRecreatingIt() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .merging, savedFilename: "Clip.mp4",
                    finalizationPhase: .preparing)
        try await store.upsert(j)
        let bytes = Data(repeating: 7, count: 500)
        let destination = downloads.directory.appendingPathComponent("Clip.mp4")
        // Models a crash after the atomic source-to-ready move but before the ready checkpoint.
        try bytes.write(to: store.partFileURL(for: j.finalizationReadyFileName))

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(await store.job(id: j.id)?.state == .completed)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(
            atPath: store.partFileURL(for: j.finalizationReadyFileName).path))
    }

    @Test func incompleteProgressiveReadyStageRetainsItsOnlyBytes() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .merging, savedFilename: "Clip.mp4",
                    finalizationPhase: .preparing)
        try await store.upsert(j)
        let ready = store.partFileURL(for: j.finalizationReadyFileName)
        let retained = Data(repeating: 7, count: 100)
        try retained.write(to: ready)

        let fin = TransferFinalizer(store: store, merger: MockMerger(), downloadStore: downloads)
        let completed = await fin.finalizeReadyJobs()

        #expect(completed.isEmpty)
        #expect(await store.job(id: j.id)?.state == .failed(.integrityCheckFailed))
        #expect(try Data(contentsOf: ready) == retained,
                "an invalid checkpoint must not delete the job's only retained bytes")
    }

    @Test func promotedProgressiveOutputSurvivesFailedCompletionPersistence() async throws {
        let storage = try TemporaryTransferJobStore()
        let transferDirectory = storage.directory
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .merging, savedFilename: "Clip.mp4",
                    finalizationPhase: .readyToPromote)
        try await store.upsert(j)
        let bytes = Data(repeating: 9, count: 500)
        let source = store.partFileURL(for: "p.part")
        let destination = downloads.directory.appendingPathComponent("Clip.mp4")
        try installPromotedOutput(bytes, for: j, store: store, destination: destination)

        // The destination reservation is already durable. Make the store directory read-only so
        // the next atomic write (`.completed`) fails after output I/O has succeeded.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: transferDirectory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: transferDirectory.path)
        }

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed.isEmpty)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(await store.job(id: j.id)?.state == .merging)

        // Both the current actor and a relaunch see the same retryable durable state.
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: transferDirectory.path)
        let reloaded = try TransferJobStore(directory: transferDirectory)
        #expect(await reloaded.job(id: j.id)?.state == .merging)

        let retried = await fin.finalizeReadyJobs()
        #expect(retried == [j.id])
        #expect(await store.job(id: j.id)?.state == .completed)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func completeRecoveredProgressiveOutputNeedsNoAdditionalDiskSpace() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .merging, savedFilename: "Clip.mp4",
                    finalizationPhase: .readyToPromote)
        try await store.upsert(j)
        let bytes = Data(repeating: 4, count: 500)
        let source = store.partFileURL(for: "p.part")
        let destination = downloads.directory.appendingPathComponent("Clip.mp4")
        try installPromotedOutput(bytes, for: j, store: store, destination: destination)

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 0))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(await store.job(id: j.id)?.state == .completed)
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func progressiveAtomicMoveNeedsNoAdditionalDiskSpace() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .progressive(track(part: "p.part", total: 500)))
        try await store.upsert(j)
        let source = store.partFileURL(for: "p.part")
        try Data(repeating: 4, count: 500).write(to: source)

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 100))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(await store.job(id: j.id)?.state == .completed)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(
            atPath: downloads.directory.appendingPathComponent("Clip.mp4").path))
    }

    @Test func persistedMergingAdaptiveJobReusesReservedDestination() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)),
                    state: .merging, savedFilename: "Clip (2).mp4")
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))

        let merger = MockMerger()
        let fin = TransferFinalizer(store: store, merger: merger,
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(merger.received?.output.lastPathComponent == j.finalizationPartialFileName)
        #expect(await store.job(id: j.id)?.state == .completed)
    }

    @Test func equalLengthDifferentProgressiveOccupantIsPreserved() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .merging, savedFilename: "Clip.mp4")
        try await store.upsert(j)
        let sourceBytes = Data(repeating: 1, count: 500)
        let occupantBytes = Data(repeating: 2, count: 500)
        try sourceBytes.write(to: store.partFileURL(for: "p.part"))
        let occupied = downloads.directory.appendingPathComponent("Clip.mp4")
        try occupantBytes.write(to: occupied)

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(try Data(contentsOf: occupied) == occupantBytes)
        let done = await store.job(id: j.id)
        #expect(done?.savedFilename == "Clip (2).mp4")
        #expect(try Data(contentsOf: downloads.directory.appendingPathComponent("Clip (2).mp4"))
                == sourceBytes)
    }

    @Test func adaptiveReservedDestinationCollisionIsPreservedAndReallocated() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)),
                    state: .merging, savedFilename: "Clip.mp4")
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))
        let occupied = downloads.directory.appendingPathComponent("Clip.mp4")
        let occupant = Data("keep me".utf8)
        try occupant.write(to: occupied)

        let merger = MockMerger()
        let fin = TransferFinalizer(store: store, merger: merger,
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(try Data(contentsOf: occupied) == occupant)
        #expect(merger.received?.output.lastPathComponent == j.finalizationPartialFileName)
        #expect(await store.job(id: j.id)?.savedFilename == "Clip (2).mp4")
    }

    @Test func persistedCompletedJobIsReturnedAndItsRetainedPartsAreCleaned() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .completed, savedFilename: "Clip.mp4")
        try await store.upsert(j)
        let part = store.partFileURL(for: "p.part")
        try Data(repeating: 1, count: 500).write(to: part)
        try Data(repeating: 1, count: 500).write(
            to: downloads.directory.appendingPathComponent("Clip.mp4"))

        let fin = TransferFinalizer(store: store, merger: MockMerger(), downloadStore: downloads)
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(await store.job(id: j.id)?.state == .completed)
        #expect(!FileManager.default.fileExists(atPath: part.path))
    }

    @Test func completedJobWithMissingOutputRetainsPartsWhenRecoveryCannotFinish() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)),
                    state: .completed, savedFilename: "Clip.mp4")
        try await store.upsert(j)
        let video = store.partFileURL(for: "v.part")
        let audio = store.partFileURL(for: "a.part")
        try Data(repeating: 2, count: 300).write(to: video)
        try Data(repeating: 3, count: 100).write(to: audio)
        let merger = MockMerger()
        merger.shouldFail = true

        let fin = TransferFinalizer(store: store, merger: merger, downloadStore: downloads)
        let completed = await fin.finalizeReadyJobs()

        #expect(completed.isEmpty, "a missing saved output is not a deliverable")
        #expect(await store.job(id: j.id)?.state == .failed(.mergeFailed))
        #expect(FileManager.default.fileExists(atPath: video.path))
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func completedProgressiveJobWithIncompleteOutputReFinalizesWithoutOverwritingIt() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let downloads = try makeDownloadStore(storage.directory)
        let j = job(kind: .progressive(track(part: "p.part", total: 500)),
                    state: .completed, savedFilename: "Clip.mp4")
        try await store.upsert(j)
        let sourceBytes = Data(repeating: 8, count: 500)
        try sourceBytes.write(to: store.partFileURL(for: "p.part"))
        let incomplete = downloads.directory.appendingPathComponent("Clip.mp4")
        let occupantBytes = Data(repeating: 4, count: 100)
        try occupantBytes.write(to: incomplete)

        let fin = TransferFinalizer(store: store, merger: MockMerger(), downloadStore: downloads)
        let completed = await fin.finalizeReadyJobs()

        #expect(completed == [j.id])
        #expect(try Data(contentsOf: incomplete) == occupantBytes)
        let recovered = try #require(await store.job(id: j.id))
        #expect(recovered.state == .completed)
        #expect(recovered.savedFilename == "Clip (2).mp4")
        #expect(try Data(contentsOf: downloads.directory.appendingPathComponent("Clip (2).mp4"))
                == sourceBytes)
    }

    @Test(arguments: [false, true])
    func malformedProgressiveAndAdaptiveRecoveryCannotReachOutsideDirectory(
        _ isAdaptive: Bool
    ) async throws {
        let storage = try TemporaryTransferJobStore()
        let outsideDirectory = storage.directory.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDirectory, withIntermediateDirectories: true)
        let sentinelURL = outsideDirectory.appendingPathComponent("sentinel")
        let sentinel = Data("outside".utf8)
        try sentinel.write(to: sentinelURL)

        let malicious = track(part: "../outside/sentinel", total: Int64(sentinel.count))
        let kind: TransferJob.Kind
        if isAdaptive {
            let audio = track(part: "safe.part", total: 1)
            kind = .adaptive(video: malicious, audio: audio)
            try Data([1]).write(to: storage.store.partFileURL(for: "safe.part"))
        } else {
            kind = .progressive(malicious)
        }
        let persisted = job(kind: kind, state: .merging, savedFilename: "Clip.mp4")
        try JSONEncoder().encode([persisted]).write(
            to: storage.directory.appendingPathComponent("transfers.json"), options: .atomic)

        let reloaded = try storage.reloadedStore()
        let downloads = try makeDownloadStore(storage.directory)
        let fin = TransferFinalizer(store: reloaded, merger: MockMerger(), downloadStore: downloads)
        let completed = await fin.finalizeReadyJobs()

        #expect(completed.isEmpty)
        #expect(try Data(contentsOf: sentinelURL) == sentinel)
        #expect(FileManager.default.fileExists(atPath: outsideDirectory.path))
    }

    @Test func truncatedPartFailsIntegrityCheck() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .progressive(track(part: "p.part", total: 500)))
        try await store.upsert(j)
        try Data(repeating: 1, count: 400).write(to: store.partFileURL(for: "p.part"))   // short!

        let fin = TransferFinalizer(store: store, merger: MockMerger(),
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        _ = await fin.finalizeReadyJobs()
        #expect(await store.job(id: j.id)!.state == .failed(.integrityCheckFailed))
    }

    private func makeDownloadStore(_ base: URL) throws -> DownloadStore {
        let downloads = DownloadStore(directory: base.appendingPathComponent("downloads"))
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        return downloads
    }

    @Test func insufficientDiskFailsBeforeMerge() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)))
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))

        let merger = MockMerger()
        let fin = TransferFinalizer(store: store, merger: merger,
                                    downloadStore: downloads, disk: FixedDisk(cap: 100))   // < 400 needed
        _ = await fin.finalizeReadyJobs()
        #expect(await store.job(id: j.id)!.state == .failed(.insufficientSpace))
        #expect(merger.received == nil)
    }

    @Test func mergeFailureIsReportedAndPartsRetained() async throws {
        let (store, downloads) = try makeStores(tempDir())
        let j = job(kind: .adaptive(video: track(part: "v.part", total: 300),
                                    audio: track(part: "a.part", total: 100)))
        try await store.upsert(j)
        try Data(repeating: 2, count: 300).write(to: store.partFileURL(for: "v.part"))
        try Data(repeating: 3, count: 100).write(to: store.partFileURL(for: "a.part"))

        let merger = MockMerger(); merger.shouldFail = true
        let fin = TransferFinalizer(store: store, merger: merger,
                                    downloadStore: downloads, disk: FixedDisk(cap: 1_000_000))
        _ = await fin.finalizeReadyJobs()
        // A mux failure is a MERGE failure, not an integrity/incomplete-data failure — the
        // parts passed the length check above. Reporting it as `.integrityCheckFailed` would
        // mislead the user ("File check failed / data was incomplete").
        #expect(await store.job(id: j.id)!.state == .failed(.mergeFailed))
        #expect(FileManager.default.fileExists(atPath: store.partFileURL(for: "v.part").path))
    }

    @Test func publishesCompletedSnapshot() async throws {
        let base = tempDir()
        let (store, downloads) = try makeStores(base)
        let bus = TransferProgress()
        let j = job(kind: .progressive(track(part: "p.part", total: 500)))
        try await store.upsert(j)
        try Data(repeating: 1, count: 500).write(to: store.partFileURL(for: "p.part"))
        let fin = TransferFinalizer(store: store, merger: MockMerger(), downloadStore: downloads, progress: bus)
        _ = await fin.finalizeReadyJobs()
        #expect(await store.job(id: j.id)?.state == .completed)
        #expect(await bus.snapshot(for: j.id)?.state == .completed)
    }
}
