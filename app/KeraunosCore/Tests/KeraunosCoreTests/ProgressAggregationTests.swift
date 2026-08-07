import Testing
import Foundation
@testable import KeraunosCore

/// Whole-file progress math for `TransferCoordinator.snapshot(for:liveReceived:)` — the
/// function every publish site funnels through. Adaptive (DASH) jobs are the interesting
/// case: two tracks download *sequentially*, so a naive per-track fraction would run to
/// 100% at the video handoff and then restart.
@Suite struct ProgressAggregationTests {
    private func track(_ part: String, bytesWritten: Int64, totalBytes: Int64?) -> TrackJob {
        TrackJob(remoteURL: URL(string: "https://cdn.example/\(part)")!,
                 urlExpiresAt: nil, chunkSize: nil, partFileName: part,
                 bytesWritten: bytesWritten, totalBytes: totalBytes,
                 resumeData: nil, taskIdentifier: nil)
    }
    private func job(_ kind: TransferJob.Kind, state: JobState = .downloading) -> TransferJob {
        TransferJob(id: UUID(), sourcePageURL: URL(string: "https://ex.com")!,
                    formatSelection: FormatSelection(formatID: "x", height: nil, isAdaptive: false),
                    credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
                    state: state, kind: kind, suggestedFilename: "f.mp4",
                    savedFilename: nil, autoSaveToPhotos: false)
    }

    @Test func progressivePassesTrackBytesThrough() {
        let snap = TransferCoordinator.snapshot(for: job(.progressive(track("p", bytesWritten: 250, totalBytes: 1000))))
        #expect(snap.receivedBytes == 250)
        #expect(snap.totalBytes == 1000)
        #expect(snap.fraction == 0.25)
    }

    @Test func adaptiveSumsBothTracks() {
        let snap = TransferCoordinator.snapshot(for: job(.adaptive(
            video: track("v", bytesWritten: 300, totalBytes: 1000),
            audio: track("a", bytesWritten: 100, totalBytes: 200))))
        #expect(snap.receivedBytes == 400)
        #expect(snap.totalBytes == 1200)
    }

    /// The handoff regression: video finished, audio untouched. The bar must read 1000/1200,
    /// not 100% — otherwise it completes, then visibly restarts when audio begins.
    @Test func finishedVideoDoesNotReachFullWhileAudioPending() {
        let snap = TransferCoordinator.snapshot(for: job(.adaptive(
            video: track("v", bytesWritten: 1000, totalBytes: 1000),
            audio: track("a", bytesWritten: 0, totalBytes: 200))))
        #expect(snap.receivedBytes == 1000)
        #expect(snap.totalBytes == 1200)
        #expect(snap.fraction != 1.0)
    }

    /// A total is only meaningful once EVERY track's is known — one unknown makes the whole
    /// job indeterminate, in either position, even though bytes still accumulate.
    @Test func oneUnknownTrackTotalMakesTheJobIndeterminate() {
        let audioUnknown = TransferCoordinator.snapshot(for: job(.adaptive(
            video: track("v", bytesWritten: 300, totalBytes: 1000),
            audio: track("a", bytesWritten: 50, totalBytes: nil))))
        #expect(audioUnknown.totalBytes == nil)
        #expect(audioUnknown.fraction == nil)
        #expect(audioUnknown.receivedBytes == 350)

        let videoUnknown = TransferCoordinator.snapshot(for: job(.adaptive(
            video: track("v", bytesWritten: 300, totalBytes: nil),
            audio: track("a", bytesWritten: 50, totalBytes: 200))))
        #expect(videoUnknown.totalBytes == nil)
    }

    /// `liveReceived` is the in-flight task's byte count (a chunk's, when chunked) and stacks
    /// on top of every track's persisted offset — not just the one being written.
    @Test func liveReceivedStacksOnSummedOffsets() {
        let snap = TransferCoordinator.snapshot(for: job(.adaptive(
            video: track("v", bytesWritten: 1000, totalBytes: 1000),
            audio: track("a", bytesWritten: 0, totalBytes: 200))), liveReceived: 50)
        #expect(snap.receivedBytes == 1050)
        #expect(snap.totalBytes == 1200)
    }

    @Test func stateMirrorsTheJob() {
        let paused = TransferCoordinator.snapshot(for: job(.progressive(track("p", bytesWritten: 1, totalBytes: 2)),
                                                           state: .paused))
        #expect(paused.state == .paused)
        let failed = TransferCoordinator.snapshot(for: job(.progressive(track("p", bytesWritten: 1, totalBytes: 2)),
                                                           state: .failed(.integrityCheckFailed)))
        #expect(failed.state == .failed(.integrityCheckFailed))
    }
}
