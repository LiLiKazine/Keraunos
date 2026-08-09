import Foundation
import KeraunosCore
import Testing

/// Stable examples for transfer-domain tests. Defaults describe one ordinary queued download;
/// individual tests override only the state that matters to the behavior under test.
enum TransferFixtures {
    static func progressiveJob(
        id: UUID = UUID(),
        track: TrackJob = .transferFixture(),
        state: JobState = .queued
    ) -> TransferJob {
        job(id: id, kind: .progressive(track), state: state)
    }

    static func dashJob(
        id: UUID = UUID(),
        video: TrackJob = .transferFixture(part: "video.part"),
        audio: TrackJob = .transferFixture(part: "audio.part"),
        state: JobState = .queued
    ) -> TransferJob {
        job(id: id, kind: .dash(video: video, audio: audio), state: state)
    }

    static func job(
        id: UUID = UUID(),
        kind: TransferJob.Kind,
        state: JobState = .queued
    ) -> TransferJob {
        let isDASH: Bool
        switch kind {
        case .progressive: isDASH = false
        case .dash: isDASH = true
        }

        return TransferJob(
            id: id,
            sourcePageURL: URL(string: "https://example.com/watch")!,
            formatSelection: FormatSelection(
                formatID: "fixture", height: nil, isDASH: isDASH
            ),
            credentialRef: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            state: state,
            kind: kind,
            suggestedFilename: "fixture.mp4",
            savedFilename: nil,
            autoSaveToPhotos: false
        )
    }
}

extension TrackJob {
    static func transferFixture(
        part: String = "media.part",
        chunkSize: Int? = nil,
        bytesWritten: Int64 = 0,
        totalBytes: Int64? = nil,
        resumeData: Data? = nil,
        taskIdentifier: Int? = nil,
        expiresAt: Date? = nil,
        requestHeaders: [String: String] = [:],
        approxBytes: Int64? = nil
    ) -> TrackJob {
        TrackJob(
            remoteURL: URL(string: "https://cdn.example/\(part)")!,
            urlExpiresAt: expiresAt,
            chunkSize: chunkSize,
            partFileName: part,
            bytesWritten: bytesWritten,
            totalBytes: totalBytes,
            resumeData: resumeData,
            taskIdentifier: taskIdentifier,
            requestHeaders: requestHeaders,
            approxBytes: approxBytes
        )
    }
}

/// A real store rooted in a unique temporary directory. A fresh `reloadedStore()` reads the
/// same durable state, while releasing this fixture removes the directory and its part files.
final class TemporaryTransferJobStore {
    let directory: URL
    let store: TransferJobStore

    init(diagnostics: (any TransferDiagnostics)? = nil) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeraunosCoreTests-\(UUID().uuidString)", isDirectory: true)
        store = try TransferJobStore(directory: directory, diagnostics: diagnostics)
    }

    deinit {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove Core harness directory: \(error)")
        }
    }

    func reloadedStore(diagnostics: (any TransferDiagnostics)? = nil) throws -> TransferJobStore {
        try TransferJobStore(directory: directory, diagnostics: diagnostics)
    }
}

/// A real transfer-domain composition rooted in an isolated temporary directory.
///
/// Tests arrange durable jobs, drive `coordinator` ingress, and then inspect the real store,
/// session requests, progress bus, and diagnostics. Staged files live under `directory`, so
/// releasing the harness deterministically removes every artifact the behavior created.
final class TransferDomainHarness {
    private let storage: TemporaryTransferJobStore
    let directory: URL
    let store: TransferJobStore
    let session: ScriptedTransferSession
    let progress: TransferProgress
    let diagnostics: SpyDiagnostics
    let coordinator: TransferCoordinator

    init(now: @Sendable @escaping () -> Date = { Date() }) throws {
        let diagnostics = SpyDiagnostics()
        let storage = try TemporaryTransferJobStore(diagnostics: diagnostics)
        let store = storage.store
        let session = ScriptedTransferSession()
        let progress = TransferProgress()

        self.storage = storage
        self.directory = storage.directory
        self.store = store
        self.session = session
        self.progress = progress
        self.diagnostics = diagnostics
        self.coordinator = TransferCoordinator(
            store: store,
            session: session,
            now: now,
            diagnostics: diagnostics,
            progress: progress
        )
    }

    func stage(_ data: Data, named name: String = "response") throws -> URL {
        let staging = directory.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let url = staging.appendingPathComponent("\(name)-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }

    func persistedJob(_ id: UUID) async -> TransferJob? {
        await store.job(id: id)
    }

    func reloadedJob(_ id: UUID) async throws -> TransferJob? {
        let reloaded = try storage.reloadedStore()
        return await reloaded.job(id: id)
    }
}
