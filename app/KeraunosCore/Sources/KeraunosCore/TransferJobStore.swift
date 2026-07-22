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
        self.directory = base
        self.partsDirectory = base.appendingPathComponent("parts", isDirectory: true)
        self.fileURL = base.appendingPathComponent("transfers.json")
        self.diagnostics = diagnostics
        // Creating the parts dir with intermediates also creates `base`.
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        self.jobs = Self.load(fileURL, diagnostics: diagnostics)
    }

    public func all() -> [TransferJob] { jobs }

    public func job(id: UUID) -> TransferJob? { jobs.first { $0.id == id } }

    /// Adds a job, or replaces the existing one with the same id.
    public func upsert(_ job: TransferJob) throws {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[i] = job
        } else {
            jobs.append(job)
        }
        try persist()
    }

    /// Mutates a job in place and persists. Returns the updated job, or nil if not found.
    @discardableResult
    public func update(id: UUID, _ mutate: @Sendable (inout TransferJob) -> Void) throws -> TransferJob? {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return nil }
        mutate(&jobs[i])
        try persist()
        return jobs[i]
    }

    /// Removes a job and deletes the part files it owned (best-effort).
    public func remove(id: UUID) throws {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        for name in jobs[i].trackPartFileNames {
            deletePartFileIfPresent(name)
        }
        jobs.remove(at: i)
        try persist()
    }

    /// Deletes part files with no owning job — e.g. a crash between cancel and cleanup.
    /// Application Support is never auto-purged, so this reconciliation runs on launch.
    /// Returns the removed names (sorted) for logging.
    @discardableResult
    public func reconcileOrphanParts() throws -> [String] {
        let referenced = Set(jobs.flatMap(\.trackPartFileNames))
        let contents: [String]
        do {
            contents = try FileManager.default.contentsOfDirectory(atPath: partsDirectory.path)
        } catch {
            // Unreadable parts dir → skip this pass (retried next launch); record why.
            diagnostics?.record(kind: "transfer_reconcile_skipped", detail: "\(error)")
            return []
        }
        var removed: [String] = []
        for name in contents where !referenced.contains(name) {
            deletePartFileIfPresent(name)
            removed.append(name)
        }
        return removed.sorted()
    }

    /// Deletes a part file; recovery for a failure is the next `reconcileOrphanParts` pass, so
    /// the error is recorded (diagnosable) rather than dropped.
    private func deletePartFileIfPresent(_ name: String) {
        do {
            try FileManager.default.removeItem(at: partFileURL(for: name))
        } catch {
            diagnostics?.record(kind: "transfer_part_delete", detail: "\(name): \(error)")
        }
    }

    /// Resolves a part-file name to its absolute URL. `nonisolated` — it reads only the
    /// immutable `partsDirectory`, so callers don't need to `await`.
    public nonisolated func partFileURL(for name: String) -> URL {
        partsDirectory.appendingPathComponent(name)
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(jobs)
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
            return try JSONDecoder().decode([TransferJob].self, from: data)
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
}
