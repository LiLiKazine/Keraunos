import Testing
import Foundation
import KeraunosCore

struct TransferJobStoreTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func progressiveJob(id: UUID = UUID(), partName: String = "p.part",
                                state: JobState = .queued) -> TransferJob {
        let track = TrackJob(
            remoteURL: URL(string: "https://cdn.example/p.mp4")!,
            urlExpiresAt: nil, chunkSize: nil, partFileName: partName,
            bytesWritten: 0, totalBytes: nil, resumeData: nil, taskIdentifier: nil)
        return TransferJob(
            id: id, sourcePageURL: URL(string: "https://ex.com")!,
            formatSelection: FormatSelection(formatID: "18", height: 360, isAdaptive: false),
            credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
            state: state, kind: .progressive(track),
            suggestedFilename: "p.mp4", savedFilename: nil, autoSaveToPhotos: false)
    }

    @Test func upsertPersistsAcrossStoreInstances() async throws {
        let dir = tempDir()
        let job = progressiveJob()
        try await TransferJobStore(directory: dir).upsert(job)

        // A fresh store instance over the same directory rehydrates from disk.
        let reloaded = try TransferJobStore(directory: dir)
        #expect(await reloaded.all() == [job])
        #expect(await reloaded.job(id: job.id) == job)
    }

    @Test func upsertReplacesExistingJobById() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let id = UUID()
        try await store.upsert(progressiveJob(id: id, state: .queued))
        try await store.upsert(progressiveJob(id: id, state: .downloading))
        #expect(await store.all().count == 1)
        #expect(await store.job(id: id)?.state == .downloading)
    }

    @Test func updateMutatesAndPersists() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let job = progressiveJob(state: .downloading)
        try await store.upsert(job)

        let returned = try await store.update(id: job.id) { $0.state = .failed(.network) }
        #expect(returned?.state == .failed(.network))
        let reloadedState = try await TransferJobStore(directory: dir).job(id: job.id)?.state
        #expect(reloadedState == .failed(.network))
    }

    @Test func updateUnknownIdReturnsNil() async throws {
        let store = try TransferJobStore(directory: tempDir())
        let result = try await store.update(id: UUID()) { $0.state = .cancelled }
        #expect(result == nil)
    }

    @Test func removeDeletesJobAndItsPartFiles() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let job = progressiveJob(partName: "p.part")
        try await store.upsert(job)
        // Create the part file this job owns (partFileURL is nonisolated — no await).
        let partURL = store.partFileURL(for: "p.part")
        try Data([1, 2, 3]).write(to: partURL)

        try await store.remove(id: job.id)

        #expect(await store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
    }

    @Test func loadsEmptyWhenNoFileYet() async throws {
        let store = try TransferJobStore(directory: tempDir())
        #expect(await store.all().isEmpty)
    }

    @Test func defaultDirectoryIsApplicationSupport() {
        // Check the static path — do NOT construct a default store, which would create a
        // real ~/Library/Application Support/Transfers on the host during tests.
        #expect(TransferJobStore.defaultDirectory.path.contains("Application Support"))
    }
}
