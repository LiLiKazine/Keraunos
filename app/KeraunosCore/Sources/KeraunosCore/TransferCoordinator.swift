import Foundation

/// The event-driven transfer engine. Drives `TransferJob`s against a `TransferSession`,
/// porting the chunked corruption guards from the old `Downloader.downloadChunked` onto
/// background-capable download tasks and enforcing the Phase-1 crash-consistency ordering.
/// Download completion advances a job to `.readyToMerge`; merging is Phase 4.
public actor TransferCoordinator {
    private let store: TransferJobStore
    private let session: any TransferSession
    /// Live task id → which job/track it is fetching. Rebuilt on relaunch by `reassociateAndResume`.
    private var owners: [Int: Owner] = [:]

    private struct Owner: Sendable { let jobID: UUID; let trackIndex: Int }

    public init(store: TransferJobStore, session: any TransferSession) {
        self.store = store
        self.session = session
    }

    // MARK: - Control

    /// Persists `job` as `.downloading` and begins its first not-yet-complete track.
    public func start(_ job: TransferJob) async throws {
        var job = job
        job.state = .downloading
        try await store.upsert(job)
        guard let index = Self.firstIncompleteTrackIndex(job) else {
            try await store.update(id: job.id) { $0.state = .readyToMerge }
            return
        }
        try await beginTrack(jobID: job.id, trackIndex: index)
    }

    /// Rebinds still-live tasks to their jobs and resumes any `.downloading` job whose
    /// current track's task has vanished (killed while suspended). Call on launch and on
    /// regained reachability.
    public func reassociateAndResume() async {
        let live = Set(await session.liveTaskIdentifiers())
        owners = owners.filter { live.contains($0.key) }
        for job in await store.all() where job.state == .downloading {
            guard let index = Self.firstIncompleteTrackIndex(job) else {
                try? await store.update(id: job.id) { $0.state = .readyToMerge }
                continue
            }
            let track = job.tracks[index]
            if let tid = track.taskIdentifier, live.contains(tid) {
                owners[tid] = Owner(jobID: job.id, trackIndex: index)   // still running — rebind
            } else {
                try? await beginTrack(jobID: job.id, trackIndex: index) // vanished — resume
            }
        }
    }

    // MARK: - Event ingress (called by the session delegate in the app target)

    /// A download task delivered a staged temp file (its bytes are already safe on disk).
    public func taskDidFinishDownloading(taskIdentifier: Int, to stagedFile: URL,
                                         statusCode: Int, contentRangeTotal: Int64?) async {
        guard let owner = owners.removeValue(forKey: taskIdentifier),
              let job = await store.job(id: owner.jobID), job.state == .downloading else {
            try? FileManager.default.removeItem(at: stagedFile)   // launch race / stale — discard
            return
        }
        let track = job.tracks[owner.trackIndex]
        defer { try? FileManager.default.removeItem(at: stagedFile) }

        do {
            if statusCode == 200 {
                // Server ignored Range (or single-shot): the body IS the whole file — only
                // valid at offset 0, else appending would corrupt a partially-written file.
                guard track.bytesWritten == 0 else { throw KeraunosError.downloadNetwork }
                let part = PartFile(url: store.partFileURL(for: track.partFileName))
                try part.truncate(to: 0)
                let length = try part.append(Data(contentsOf: stagedFile))
                try await store.update(id: owner.jobID) {
                    Self.mutateTrack(&$0, at: owner.trackIndex) { $0.bytesWritten = length; $0.totalBytes = length }
                }
                try await completeTrack(jobID: owner.jobID)
            } else if statusCode == 206 {
                let part = PartFile(url: store.partFileURL(for: track.partFileName))
                let chunk = try Data(contentsOf: stagedFile)
                let length = try part.append(chunk)              // fsync BEFORE persisting offset
                let total = contentRangeTotal ?? track.totalBytes
                try await store.update(id: owner.jobID) {
                    Self.mutateTrack(&$0, at: owner.trackIndex) { $0.bytesWritten = length; $0.totalBytes = total }
                }
                let requested = track.chunkSize ?? 0
                let ended = chunk.isEmpty || chunk.count < requested || (total.map { length >= $0 } ?? false)
                if ended {
                    if total == nil {   // server never reported a total — freeze it at what we wrote
                        try await store.update(id: owner.jobID) {
                            Self.mutateTrack(&$0, at: owner.trackIndex) { $0.totalBytes = length }
                        }
                    }
                    try await completeTrack(jobID: owner.jobID)
                } else {
                    try await beginTrack(jobID: owner.jobID, trackIndex: owner.trackIndex)
                }
            } else {
                throw KeraunosError.downloadNetwork              // Phase 5 splits 403/410 → needsRefresh
            }
        } catch {
            try? await store.update(id: owner.jobID) { $0.state = .failed(.network) }
        }
    }

    /// A download task failed (network drop) or was cancelled. The offset is intact, so the
    /// job stays `.downloading`; `reassociateAndResume` re-kicks it. Single-shot resume data
    /// is stashed on the track.
    public func taskDidFail(taskIdentifier: Int, resumeData: Data?, isCancelled: Bool) async {
        guard let owner = owners.removeValue(forKey: taskIdentifier) else { return }
        try? await store.update(id: owner.jobID) {
            Self.mutateTrack(&$0, at: owner.trackIndex) { $0.resumeData = resumeData; $0.taskIdentifier = nil }
        }
    }

    // MARK: - Track driving

    /// Begins (or resumes) the track at `trackIndex`: truncates the part file to the recorded
    /// offset (chunked resume safety), then starts the next task.
    private func beginTrack(jobID: UUID, trackIndex: Int) async throws {
        guard let job = await store.job(id: jobID) else { return }
        let track = job.tracks[trackIndex]
        let chunked = (track.chunkSize ?? 0) > 0
        let taskID: Int
        if chunked {
            // Discard any un-recorded tail written before a crash, so the ranged request
            // that follows can't double-append. `bytesWritten` is authoritative.
            try PartFile(url: store.partFileURL(for: track.partFileName)).truncate(to: track.bytesWritten)
            var request = URLRequest(url: track.remoteURL)
            let upper = track.bytesWritten + Int64(track.chunkSize!) - 1
            request.setValue("bytes=\(track.bytesWritten)-\(upper)", forHTTPHeaderField: "Range")
            taskID = try await session.startDownloadTask(for: request)
        } else if let resume = track.resumeData {
            taskID = try await session.startDownloadTask(withResumeData: resume)
        } else {
            taskID = try await session.startDownloadTask(for: URLRequest(url: track.remoteURL))
        }
        owners[taskID] = Owner(jobID: jobID, trackIndex: trackIndex)
        try await store.update(id: jobID) {
            Self.mutateTrack(&$0, at: trackIndex) { $0.taskIdentifier = taskID }
        }
    }

    /// Marks the current track done and either starts the next track (adaptive) or advances
    /// the whole job to `.readyToMerge`.
    private func completeTrack(jobID: UUID) async throws {
        guard let job = await store.job(id: jobID) else { return }
        if let next = Self.firstIncompleteTrackIndex(job) {
            try await beginTrack(jobID: jobID, trackIndex: next)
        } else {
            try await store.update(id: jobID) { $0.state = .readyToMerge }
        }
    }

    // MARK: - Helpers

    /// Index of the first track that isn't fully downloaded, or nil if all are complete.
    /// A track is complete ⟺ `totalBytes != nil && bytesWritten >= totalBytes`.
    static func firstIncompleteTrackIndex(_ job: TransferJob) -> Int? {
        job.tracks.firstIndex { track in
            guard let total = track.totalBytes else { return true }
            return track.bytesWritten < total
        }
    }

    /// Applies `mutate` to the track at `index` inside a job's `kind` (0 = progressive/video,
    /// 1 = audio).
    static func mutateTrack(_ job: inout TransferJob, at index: Int, _ mutate: (inout TrackJob) -> Void) {
        switch job.kind {
        case .progressive(var t):
            mutate(&t); job.kind = .progressive(t)
        case .adaptive(var v, var a):
            if index == 0 { mutate(&v) } else { mutate(&a) }
            job.kind = .adaptive(video: v, audio: a)
        }
    }
}
