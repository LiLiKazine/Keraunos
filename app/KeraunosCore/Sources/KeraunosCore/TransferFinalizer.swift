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

    public init(store: TransferJobStore, merger: any MediaMerging,
                downloadStore: DownloadStore, disk: any DiskSpaceProbing = VolumeDiskSpace()) {
        self.store = store
        self.merger = merger
        self.downloadStore = downloadStore
        self.disk = disk
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
                try? await store.update(id: job.id) { $0.state = .failed(.integrityCheckFailed) }
                return false
            }
        }

        // 2. Disk guard: the finalized output needs ~sum(track totals) of new space.
        let required = job.tracks.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
        if let available = disk.availableCapacity(at: downloadStore.directory), available < required {
            try? await store.update(id: job.id) { $0.state = .failed(.insufficientSpace) }
            return false
        }

        try? await store.update(id: job.id) { $0.state = .merging }

        do {
            let destination: URL
            switch job.kind {
            case .progressive(let track):
                destination = downloadStore.uniqueDestination(for: job.suggestedFilename)
                let part = store.partFileURL(for: track.partFileName)
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: part, to: destination)
            case .adaptive(let video, let audio):
                let base = (job.suggestedFilename as NSString).deletingPathExtension
                destination = downloadStore.uniqueDestination(for: "\(base).mp4")
                try await merger.merge(video: store.partFileURL(for: video.partFileName),
                                       audio: store.partFileURL(for: audio.partFileName),
                                       into: destination)
            }
            // Success: record the saved name, drop the parts, complete.
            let savedName = destination.lastPathComponent
            try? await store.update(id: job.id) { $0.savedFilename = savedName; $0.state = .completed }
            for track in job.tracks {
                try? FileManager.default.removeItem(at: store.partFileURL(for: track.partFileName))
            }
            return true
        } catch {
            // Merge/move failed after the integrity check — a real mux error. Retain parts
            // for retry; surface as integrityCheckFailed (the only durable "bad output" reason).
            try? await store.update(id: job.id) { $0.state = .failed(.integrityCheckFailed) }
            return false
        }
    }
}
