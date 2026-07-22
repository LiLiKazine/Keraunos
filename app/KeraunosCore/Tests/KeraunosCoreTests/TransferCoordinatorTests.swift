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

    // MARK: chunked driver

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

    // MARK: resume & relaunch reassociation

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
        let firstChunk = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: firstChunk, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: 250)
        // The 2nd-chunk task (100-199) is now live. Simulate a crash that appended an
        // un-recorded tail to the part file before dying (offset was never persisted).
        let partURL = store.partFileURL(for: "c.part")
        let handle = try FileHandle(forWritingTo: partURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 9, count: 30))
        try handle.close()
        #expect(FileManager.default.fileSize(partURL) == 130)

        // Fresh coordinator (in-memory owners lost), task 2 vanished from the OS.
        let coord2 = TransferCoordinator(store: store, session: session)
        await session.setLive([])
        await coord2.reassociateAndResume()
        #expect(FileManager.default.fileSize(partURL) == 100)   // tail truncated to persisted offset
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

        await coord2.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 50)),
                                              statusCode: 206, contentRangeTotal: 50)
        #expect(await store.job(id: j.id)!.state == .readyToMerge)
    }
}

private extension URL { var pathExists: Bool { FileManager.default.fileExists(atPath: path) } }
private extension FileManager {
    /// Fresh on-disk size via `attributesOfItem` — NOT `URL.resourceValues`, which caches
    /// the size on the URL and would return a stale length after a truncate.
    func fileSize(_ url: URL) -> Int64 {
        let attrs = try? attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? -1
    }
}
