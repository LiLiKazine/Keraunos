import Foundation

/// Durable owner of the transfer job set. Persists atomically to Application Support on
/// every mutation and rehydrates on init, so the queue survives suspension, termination,
/// and relaunch. Part files live in a sibling `parts/` directory, addressed by name.
public actor TransferJobStore {
    public let directory: URL
    public let partsDirectory: URL
    private let fileURL: URL
    private let diagnostics: (any TransferDiagnostics)?
    private var jobs: [TransferJob]

    /// Default base directory: `<Application Support>/Transfers`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfers", isDirectory: true)
    }

    public init(directory: URL? = nil, diagnostics: (any TransferDiagnostics)? = nil) throws {
        let base = directory ?? Self.defaultDirectory
        let parts = base.appendingPathComponent("parts", isDirectory: true)
        // Reject terminal symlinks before `createDirectory` can follow them and mutate their
        // targets. Missing directories are the normal first-launch case.
        try SafeFileComponent.validateDirectory(base, allowMissing: true)
        try SafeFileComponent.validateDirectory(parts, allowMissing: true)
        try FileManager.default.createDirectory(at: parts, withIntermediateDirectories: true)
        try SafeFileComponent.validateDirectory(base, allowMissing: false)
        try SafeFileComponent.validateDirectory(parts, allowMissing: false)
        self.directory = base
        self.partsDirectory = parts
        self.fileURL = base.appendingPathComponent("transfers.json")
        self.diagnostics = diagnostics
        self.jobs = Self.load(fileURL, diagnostics: diagnostics)
    }

    public func all() -> [TransferJob] { jobs }

    public func job(id: UUID) -> TransferJob? { jobs.first { $0.id == id } }

    /// Adds a job, or replaces the existing one with the same id.
    public func upsert(_ job: TransferJob) throws {
        var candidate = jobs
        if let i = candidate.firstIndex(where: { $0.id == job.id }) {
            candidate[i] = job
        } else {
            candidate.append(job)
        }
        try validate(candidate)
        try persist(candidate)
        jobs = candidate
    }

    /// Mutates a job in place and persists. Returns the updated job, or nil if not found.
    @discardableResult
    public func update(id: UUID, _ mutate: @Sendable (inout TransferJob) -> Void) throws -> TransferJob? {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        var candidate = jobs
        mutate(&candidate[i])
        try validate(candidate)
        try persist(candidate)
        jobs = candidate
        return candidate[i]
    }

    /// Durably removes a job, publishes that removal in memory, then deletes its part files
    /// best-effort. A crash after persistence but before cleanup leaves orphans for reconciliation;
    /// a persistence failure leaves both the job and its parts untouched.
    public func remove(id: UUID) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        let removed = jobs[i]
        var candidate = jobs
        candidate.remove(at: i)
        try persist(candidate)
        jobs = candidate
        let referenced = Set(candidate.flatMap(\.ownedPartFileNames).compactMap(Self.ownershipKey))
        for name in removed.ownedPartFileNames {
            guard let key = Self.ownershipKey(name), !referenced.contains(key) else { continue }
            deletePartFileIfPresent(name)
        }
    }

    /// Deletes part files with no owning job — e.g. a crash between cancel and cleanup.
    /// Application Support is never auto-purged, so this reconciliation runs on launch.
    /// Returns the removed names (sorted) for logging.
    @discardableResult
    public func reconcileOrphanParts() throws -> [String] {
        let referenced = Set(jobs.flatMap(\.ownedPartFileNames).compactMap(Self.ownershipKey))
        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: partsDirectory.path)
        } catch {
            // Unreadable parts dir → skip this pass (retried next launch); record why.
            diagnostics?.record(kind: "transfer_reconcile_skipped", detail: "\(error)")
            return []
        }
        var removed: [String] = []
        for name in contents where Self.ownershipKey(name).map({ !referenced.contains($0) }) ?? true {
            do {
                if try SafeFileComponent.removeEnumeratedRegularFileOrSymbolicLink(
                    named: name,
                    from: partsDirectory
                ) {
                    removed.append(name)
                }
            } catch {
                diagnostics?.record(kind: "transfer_part_delete", detail: "\(name): \(error)")
            }
        }
        return removed.sorted()
    }

    /// Deletes a part file; recovery for a failure is the next `reconcileOrphanParts` pass, so
    /// the error is recorded (diagnosable) rather than dropped.
    private func deletePartFileIfPresent(_ name: String) {
        do {
            let url = try validatedPartFileURL(for: name)
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            try FileManager.default.removeItem(at: url)
        } catch {
            diagnostics?.record(kind: "transfer_part_delete", detail: "\(name): \(error)")
        }
    }

    /// Resolves a validated part-file name to its absolute URL. Core production paths use the
    /// throwing variant; this convenience preserves the existing API for already-validated jobs
    /// and traps on programmer misuse rather than ever returning an escaped path.
    public nonisolated func partFileURL(for name: String) -> URL {
        do { return try validatedPartFileURL(for: name) }
        catch { preconditionFailure("Unsafe transfer part filename: \(name)") }
    }

    public nonisolated func validatedPartFileURL(for name: String) throws -> URL {
        try SafeFileComponent(name).regularFileURL(in: partsDirectory)
    }

    /// Writes a complete candidate snapshot. Callers publish it to `jobs` only after this atomic
    /// write succeeds, keeping the actor's in-memory view identical to the durable view.
    private func persist(_ candidate: [TransferJob]) throws {
        let data = try JSONEncoder().encode(candidate)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Rehydrates the persisted jobs. Missing file → empty (first launch). A corrupt/
    /// incompatible file is *quarantined* (moved aside) so it's preserved for debugging and
    /// can't crash-loop the store, and the event is recorded — not silently discarded.
    private static func load(_ url: URL, diagnostics: (any TransferDiagnostics)?) -> [TransferJob] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return []   // first launch — no transfers.json yet (an expected, non-error state)
        }
        do {
            let decoded = try JSONDecoder().decode([TransferJob].self, from: data)
            try validate(decoded)
            return decoded
        } catch {
            let quarantine = url.deletingPathExtension().appendingPathExtension("corrupt.json")
            do {
                if FileManager.default.fileExists(atPath: quarantine.path) {
                    try FileManager.default.removeItem(at: quarantine)   // replace a prior quarantine
                }
                try FileManager.default.moveItem(at: url, to: quarantine)
                diagnostics?.record(kind: "transfer_store_corrupt",
                                    detail: "quarantined to \(quarantine.lastPathComponent): \(error)")
            } catch let moveError {
                diagnostics?.record(kind: "transfer_store_corrupt",
                                    detail: "could not quarantine (\(moveError)); starting empty")
            }
            return []
        }
    }

    /// Validates every persisted component at the store boundary. A candidate is never written or
    /// published in memory until this passes; decoded legacy/malicious stores are quarantined.
    private static func validate(_ jobs: [TransferJob]) throws {
        var jobIDs: Set<UUID> = []
        var ownedParts: Set<String> = []
        for job in jobs {
            guard jobIDs.insert(job.id).inserted else {
                throw SafeFileComponent.ValidationError.duplicateJobID(job.id.uuidString)
            }
            for name in job.ownedPartFileNames {
                let component = try SafeFileComponent(name)
                guard ownedParts.insert(component.ownershipKey).inserted else {
                    throw SafeFileComponent.ValidationError.duplicateOwnership(name)
                }
            }
            if let savedFilename = job.savedFilename { _ = try SafeFileComponent(savedFilename) }
        }
    }

    private static func ownershipKey(_ name: String) -> String? {
        try? SafeFileComponent(name).ownershipKey
    }

    private func validate(_ jobs: [TransferJob]) throws {
        try Self.validate(jobs)
    }
}
