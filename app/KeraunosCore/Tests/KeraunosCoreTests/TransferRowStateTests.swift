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
