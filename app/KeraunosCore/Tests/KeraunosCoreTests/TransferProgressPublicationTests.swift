import Testing
import Foundation
import KeraunosCore

/// Every `TransferCoordinator` transition must reach the progress bus. The queue UI rebuilds
/// **only** when the bus emits (`DownloadsViewModel.start`), so a transition that mutates the
/// store without publishing leaves the row rendering stale — a download that looks live after
/// it stopped, or a failure that never surfaces. State-persistence tests can't catch that:
/// they read the store, which is always correct. These read the bus.
@Suite struct TransferProgressPublicationTests {
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
                       totalBytes: Int64? = nil, expiresAt: Date? = nil) -> TrackJob {
        TrackJob(remoteURL: URL(string: "https://cdn.example/\(part)")!,
                 urlExpiresAt: expiresAt, chunkSize: chunkSize, partFileName: part,
                 bytesWritten: bytesWritten, totalBytes: totalBytes,
                 resumeData: nil, taskIdentifier: nil)
    }
    private func job(id: UUID = UUID(), kind: TransferJob.Kind, state: JobState = .queued) -> TransferJob {
        TransferJob(id: id, sourcePageURL: URL(string: "https://ex.com")!,
                    formatSelection: FormatSelection(formatID: "x", height: nil, isAdaptive: false),
                    credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
                    state: state, kind: kind, suggestedFilename: "f.mp4",
                    savedFilename: nil, autoSaveToPhotos: false)
    }

    private struct Rig {
        let directory: URL
        let store: TransferJobStore
        let session: ScriptedTransferSession
        let bus: TransferProgress
        let coord: TransferCoordinator
    }
    private func rig(now: Date? = nil) throws -> Rig {
        let directory = tempDir()
        let store = try TransferJobStore(directory: directory)
        let session = ScriptedTransferSession()
        let bus = TransferProgress()
        let coord = TransferCoordinator(store: store, session: session,
                                        now: { now ?? Date() }, progress: bus)
        return Rig(directory: directory, store: store, session: session, bus: bus, coord: coord)
    }

    /// The invariant: after any transition the bus carries a snapshot whose state matches the
    /// persisted job and whose bytes match the summed track offsets. A missing `publish` shows
    /// up as either no snapshot at all or a stale state.
    private func expectBusMatchesStore(_ r: Rig, _ id: UUID,
                                       sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let job = await r.store.job(id: id) else {
            Issue.record("no persisted job \(id)", sourceLocation: sourceLocation); return
        }
        guard let snap = await r.bus.snapshot(for: id) else {
            Issue.record("nothing published for \(id)", sourceLocation: sourceLocation); return
        }
        #expect(snap.state == job.state, sourceLocation: sourceLocation)
        #expect(snap.receivedBytes == job.tracks.reduce(0) { $0 + $1.bytesWritten },
                sourceLocation: sourceLocation)
    }

    // MARK: start

    @Test func startOnAnAlreadyCompleteJobPublishesReadyToMerge() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil,
                                             bytesWritten: 500, totalBytes: 500)))
        try await r.coord.start(j)
        #expect(await r.bus.snapshot(for: j.id)?.state == .readyToMerge)
        await expectBusMatchesStore(r, j.id)
    }

    // MARK: pause & resume

    @Test func pausePublishesPaused() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: 1_048_576,
                                             bytesWritten: 100, totalBytes: 4_000_000)),
                    state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        await r.coord.pause(jobID: j.id)
        #expect(await r.bus.snapshot(for: j.id)?.state == .paused)
        await expectBusMatchesStore(r, j.id)
    }

    @Test func resumePublishesDownloading() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: 1_048_576,
                                             bytesWritten: 100, totalBytes: 4_000_000)),
                    state: .paused)
        try await r.store.upsert(j)
        try await r.coord.resume(jobID: j.id)
        #expect(await r.bus.snapshot(for: j.id)?.state == .downloading)
        await expectBusMatchesStore(r, j.id)
    }

    // MARK: refresh

    @Test func refreshKeepingOffsetPublishesDownloading() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100,
                                             bytesWritten: 100, totalBytes: 400)),
                    state: .needsRefresh)
        try await r.store.upsert(j)
        try await r.coord.refresh(jobID: j.id, freshURL: URL(string: "https://cdn.example/new")!,
                                  freshExpiresAt: nil, freshContentLength: 400)
        #expect(await r.bus.snapshot(for: j.id)?.state == .downloading)
        #expect(await r.bus.snapshot(for: j.id)?.receivedBytes == 100)   // offset kept
        await expectBusMatchesStore(r, j.id)
    }

    @Test func refreshWithADifferentLengthPublishesZeroedProgress() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100,
                                             bytesWritten: 100, totalBytes: 400)),
                    state: .needsRefresh)
        try await r.store.upsert(j)
        try await r.coord.refresh(jobID: j.id, freshURL: URL(string: "https://cdn.example/new")!,
                                  freshExpiresAt: nil, freshContentLength: 999)
        let snap = await r.bus.snapshot(for: j.id)
        #expect(snap?.state == .downloading)
        #expect(snap?.receivedBytes == 0)          // track restarted — the bar must go back
        #expect(snap?.totalBytes == 999)
        await expectBusMatchesStore(r, j.id)
    }

    // MARK: failure & recovery ingress

    @Test func unexpectedStatusPublishesFailed() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)), state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id
        await r.coord.taskDidFinishDownloading(taskIdentifier: taskID, to: stage(Data()),
                                               statusCode: 500, contentRangeTotal: nil)
        #expect(await r.bus.snapshot(for: j.id)?.state == .failed(.network))
        await expectBusMatchesStore(r, j.id)
    }

    @Test func corruptionAtANonZeroOffsetPublishesFailed() async throws {
        let r = try rig()
        // 200 (whole body) after we already wrote 50 bytes would corrupt the part file.
        let j = job(kind: .progressive(track(part: "x.part", chunkSize: 100,
                                             bytesWritten: 50, totalBytes: 400)),
                    state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id
        await r.coord.taskDidFinishDownloading(taskIdentifier: taskID,
                                               to: stage(Data(repeating: 1, count: 400)),
                                               statusCode: 200, contentRangeTotal: nil)
        #expect(await r.bus.snapshot(for: j.id)?.state == .failed(.network))
        await expectBusMatchesStore(r, j.id)
    }

    @Test func forbiddenStatusPublishesNeedsRefresh() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)), state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id
        await r.coord.taskDidFinishDownloading(taskIdentifier: taskID, to: stage(Data()),
                                               statusCode: 403, contentRangeTotal: nil)
        #expect(await r.bus.snapshot(for: j.id)?.state == .needsRefresh)
        await expectBusMatchesStore(r, j.id)
    }

    @Test func expiredURLPublishesNeedsRefresh() async throws {
        let r = try rig(now: Date(timeIntervalSince1970: 10_000))
        let expired = track(part: "c.part", chunkSize: 100,
                            expiresAt: Date(timeIntervalSince1970: 9_000))
        let j = job(kind: .progressive(expired))
        try await r.coord.start(j)
        #expect(await r.session.started.isEmpty)                 // never fired a doomed request
        #expect(await r.bus.snapshot(for: j.id)?.state == .needsRefresh)
        await expectBusMatchesStore(r, j.id)
    }

    /// A network drop mid-transfer. The job *state* stays `.downloading` — only the track's
    /// `taskIdentifier` is cleared — which flips the ROW to "Waiting (background)". Because the
    /// state is unchanged, a state comparison can't prove a publish happened, so seed the bus
    /// with a snapshot the coordinator could never derive and assert it gets overwritten.
    @Test func taskFailurePublishesSoTheRowStopsClaimingALiveDownload() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil, totalBytes: 1_000_000)),
                    state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id

        await r.bus.set(ProgressSnapshot(state: .downloading, receivedBytes: 999_999,
                                         totalBytes: 1_000_000), for: j.id)
        await r.coord.taskDidFail(taskIdentifier: taskID, resumeData: nil, isCancelled: false)

        #expect(await r.store.job(id: j.id)?.rowState == .waitingBackground)
        #expect(await r.bus.snapshot(for: j.id)?.receivedBytes == 0)   // republished from the store
        await expectBusMatchesStore(r, j.id)
    }

    // MARK: learning a single-shot track's total from the delegate

    /// A single-shot (non-chunked) track's total was previously only recorded at *completion*,
    /// so the whole download published `totalBytes: nil` and the row showed an indeterminate
    /// bar with "Downloading…" instead of a percentage — on every site except YouTube's
    /// chunk-hinted formats. `URLSession` hands us the real `Content-Length` on every progress
    /// callback; use it.
    @Test func singleShotLearnsItsTotalFromTheFirstProgressCallback() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil)), state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id

        await r.coord.taskDidWriteData(taskIdentifier: taskID, totalBytesWritten: 500,
                                       totalBytesExpectedToWrite: 4000)

        let snap = await r.bus.snapshot(for: j.id)
        #expect(snap?.receivedBytes == 500)
        #expect(snap?.totalBytes == 4000)
        #expect(snap?.fraction == 0.125)      // determinate from the first callback
    }

    /// Persisted, not just published — a relaunch rebuilds the bus from the store, so a
    /// determinate bar must survive it rather than reverting to indeterminate.
    @Test func theLearnedTotalIsPersisted() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil)), state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id
        await r.coord.taskDidWriteData(taskIdentifier: taskID, totalBytesWritten: 500,
                                       totalBytesExpectedToWrite: 4000)

        let reloaded = try TransferJobStore(directory: r.directory)
        #expect(await reloaded.job(id: j.id)?.tracks[0].totalBytes == 4000)
    }

    /// The critical guard: on a **ranged** request `totalBytesExpectedToWrite` is the CHUNK's
    /// length, not the file's. Adopting it would peg a multi-gigabyte YouTube track's total at
    /// one chunk and show a bar that fills and resets on every chunk.
    @Test func chunkedTrackNeverAdoptsTheChunkLengthAsItsTotal() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)), state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id

        await r.coord.taskDidWriteData(taskIdentifier: taskID, totalBytesWritten: 40,
                                       totalBytesExpectedToWrite: 100)

        #expect(await r.bus.snapshot(for: j.id)?.totalBytes == nil)   // stays indeterminate
        #expect(await r.store.job(id: j.id)?.tracks[0].totalBytes == nil)
    }

    @Test func chunkedTrackWithAKnownTotalIsNotOverwritten() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100, totalBytes: 4000)),
                    state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id

        await r.coord.taskDidWriteData(taskIdentifier: taskID, totalBytesWritten: 40,
                                       totalBytesExpectedToWrite: 100)

        #expect(await r.bus.snapshot(for: j.id)?.totalBytes == 4000)
    }

    /// A server that sends no `Content-Length` yields `NSURLSessionTransferSizeUnknown` (-1).
    /// It must not become a total (a negative or zero total would poison `fraction`).
    @Test func anUnknownExpectedSizeIsIgnoredButBytesStillPublish() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil)), state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id

        await r.coord.taskDidWriteData(taskIdentifier: taskID, totalBytesWritten: 500,
                                       totalBytesExpectedToWrite: -1)

        let snap = await r.bus.snapshot(for: j.id)
        #expect(snap?.totalBytes == nil)
        #expect(snap?.fraction == nil)
        #expect(snap?.receivedBytes == 500)      // still counts up
        #expect(await r.store.job(id: j.id)?.tracks[0].totalBytes == nil)
    }

    /// Completion remains authoritative: the 200 path records the bytes actually written, so a
    /// server that lied in `Content-Length` can't leave a wrong total behind for the finalizer's
    /// integrity check to compare against.
    @Test func completionOverwritesALearnedTotalWithTheActualLength() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil)), state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id
        await r.coord.taskDidWriteData(taskIdentifier: taskID, totalBytesWritten: 300,
                                       totalBytesExpectedToWrite: 4000)   // server over-reported

        await r.coord.taskDidFinishDownloading(taskIdentifier: taskID,
                                               to: stage(Data(repeating: 1, count: 300)),
                                               statusCode: 200, contentRangeTotal: nil)

        let done = await r.store.job(id: j.id)!
        #expect(done.tracks[0].totalBytes == 300)
        #expect(done.state == .readyToMerge)
        await expectBusMatchesStore(r, j.id)
    }

    // MARK: chunked progression

    @Test func midSequenceChunkPublishesAdvancingBytes() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100, totalBytes: 400)),
                    state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id
        await r.coord.taskDidFinishDownloading(taskIdentifier: taskID,
                                               to: stage(Data(repeating: 1, count: 100)),
                                               statusCode: 206, contentRangeTotal: 400)
        let snap = await r.bus.snapshot(for: j.id)
        #expect(snap?.state == .downloading)        // more chunks to come
        #expect(snap?.receivedBytes == 100)
        #expect(snap?.totalBytes == 400)
        await expectBusMatchesStore(r, j.id)
    }

    @Test func finalShortChunkPublishesReadyToMerge() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)), state: .downloading)
        try await r.store.upsert(j)
        try await r.coord.start(j)
        let taskID = await r.session.started[0].id
        await r.coord.taskDidFinishDownloading(taskIdentifier: taskID,
                                               to: stage(Data(repeating: 1, count: 40)),
                                               statusCode: 206, contentRangeTotal: nil)
        #expect(await r.bus.snapshot(for: j.id)?.state == .readyToMerge)
        await expectBusMatchesStore(r, j.id)
    }

    // MARK: relaunch

    /// The bus is rebuilt from the persisted store on launch (no closure survives the process),
    /// so reassociation must repopulate it — otherwise the queue renders nothing until the
    /// first byte delta arrives.
    @Test func reassociateRepublishesAResumedJob() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100,
                                             bytesWritten: 200, totalBytes: 400)),
                    state: .downloading)
        try await r.store.upsert(j)
        await r.session.setLive([])                  // its task died while suspended
        await r.coord.reassociateAndResume()
        let snap = await r.bus.snapshot(for: j.id)
        #expect(snap?.state == .downloading)
        #expect(snap?.receivedBytes == 200)
        await expectBusMatchesStore(r, j.id)
    }

    @Test func reassociatePublishesReadyToMergeForAFinishedJob() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "p.part", chunkSize: nil,
                                             bytesWritten: 500, totalBytes: 500)),
                    state: .downloading)
        try await r.store.upsert(j)
        await r.coord.reassociateAndResume()
        #expect(await r.bus.snapshot(for: j.id)?.state == .readyToMerge)
        await expectBusMatchesStore(r, j.id)
    }

    @Test func reassociateResumeFailurePublishesFailed() async throws {
        let r = try rig()
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100,
                                             bytesWritten: 200, totalBytes: 400)),
                    state: .downloading)
        try await r.store.upsert(j)
        await r.session.setStartError(KeraunosError.downloadNetwork)
        await r.coord.reassociateAndResume()
        #expect(await r.bus.snapshot(for: j.id)?.state == .failed(.network))
        await expectBusMatchesStore(r, j.id)
    }
}
