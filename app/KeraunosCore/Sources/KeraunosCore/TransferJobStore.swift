import Foundation

/// Durable owner of the transfer job set. Persists atomically to Application Support on
/// every mutation and rehydrates on init, so the queue survives suspension, termination,
/// and relaunch. Part files live in a sibling `parts/` directory, addressed by name.
public actor TransferJobStore {
    public let directory: URL
    public let partsDirectory: URL
    private let fileURL: URL
    private var jobs: [TransferJob]

    /// Default base directory: `<Application Support>/Transfers`.
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transfers", isDirectory: true)
    }

    public init(directory: URL? = nil) throws {
        let base = directory ?? Self.defaultDirectory
        self.directory = base
        self.partsDirectory = base.appendingPathComponent("parts", isDirectory: true)
        self.fileURL = base.appendingPathComponent("transfers.json")
        // Creating the parts dir with intermediates also creates `base`.
        try FileManager.default.createDirectory(at: partsDirectory, withIntermediateDirectories: true)
        self.jobs = Self.load(fileURL)
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
            try? FileManager.default.removeItem(at: partFileURL(for: name))
        }
        jobs.remove(at: i)
        try persist()
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

    private static func load(_ url: URL) -> [TransferJob] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TransferJob].self, from: data)) ?? []
    }
}
