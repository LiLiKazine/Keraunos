import Testing
import Foundation
import KeraunosCore
@testable import Keraunos

/// The queue-row mapping: persisted jobs + the live progress bus → sorted `QueueItem`s.
/// Exercises `DownloadsViewModel.rows` directly (pure), so no `TransferEngine` is involved.
@MainActor
struct DownloadsViewModelTests {
    private func track(_ part: String, bytesWritten: Int64 = 0, totalBytes: Int64? = nil,
                       taskIdentifier: Int? = nil) -> TrackJob {
        AppTestTransfer.track(
            part,
            bytesWritten: bytesWritten,
            totalBytes: totalBytes,
            taskIdentifier: taskIdentifier)
    }
    private func job(id: UUID = UUID(), state: JobState, createdAt: TimeInterval = 1,
                     kind: TransferJob.Kind? = nil, filename: String = "clip.mp4",
                     page: String = "https://vimeo.com/1234",
                     height: Int? = 720,
                     credentialRef: String? = nil) -> TransferJob {
        AppTestTransfer.job(
            id: id,
            state: state,
            createdAt: createdAt,
            kind: kind,
            filename: filename,
            page: page,
            height: height,
            credentialRef: credentialRef)
    }
    private func snap(_ state: JobState, _ received: Int64, _ total: Int64?,
                      isEstimated: Bool = false) -> ProgressSnapshot {
        AppTestTransfer.snapshot(
            state,
            receivedBytes: received,
            totalBytes: total,
            isEstimated: isEstimated)
    }

    // MARK: estimated totals

    @Test func estimatedTotalsAreFlaggedOnTheRow() throws {
        let j = job(state: .downloading, kind: .progressive(track("p.part", taskIdentifier: 3)))
        let queue = QueueProjectionHarness(
            jobs: [j],
            snapshots: [j.id: snap(.downloading, 300, 10_000, isEstimated: true)])
        let row = try queue.requireOnlyRow()
        #expect(row.fraction == 0.03)
        #expect(row.isEstimatedTotal == true)
    }

    @Test func exactTotalsAreNotFlagged() {
        let j = job(state: .downloading, kind: .progressive(track("p.part", taskIdentifier: 3)))
        let rows = DownloadsViewModel.rows(jobs: [j], snapshots: [j.id: snap(.downloading, 300, 1000)])
        #expect(!rows[0].isEstimatedTotal)
    }

    /// A job with no snapshot has no total either, so it can't be claiming an estimate.
    @Test func aRowWithoutASnapshotIsNotFlaggedAsEstimated() {
        let j = job(state: .paused, kind: .progressive(track("p.part", bytesWritten: 10)))
        #expect(!DownloadsViewModel.rows(jobs: [j], snapshots: [:])[0].isEstimatedTotal)
    }

    // MARK: the percentage shown next to the bar

    @Test func exactPercentIsPlain() {
        #expect(TransferQueueRow.percentText(fraction: 0.25, isEstimated: false) == "25%")
        #expect(TransferQueueRow.percentText(fraction: 1.0, isEstimated: false) == "100%")
    }

    @Test func estimatedPercentIsHedged() {
        #expect(TransferQueueRow.percentText(fraction: 0.25, isEstimated: true) == "~25%")
    }

    /// A low `filesize_approx` overshoots — "137%" reads as a bug, and a premature "100%" is a
    /// lie while the job is still downloading. Cap an estimate at 99%.
    @Test func anOvershootingEstimateIsCappedBelowComplete() {
        #expect(TransferQueueRow.percentText(fraction: 1.37, isEstimated: true) == "~99%")
        #expect(TransferQueueRow.percentText(fraction: 9.0, isEstimated: true) == "~99%")
    }

    @Test func percentNeverGoesNegativeOrPastComplete() {
        #expect(TransferQueueRow.percentText(fraction: -0.5, isEstimated: false) == "0%")
        #expect(TransferQueueRow.percentText(fraction: 1.2, isEstimated: false) == "100%")
    }

    // MARK: identity & labels

    @Test func stripsExtensionAndCarriesHostAndQuality() throws {
        let j = job(state: .queued, filename: "My Clip.mp4", page: "https://vimeo.com/1234", height: 1080)
        let queue = QueueProjectionHarness(jobs: [j])
        let row = try queue.requireOnlyRow()
        #expect(row.title == "My Clip")
        #expect(row.sourceHost == "vimeo.com")
        #expect(row.qualityLabel == "1080p")
    }

    @Test func adaptiveWithoutHeightLabelsAsAdaptive() {
        let j = job(
            state: .queued,
            kind: .adaptive(video: track("v.part"), audio: track("a.part")),
            height: nil)
        #expect(DownloadsViewModel.rows(jobs: [j], snapshots: [:])[0].qualityLabel == "Adaptive")
    }

    // MARK: which jobs appear

    @Test func terminalJobsAreNotRows() {
        let jobs = [job(state: .completed), job(state: .cancelled)]
        #expect(QueueProjectionHarness(jobs: jobs).rows.isEmpty)
    }

    @Test func failedJobCarriesItsReason() {
        let j = job(state: .failed(.mergeFailed))
        #expect(DownloadsViewModel.rows(jobs: [j], snapshots: [:])[0].rowState == .failed(.mergeFailed))
    }

    // MARK: progress merge

    @Test func snapshotSuppliesFractionAndBytes() throws {
        let j = job(state: .downloading, kind: .progressive(track("p.part", bytesWritten: 10, taskIdentifier: 7)))
        let queue = QueueProjectionHarness(
            jobs: [j], snapshots: [j.id: snap(.downloading, 500, 2000)])
        let row = try queue.requireOnlyRow()
        #expect(row.fraction == 0.25)
        #expect(row.receivedBytes == 500) // bus wins over the persisted offset
        #expect(row.totalBytes == 2000)
    }

    /// A job the bus hasn't published yet (fresh launch, before reassociation) still shows the
    /// bytes already on disk — summed across tracks — rather than zero, with an indeterminate bar.
    @Test func withoutASnapshotFallsBackToSummedPersistedOffsets() {
        let j = job(state: .paused, kind: .adaptive(video: track("v.part", bytesWritten: 900, totalBytes: 1000),
                                                    audio: track("a.part", bytesWritten: 100, totalBytes: 200)))
        let row = DownloadsViewModel.rows(jobs: [j], snapshots: [:])[0]
        #expect(row.receivedBytes == 1000)
        #expect(row.fraction == nil)
        #expect(row.totalBytes == nil)
    }

    @Test func indeterminateSnapshotYieldsNoFraction() {
        let j = job(state: .downloading, kind: .progressive(track("p.part", taskIdentifier: 3)))
        let rows = DownloadsViewModel.rows(jobs: [j], snapshots: [j.id: snap(.downloading, 700, nil)])
        #expect(rows[0].fraction == nil)
        #expect(rows[0].receivedBytes == 700)
    }

    /// The row variant comes from the persisted job, not the snapshot's state — a `.downloading`
    /// job with no live task is "Waiting (background)".
    @Test func rowVariantComesFromTheJobNotTheSnapshot() {
        let j = job(state: .downloading, kind: .progressive(track("p.part", taskIdentifier: nil)))
        let rows = DownloadsViewModel.rows(jobs: [j], snapshots: [j.id: snap(.downloading, 1, 2)])
        #expect(rows[0].rowState == .waitingBackground)
    }

    // MARK: ordering

    @Test func ordersActiveThenWaitingThenAttention() {
        let failed = job(state: .failed(.network), createdAt: 1)
        let queued = job(state: .queued, createdAt: 2)
        let active = job(state: .downloading, createdAt: 3,
                         kind: .progressive(track("p.part", taskIdentifier: 5)))
        let needsSignIn = job(state: .needsRefresh, createdAt: 4, credentialRef: "acct")
        let queue = QueueProjectionHarness(jobs: [failed, queued, active, needsSignIn])
        #expect(queue.rows.map(\.rowState) == [.downloading, .queued, .failed(.network), .needsSignIn])
    }

    @Test func tiesBreakOnCreatedAtOldestFirst() {
        let newer = job(state: .queued, createdAt: 200)
        let older = job(state: .queued, createdAt: 100)
        let rows = DownloadsViewModel.rows(jobs: [newer, older], snapshots: [:])
        #expect(rows.map(\.id) == [older.id, newer.id])
    }

    /// Merging and refreshing rank as active alongside downloading (they're automatic work),
    /// so they never sink below a queued row.
    @Test func mergingAndRefreshingRankAsActive() {
        let queued = job(state: .queued, createdAt: 1)
        let merging = job(state: .readyToMerge, createdAt: 2)
        let refreshing = job(state: .needsRefresh, createdAt: 3)
        let rows = DownloadsViewModel.rows(jobs: [queued, merging, refreshing], snapshots: [:])
        #expect(rows.map(\.rowState) == [.merging, .refreshing, .queued])
    }
}
