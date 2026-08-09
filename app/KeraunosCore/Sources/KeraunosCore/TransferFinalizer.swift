import Foundation

private enum FinalizationError: Error {
    case stagePathCollision
    case invalidStage
    case crossVolumePromotion
}

/// Takes `.readyToMerge` and crash-interrupted `.merging` jobs to `.completed`. It validates source
/// lengths, reserves the durable output name, and produces a deterministic job-owned ready stage:
/// progressive jobs atomically move their existing part, while adaptive jobs mux once into a
/// bounded partial stage and atomically checkpoint it as ready. Promotion into `DownloadStore`
/// atomically creates a no-overwrite hard link, and its durable identity checkpoint makes every
/// crash window idempotent without a whole-file copy or byte comparison. Adaptive source parts
/// remain until `.completed` is durable;
/// a progressive source becomes the owned ready/final file as it advances. Photos/background-task
/// handling remains app-target glue around this actor.
public actor TransferFinalizer {
    private let store: TransferJobStore
    private let merger: any MediaMerging
    private let downloadStore: DownloadStore
    private let disk: any DiskSpaceProbing
    private let diagnostics: (any TransferDiagnostics)?
    private let progress: TransferProgress?
    private var activeJobIDs: Set<UUID> = []

    public init(store: TransferJobStore, merger: any MediaMerging,
                downloadStore: DownloadStore, disk: any DiskSpaceProbing = VolumeDiskSpace(),
                diagnostics: (any TransferDiagnostics)? = nil,
                progress: TransferProgress? = nil) {
        self.store = store
        self.merger = merger
        self.downloadStore = downloadStore
        self.disk = disk
        self.diagnostics = diagnostics
        self.progress = progress
    }

    @discardableResult
    public func finalizeReadyJobs() async -> [UUID] {
        var completed: [UUID] = []
        for job in await store.all() {
            switch job.state {
            case .completed:
                // Completion is not deliverable until its contained output still exists and is
                // structurally plausible. Retained sources are the recovery copy after a crash or
                // external deletion between completion persistence and post-processing.
                if completedOutputIsValid(job) {
                    if cleanupAfterCompleted(job) { completed.append(job.id) }
                } else {
                    diagnostics?.record(kind: "transfer_completed_output_missing",
                                        detail: "job \(job.id) \(sourceTag(job))")
                    let hasCheckpoint = validPromotionCheckpointURL(for: job) != nil
                    guard await persist(job.id, "recover_completed_output", {
                        if hasCheckpoint {
                            // Preserve the durable reservation and identity anchor. `finalize`
                            // will reconstruct the ready name without copying or remuxing.
                            $0.state = .merging
                            $0.finalizationPhase = .readyToPromote
                        } else {
                            // Legacy completion has no ownership identity; regenerate from sources
                            // and allocate around any occupant instead of trusting it by size.
                            $0.state = .readyToMerge
                            $0.savedFilename = nil
                            $0.finalizationPhase = nil
                        }
                    }), let recovered = await store.job(id: job.id) else { continue }
                    if await finalize(recovered) { completed.append(job.id) }
                }
            case .readyToMerge, .merging:
                if await finalize(job) { completed.append(job.id) }
            default:
                continue
            }
        }
        return completed
    }

    public func finalize(id: UUID) async {
        guard let job = await store.job(id: id) else { return }
        _ = await finalize(job)
    }

    /// Returns true iff the job reached `.completed`.
    private func finalize(_ job: TransferJob) async -> Bool {
        guard job.state == .readyToMerge || job.state == .merging else { return false }
        guard activeJobIDs.insert(job.id).inserted else { return false }
        defer { activeJobIDs.remove(job.id) }

        let sourceURLs: [URL]
        let partialStage: URL
        let readyStage: URL
        let promotionCheckpoint: URL
        do {
            sourceURLs = try job.tracks.map { try store.validatedPartFileURL(for: $0.partFileName) }
            partialStage = try store.validatedPartFileURL(for: job.finalizationPartialFileName)
            readyStage = try store.validatedPartFileURL(for: job.finalizationReadyFileName)
            promotionCheckpoint = try store.validatedPartFileURL(
                for: job.finalizationPromotionCheckpointFileName)
            // Validate deterministic merger aliases before AVFoundation may replace stale links.
            _ = try store.validatedPartFileURL(for: job.finalizationVideoScratchFileName)
            _ = try store.validatedPartFileURL(for: job.finalizationAudioScratchFileName)
            guard !sourceURLs.contains(partialStage), !sourceURLs.contains(readyStage) else {
                throw FinalizationError.stagePathCollision
            }
            try requireSamePromotionVolume()
        } catch {
            diagnostics?.record(kind: "transfer_invalid_path", detail: "job \(job.id): \(error)")
            return false
        }

        var destination: URL
        var savedName: String
        do {
            destination = try self.destination(for: job)
            savedName = destination.lastPathComponent
        } catch {
            diagnostics?.record(kind: "transfer_destination_failed",
                                detail: "job \(job.id) \(sourceTag(job)): \(error)")
            return false
        }

        // A ready checkpoint plus an absent stage is the crash window after promotion. Trust the
        // destination only when it is the same filesystem object as our retained hard-link anchor;
        // size/nonempty checks would misattribute a user replacement.
        if job.finalizationPhase == .readyToPromote,
           filesShareIdentity(promotionCheckpoint, destination) {
            return await persistCompleted(job, savedName: savedName)
        }

        // Reserve both destination and preparation phase before filesystem work. Legacy merging
        // jobs have a nil phase and safely enter this checkpoint without trusting any occupant.
        if job.state != .merging || job.savedFilename != savedName || job.finalizationPhase == nil {
            let reservedName = savedName
            guard await persist(job.id, "merging", {
                $0.savedFilename = reservedName
                $0.state = .merging
                $0.finalizationPhase = .preparing
            }) else { return false }
        }

        do {
            // If promotion happened but its destination was removed/replaced, the checkpoint is
            // still the owned inode. Recreate the ready directory entry without copying bytes;
            // the collision loop below preserves the replacement and chooses a fresh destination.
            if job.finalizationPhase == .readyToPromote,
               !FileManager.default.fileExists(atPath: readyStage.path),
               FileManager.default.fileExists(atPath: promotionCheckpoint.path) {
                try FileManager.default.linkItem(at: promotionCheckpoint, to: readyStage)
            }

            // A ready file is the filesystem checkpoint. If a crash left both deterministic
            // names, the ready file wins and the incomplete partial is discarded, bounding each
            // job to one staging artifact.
            if FileManager.default.fileExists(atPath: readyStage.path) {
                try removeIfPresent(partialStage)
            } else {
                try removeIfPresent(partialStage)

                // Source integrity is required only while producing a stage. Progressive recovery
                // after promotion intentionally has no source because atomic move consumed it.
                guard sourcesAreComplete(job, urls: sourceURLs) else {
                    _ = await persist(job.id, "integrity_failed") {
                        $0.state = .failed(.integrityCheckFailed)
                    }
                    return false
                }

                switch job.kind {
                case .progressive:
                    // Both paths are on the transfer store volume. Rename preserves the inode and
                    // never duplicates a multi-gigabyte progressive download.
                    try FileManager.default.moveItem(at: sourceURLs[0], to: readyStage)
                case .adaptive:
                    let required = job.tracks.reduce(Int64(0)) { $0 + ($1.totalBytes ?? 0) }
                    if let available = disk.availableCapacity(at: store.partsDirectory),
                       available < required {
                        _ = await persist(job.id, "insufficient_space") {
                            $0.state = .failed(.insufficientSpace)
                        }
                        return false
                    }
                    try await merger.merge(video: sourceURLs[0], audio: sourceURLs[1],
                                           into: partialStage)
                    guard stagedOutputIsValid(job, at: partialStage) else {
                        throw FinalizationError.invalidStage
                    }
                    try FileManager.default.moveItem(at: partialStage, to: readyStage)
                }
            }

            try synchronizePromotionCheckpoint(
                promotionCheckpoint, with: readyStage,
                checkpointWins: job.finalizationPhase == .readyToPromote)
            guard stagedOutputIsValid(job, at: readyStage) else {
                diagnostics?.record(kind: "transfer_integrity_failed",
                                    detail: "job \(job.id) \(sourceTag(job)) invalid ready stage")
                _ = await persist(job.id, "invalid_ready_stage") {
                    $0.state = .failed(.integrityCheckFailed)
                }
                return false
            }

            guard await persist(job.id, "ready_to_promote", {
                $0.finalizationPhase = .readyToPromote
            }) else { return false }

            // Promote only via a no-overwrite rename. A collision reallocates the durable
            // reservation while keeping the same ready stage, so neither copy nor mux repeats.
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = try uniqueDestination(for: savedName)
                savedName = destination.lastPathComponent
                let reservedName = savedName
                guard await persist(job.id, "destination_collision", {
                    $0.savedFilename = reservedName
                    $0.state = .merging
                    $0.finalizationPhase = .readyToPromote
                }) else { return false }
            }
            do {
                try promoteWithoutOverwrite(readyStage, to: destination)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                // Close the final check/move race without regenerating the owned stage.
                destination = try uniqueDestination(for: savedName)
                savedName = destination.lastPathComponent
                let reservedName = savedName
                guard await persist(job.id, "destination_race", {
                    $0.savedFilename = reservedName
                    $0.finalizationPhase = .readyToPromote
                }) else { return false }
                try promoteWithoutOverwrite(readyStage, to: destination)
            }

            return await persistCompleted(job, savedName: savedName)
        } catch {
            try? removeIfPresent(partialStage)
            diagnostics?.record(kind: "transfer_merge_failed",
                                detail: "job \(job.id) \(sourceTag(job)): \(error)")
            _ = await persist(job.id, "merge_failed") { $0.state = .failed(.mergeFailed) }
            return false
        }
    }

    /// Resolves the durable destination reservation. Only a `.merging` job may reuse a saved
    /// name; ready jobs allocate a fresh non-colliding path. Invalid legacy/persisted names are
    /// replaced with a sanitized reservation inside the download directory.
    private func destination(for job: TransferJob) throws -> URL {
        if job.state == .merging, let savedName = job.savedFilename {
            return try SafeFileComponent(savedName).url(in: downloadStore.directory)
        }
        switch job.kind {
        case .progressive:
            return try uniqueDestination(for: job.suggestedFilename)
        case .adaptive:
            let base = (job.suggestedFilename as NSString).deletingPathExtension
            return try uniqueDestination(for: "\(base).mp4")
        }
    }

    private func uniqueDestination(for filename: String) throws -> URL {
        let candidate = downloadStore.uniqueDestination(for: filename)
        return try SafeFileComponent(candidate.lastPathComponent).url(in: downloadStore.directory)
    }

    private func sourcesAreComplete(_ job: TransferJob, urls: [URL]) -> Bool {
        for (track, source) in zip(job.tracks, urls) {
            let length = PartFile(url: source).length()
            guard let total = track.totalBytes, length == total else {
                diagnostics?.record(kind: "transfer_integrity_failed",
                                    detail: "job \(job.id) \(sourceTag(job)) part \(track.partFileName): \(length) != \(track.totalBytes.map(String.init) ?? "nil")")
                return false
            }
        }
        return true
    }

    private func stagedOutputIsValid(_ job: TransferJob, at url: URL) -> Bool {
        guard let size = regularFileSize(at: url) else { return false }
        switch job.kind {
        case .progressive(let track): return track.totalBytes == size
        case .adaptive: return size > 0
        }
    }

    private func completedOutputIsValid(_ job: TransferJob) -> Bool {
        guard let savedName = job.savedFilename,
              let destination = try? SafeFileComponent(savedName).url(in: downloadStore.directory)
        else { return false }
        if let checkpoint = validPromotionCheckpointURL(for: job) {
            return filesShareIdentity(checkpoint, destination)
        }
        // A legacy completed job may predate identity checkpoints. If it still retains any source,
        // never trust a same-sized/nonempty occupant: regenerate into a fresh reservation instead.
        guard !job.tracks.contains(where: { track in
            guard let url = try? store.validatedPartFileURL(for: track.partFileName) else {
                return false
            }
            return fileIdentity(at: url) != nil
        }) else { return false }
        // With no recoverable source or checkpoint, structural validity is the only backward-
        // compatible evidence available for a job completed by an older app version.
        return stagedOutputIsValid(job, at: destination)
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
    }

    private func fileIdentity(at url: URL) -> FileIdentity? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else { return nil }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value)
    }

    private func filesShareIdentity(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = fileIdentity(at: lhs), let right = fileIdentity(at: rhs) else {
            return false
        }
        return left == right
    }

    private func validPromotionCheckpointURL(for job: TransferJob) -> URL? {
        guard let lexical = try? SafeFileComponent(job.finalizationPromotionCheckpointFileName)
            .url(in: store.partsDirectory),
              FileManager.default.fileExists(atPath: lexical.path),
              let validated = try? store.validatedPartFileURL(
                for: job.finalizationPromotionCheckpointFileName),
              fileIdentity(at: validated) != nil else { return nil }
        return validated
    }

    private func synchronizePromotionCheckpoint(_ checkpoint: URL, with ready: URL,
                                                checkpointWins: Bool) throws {
        if filesShareIdentity(checkpoint, ready) { return }
        if checkpointWins, fileIdentity(at: checkpoint) != nil {
            try removeIfPresent(ready)
            try FileManager.default.linkItem(at: checkpoint, to: ready)
        } else {
            try removeIfPresent(checkpoint)
            try FileManager.default.linkItem(at: ready, to: checkpoint)
        }
    }

    private func regularFileSize(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey
        ]), values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize else { return nil }
        return Int64(size)
    }

    private func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Hard-link creation is an atomic no-overwrite promotion on the already-verified shared
    /// volume. Removing the private ready name afterward changes no bytes or filesystem identity.
    /// If that cleanup fails, completed cleanup retries it while the checkpoint still anchors the
    /// promoted inode.
    private func promoteWithoutOverwrite(_ ready: URL, to destination: URL) throws {
        try FileManager.default.linkItem(at: ready, to: destination)
        do {
            try FileManager.default.removeItem(at: ready)
        } catch {
            diagnostics?.record(kind: "transfer_stage_cleanup",
                                detail: "\(ready.lastPathComponent): \(error)")
        }
    }

    /// Promotion hard links require both directories to be on the same mounted volume.
    private func requireSamePromotionVolume() throws {
        let keys: Set<URLResourceKey> = [.volumeIdentifierKey]
        let stageVolume = try store.partsDirectory.resourceValues(forKeys: keys).volumeIdentifier
        let outputVolume = try downloadStore.directory.resourceValues(forKeys: keys).volumeIdentifier
        guard let stage = stageVolume as? NSObject,
              let output = outputVolume as? NSObject,
              stage == output else {
            throw FinalizationError.crossVolumePromotion
        }
    }

    private func persistCompleted(_ job: TransferJob, savedName: String) async -> Bool {
        guard await persist(job.id, "completed", {
            $0.savedFilename = savedName
            $0.state = .completed
            $0.finalizationPhase = nil
        }) else { return false }
        return cleanupAfterCompleted(job)
    }

    /// Source page + chosen format for a failing job, so a finalize failure in the log maps
    /// straight back to the video and rendition without timestamp correlation. The URL is
    /// redacted for embedded secrets by the diagnostics sink at write time.
    private func sourceTag(_ job: TransferJob) -> String {
        "src=\(job.sourcePageURL.absoluteString) fmt=\(job.formatSelection.formatID)"
    }

    /// Persists a state mutation and reports whether it reached disk. A failed write is recorded;
    /// the durable job remains eligible on the next relaunch.
    private func persist(_ id: UUID, _ context: String,
                         _ mutate: @escaping @Sendable (inout TransferJob) -> Void) async -> Bool {
        do {
            let updated = try await store.update(id: id, mutate)
            if let progress, let updated {
                await progress.set(TransferCoordinator.snapshot(for: updated), for: id)
            }
            return updated != nil
        } catch {
            diagnostics?.record(kind: "transfer_persist_failed", detail: "\(context) job \(id): \(error)")
            return false
        }
    }

    /// Deletes a completed job's consumed part files. Non-fatal on failure (orphan GC is the
    /// backstop) but recorded so a persistent cleanup problem is diagnosable.
    @discardableResult
    private func cleanupParts(of job: TransferJob) -> Bool {
        var succeeded = true
        for track in job.tracks {
            do {
                let url = try store.validatedPartFileURL(for: track.partFileName)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try FileManager.default.removeItem(at: url)
            } catch {
                succeeded = false
                diagnostics?.record(kind: "transfer_part_cleanup", detail: "\(track.partFileName): \(error)")
            }
        }
        return succeeded
    }

    @discardableResult
    private func cleanupOwnedStages(of job: TransferJob) -> Bool {
        var succeeded = true
        for name in [
            job.finalizationPartialFileName,
            job.finalizationReadyFileName,
            job.finalizationVideoScratchFileName,
            job.finalizationAudioScratchFileName
        ] {
            do {
                let url = try store.validatedPartFileURL(for: name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try FileManager.default.removeItem(at: url)
            } catch {
                succeeded = false
                diagnostics?.record(kind: "transfer_stage_cleanup", detail: "\(name): \(error)")
            }
        }
        return succeeded
    }

    /// The promotion checkpoint deliberately outlives finalizer cleanup. It remains the job's
    /// ownership evidence throughout `.completed` post-processing; only the durable app-level
    /// `TransferJobStore.remove` deletes it through `ownedPartFileNames`.
    private func cleanupAfterCompleted(_ job: TransferJob) -> Bool {
        let stagesClean = cleanupOwnedStages(of: job)
        guard cleanupParts(of: job) else { return false }
        return stagesClean
    }
}
