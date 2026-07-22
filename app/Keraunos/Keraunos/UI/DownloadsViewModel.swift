import Foundation
import Observation
import KeraunosCore

/// One queue row's display payload — the durable job's identity/quality plus the live
/// progress snapshot, flattened for SwiftUI.
struct QueueItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let sourceHost: String?
    let qualityLabel: String
    let rowState: TransferRowState
    let fraction: Double?
    let receivedBytes: Int64
    let totalBytes: Int64?
}

/// The Download tab's live queue. Reconstructs rows from the persisted `TransferJobStore`
/// (identity + row *variant*) merged with the `TransferProgress` bus (live fraction/bytes),
/// so it reconnects after relaunch. Ordered active → queued → attention, per the spec.
@MainActor
@Observable
final class DownloadsViewModel {
    private(set) var items: [QueueItem] = []

    private let engine: TransferEngine
    private var streamTask: Task<Void, Never>?

    /// Ordering rank: active (downloading/waiting/merging/refreshing) → paused/queued → attention.
    private static func rank(_ s: TransferRowState) -> Int {
        switch s {
        case .downloading, .waitingBackground, .merging, .refreshing: return 0
        case .paused, .queued:                                        return 1
        case .needsSignIn, .failed:                                   return 2
        }
    }

    init(engine: TransferEngine = .shared) {
        self.engine = engine
    }

    var activeCount: Int {
        items.filter { Self.rank($0.rowState) == 0 || $0.rowState == .paused || $0.rowState == .queued }.count
    }

    /// Subscribes to the progress bus; every emission triggers a full rebuild from the store
    /// (tiny) so state transitions the bus reflects are picked up. Call from `.task`.
    func start() {
        streamTask?.cancel()
        streamTask = Task { [engine] in
            for await snapshots in await engine.progress.updates() {
                await self.rebuild(snapshots: snapshots)
            }
        }
    }

    func stop() { streamTask?.cancel(); streamTask = nil }

    /// Rebuilds `items` from persisted jobs (source of row variant + identity) and the live
    /// snapshot map (fraction/bytes). Also fires the "Saved to Library" toast for jobs the
    /// engine has just moved to Library.
    func rebuild(snapshots: [UUID: ProgressSnapshot]) async {
        let jobs = await engine.store.all()
        let rows: [QueueItem] = jobs.compactMap { job in
            guard let rowState = job.rowState else { return nil }
            let snap = snapshots[job.id]
            return QueueItem(
                id: job.id,
                title: (job.suggestedFilename as NSString).deletingPathExtension,
                sourceHost: job.sourcePageURL.host,
                qualityLabel: Self.qualityLabel(job.formatSelection),
                rowState: rowState,
                fraction: snap?.fraction,
                receivedBytes: snap?.receivedBytes ?? job.tracks.reduce(0) { $0 + $1.bytesWritten },
                totalBytes: snap?.totalBytes)
        }
        items = rows.sorted {
            let (a, b) = (Self.rank($0.rowState), Self.rank($1.rowState))
            return a != b ? a < b : $0.id.uuidString < $1.id.uuidString
        }
        savedTitles = engine.consumeRecentlySaved()   // consumed by the view's onChange
    }

    /// Set to the newly-saved titles on each rebuild; the screen coalesces these into a toast.
    private(set) var savedTitles: [String] = []

    static func qualityLabel(_ f: FormatSelection) -> String {
        f.height.map { "\($0)p" } ?? (f.isAdaptive ? "Adaptive" : "Video")
    }

    // MARK: Actions
    func pause(_ id: UUID)  { Task { await engine.pause(id) } }
    func resume(_ id: UUID) { Task { await engine.resume(id) } }
    func cancel(_ id: UUID) { Task { await engine.cancel(id) } }
    func retry(_ id: UUID)  { Task { await engine.retry(id) } }
    func dismiss(_ id: UUID){ Task { await engine.remove(id) } }
}
