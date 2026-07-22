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
    private let diagnostics: (any TransferDiagnostics)?

    public init(store: TransferJobStore, merger: any MediaMerging,
                downloadStore: DownloadStore, disk: any DiskSpaceProbing = VolumeDiskSpace(),
                diagnostics: (any TransferDiagnostics)? = nil) {
        self.store = store
        self.merger = merger
        self.downloadStore = downloadStore
        self.disk = disk
        self.diagnostics = diagnostics
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
                diagnostics?.record(kind: "transfer_integrity_failed",
                                    detail: "job \(job.id) part \(track.partFileName): \(length) != \(track.totalBytes.map(String.init) ?? "nil")")
                await persist(job.id, "integrity_failed") { $0.state = .failed(.integrityCheckFailed) }
                return false
            }
        }

        // 2. Disk guard: the finalized output needs ~sum(track totals) of new space.
        let required = job.tracks.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        if let available = disk.availableCapacity(at: downloadStore.directory), available < required {
            await persist(job.id, "insufficient_space") { $0.state = .failed(.insufficientSpace) }
            return false
        }

        await persist(job.id, "merging") { $0.state = .merging }

        do {
            // `uniqueDestination` guarantees a non-colliding path, so no pre-delete is needed.
            let destination: URL
            switch job.kind {
            case .progressive(let track):
                destination = downloadStore.uniqueDestination(for: job.suggestedFilename)
                try FileManager.default.moveItem(at: store.partFileURL(for: track.partFileName), to: destination)
            case .adaptive(let video, let audio):
                let base = (job.suggestedFilename as NSString).deletingPathExtension
                destination = downloadStore.uniqueDestination(for: "\(base).mp4")
                try await merger.merge(video: store.partFileURL(for: video.partFileName),
                                       audio: store.partFileURL(for: audio.partFileName),
                                       into: destination)
            }
            // Success: record the saved name, complete, then drop the now-consumed parts.
            let savedName = destination.lastPathComponent
            await persist(job.id, "completed") { $0.savedFilename = savedName; $0.state = .completed }
            cleanupParts(of: job)
            return true
        } catch {
            // Merge/move failed after the integrity check — a real mux error. Marking the job
            // retryable (parts retained) IS the handling; record the cause for diagnosis.
            diagnostics?.record(kind: "transfer_merge_failed", detail: "job \(job.id): \(error)")
            await persist(job.id, "merge_failed") { $0.state = .failed(.integrityCheckFailed) }
            return false
        }
    }

    /// Persists a state mutation; a failed write is recorded (self-heals on the next
    /// `finalizeReadyJobs` since the job stays `.readyToMerge`).
    private func persist(_ id: UUID, _ context: String,
                         _ mutate: @escaping @Sendable (inout TransferJob) -> Void) async {
        do {
            _ = try await store.update(id: id, mutate)
        } catch {
            diagnostics?.record(kind: "transfer_persist_failed", detail: "\(context) job \(id): \(error)")
        }
    }

    /// Deletes a completed job's consumed part files. Non-fatal on failure (orphan GC is the
    /// backstop) but recorded so a persistent cleanup problem is diagnosable.
    private func cleanupParts(of job: TransferJob) {
        for track in job.tracks {
            do {
                try FileManager.default.removeItem(at: store.partFileURL(for: track.partFileName))
            } catch {
                diagnostics?.record(kind: "transfer_part_cleanup", detail: "\(track.partFileName): \(error)")
            }
        }
    }
}
