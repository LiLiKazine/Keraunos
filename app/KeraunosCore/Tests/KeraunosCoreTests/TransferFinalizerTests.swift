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

    private func makeStores(_ base: URL) throws -> (TransferJobStore, DownloadStore) {
        let store = try TransferJobStore(directory: base.appendingPathComponent("transfers"))
        let downloads = DownloadStore(directory: base.appendingPathComponent("downloads"))
        try FileManager.default.createDirectory(at: downloads.directory, withIntermediateDirectories: true)
        return (store, downloads)
    }

    @Test func progressiveMovesPartIntoStoreAndCompletes() async throws {
        let (store, downloads) = try makeStores(tempDir())
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
        #expect(!FileManager.default.fileExists(atPath: store.partFileURL(for: "p.part").path))
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
        #expect(await store.job(id: j.id)!.state == .failed(.integrityCheckFailed))
        #expect(FileManager.default.fileExists(atPath: store.partFileURL(for: "v.part").path))
    }
}
