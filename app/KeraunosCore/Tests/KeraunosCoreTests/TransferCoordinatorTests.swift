import Testing
import Foundation
import KeraunosCore

struct TransferCoordinatorTests {
    // MARK: fixtures
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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

    @Test func appliesPersistedRequestHeaders() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        var t = track(part: "p.part", chunkSize: nil)
        t.requestHeaders = ["User-Agent": "yt", "Cookie": "a=b"]
        try await coord.start(job(kind: .progressive(t)))
        let req = await session.started[0].request
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "yt")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "a=b")
    }

    @Test func reassociateResumeFailureSurfacesAsFailedNotSilentStall() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        // A downloading job whose task vanished while suspended.
        var t = track(part: "c.part", chunkSize: 100, bytesWritten: 50, totalBytes: 250)
        t.taskIdentifier = 42
        try await store.upsert(job(kind: .progressive(t), state: .downloading))
        await session.setStartError(URLError(.notConnectedToInternet))   // resume can't start
        await session.setLive([])                                        // task 42 gone

        let spy = SpyDiagnostics()
        let coord = TransferCoordinator(store: store, session: session, diagnostics: spy)
        await coord.reassociateAndResume()

        // The failed resume is surfaced (retryable) AND recorded — not swallowed.
        #expect(await store.all().first!.state == .failed(.network))
        #expect(spy.kinds.contains("transfer_resume_failed"))
    }

    // MARK: media-URL refresh

    @Test func status403RoutesToNeedsRefresh() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data()),
                                             statusCode: 403, contentRangeTotal: nil)
        #expect(await store.job(id: j.id)!.state == .needsRefresh)
    }

    @Test func expiredURLDoesNotStartAndNeedsRefresh() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let now = Date(timeIntervalSince1970: 2000)
        let coord = TransferCoordinator(store: store, session: session, now: { now })
        var t = track(part: "c.part", chunkSize: 100)
        t.urlExpiresAt = Date(timeIntervalSince1970: 1000)      // already past `now`
        try await coord.start(job(kind: .progressive(t)))
        #expect(await session.started.isEmpty)                 // never issued a doomed request
        #expect(await store.all().first!.state == .needsRefresh)
    }

    @Test func refreshWithMatchingLengthResumesFromOffset() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: 250)
        let id2 = await session.started[1].id
        await coord.taskDidFinishDownloading(taskIdentifier: id2, to: stage(Data()),
                                             statusCode: 403, contentRangeTotal: nil)
        #expect(await store.job(id: j.id)!.state == .needsRefresh)

        let fresh = URL(string: "https://r2.googlevideo.com/vp?expire=9999999999")!
        try await coord.refresh(jobID: j.id, freshURL: fresh,
                                freshExpiresAt: Date(timeIntervalSince1970: 9_999_999_999),
                                freshContentLength: 250)          // matches persisted total
        let after = await store.job(id: j.id)!
        #expect(after.state == .downloading)
        #expect(after.tracks[0].bytesWritten == 100)             // resumed, not reset
        #expect(after.tracks[0].remoteURL == fresh)
        #expect(await session.lastRange() == "bytes=100-199")
    }

    @Test func refreshWithDifferentLengthRestartsTrack() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: 250)
        let id2 = await session.started[1].id
        await coord.taskDidFinishDownloading(taskIdentifier: id2, to: stage(Data()),
                                             statusCode: 410, contentRangeTotal: nil)

        let fresh = URL(string: "https://r3.googlevideo.com/vp")!
        try await coord.refresh(jobID: j.id, freshURL: fresh, freshExpiresAt: nil,
                                freshContentLength: 999)          // DIFFERENT length → restart
        let after = await store.job(id: j.id)!
        #expect(after.state == .downloading)
        #expect(after.tracks[0].bytesWritten == 0)               // restarted
        #expect(await session.lastRange() == "bytes=0-99")
        #expect(FileManager.default.fileSize(store.partFileURL(for: "c.part")) == 0)
    }

    // MARK: progress publication

    @Test func publishesDownloadingSnapshotOnStart() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
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
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
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
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let bus = TransferProgress()
        let coord = TransferCoordinator(store: store, session: session, progress: bus)
        await coord.taskDidWriteData(taskIdentifier: 999, totalBytesWritten: 1, totalBytesExpectedToWrite: 2)
        #expect(await bus.current().isEmpty)
    }
}

private extension URL { var pathExists: Bool { FileManager.default.fileExists(atPath: path) } }
private extension FileManager {
    /// Fresh on-disk size via `attributesOfItem` — NOT `URL.resourceValues`, which caches
    /// the size on the URL and would return a stale length after a truncate.
    func fileSize(_ url: URL) -> Int64 {
        let attrs: [FileAttributeKey: Any]
        do { attrs = try attributesOfItem(atPath: url.path) } catch { return -1 }
        return (attrs[.size] as? NSNumber)?.int64Value ?? -1
    }
}
