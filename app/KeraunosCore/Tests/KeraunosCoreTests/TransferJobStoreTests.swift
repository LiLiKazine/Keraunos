import Testing
import Foundation
import KeraunosCore

struct TransferJobStoreTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
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
            formatSelection: FormatSelection(formatID: "18", height: 360, isDASH: false),
            credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
            state: state, kind: .progressive(track),
            suggestedFilename: "p.mp4", savedFilename: nil, autoSaveToPhotos: false)
    }

    @Test func sharedFixturesKeepFormatSelectionConsistentWithJobKind() {
        let progressive = TransferFixtures.progressiveJob()
        let DASH = TransferFixtures.dashJob()

        #expect(!progressive.formatSelection.isDASH)
        #expect(DASH.formatSelection.isDASH)
    }

    @Test func upsertPersistsAcrossStoreInstances() async throws {
        let storage = try TemporaryTransferJobStore()
        let job = TransferFixtures.progressiveJob()
        try await storage.store.upsert(job)

        // A fresh store instance over the same directory rehydrates from disk.
        let reloaded = try storage.reloadedStore()
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
        let storage = try TemporaryTransferJobStore()
        let job = TransferFixtures.progressiveJob(state: .downloading)
        try await storage.store.upsert(job)

        let returned = try await storage.store.update(id: job.id) { $0.state = .failed(.network) }
        #expect(returned?.state == .failed(.network))
        let reloaded = try storage.reloadedStore()
        let reloadedState = await reloaded.job(id: job.id)?.state
        #expect(reloadedState == .failed(.network))
    }

    @Test func updateUnknownIdReturnsNil() async throws {
        let store = try TransferJobStore(directory: tempDir())
        let result = try await store.update(id: UUID()) { $0.state = .cancelled }
        #expect(result == nil)
    }

    @Test func failedUpdateRollsBackInMemoryMutation() async throws {
        let storage = try TemporaryTransferJobStore()
        let dir = storage.directory
        let store = storage.store
        let job = progressiveJob(state: .queued)
        try await store.upsert(job)
        try makeReadOnly(dir)
        defer { makeWritable(dir) }

        do {
            try await store.update(id: job.id) { $0.state = .completed }
            Issue.record("Expected persistence to fail")
        } catch {}

        #expect(await store.job(id: job.id)?.state == .queued)
    }

    @Test func failedUpsertDoesNotPublishCandidateInMemory() async throws {
        let storage = try TemporaryTransferJobStore()
        let dir = storage.directory
        let store = storage.store
        let original = progressiveJob(state: .queued)
        let candidate = progressiveJob(state: .downloading)
        try await store.upsert(original)
        try makeReadOnly(dir)
        defer { makeWritable(dir) }

        do {
            try await store.upsert(candidate)
            Issue.record("Expected persistence to fail")
        } catch {}

        #expect(await store.all() == [original])
    }

    @Test func failedRemoveRetainsJobAndPartUntilRemovalIsDurable() async throws {
        let storage = try TemporaryTransferJobStore()
        let dir = storage.directory
        let store = storage.store
        let job = progressiveJob(partName: "p.part")
        try await store.upsert(job)
        let partURL = store.partFileURL(for: "p.part")
        try Data([1, 2, 3]).write(to: partURL)
        try makeReadOnly(dir)
        defer { makeWritable(dir) }

        do {
            try await store.remove(id: job.id)
            Issue.record("Expected persistence to fail")
        } catch {}

        #expect(await store.job(id: job.id) == job)
        #expect(FileManager.default.fileExists(atPath: partURL.path))
    }

    @Test(arguments: ["", ".", "..", "../outside", "/tmp/outside",
                      "nested/file", "nested\\file", "\\absolute"])
    func rejectsUnsafePartComponentsOnUpsert(_ component: String) async throws {
        let storage = try TemporaryTransferJobStore()
        let job = progressiveJob(partName: component)

        do {
            try await storage.store.upsert(job)
            Issue.record("Expected unsafe component to be rejected: \(component)")
        } catch {}

        #expect(await storage.store.all().isEmpty)
    }

    @Test func unsafeUpdateRollsBackWithoutPublishingTheCandidate() async throws {
        let storage = try TemporaryTransferJobStore()
        let job = progressiveJob(partName: "safe.part")
        try await storage.store.upsert(job)

        do {
            try await storage.store.update(id: job.id) {
                $0.kind = .progressive(self.track(partName: "../outside"))
            }
            Issue.record("Expected unsafe component to be rejected")
        } catch {}

        #expect(await storage.store.job(id: job.id) == job)
    }

    @Test func malformedPersistedPartIsQuarantinedAndOutsideSentinelSurvives() async throws {
        let storage = try TemporaryTransferJobStore()
        let outside = storage.directory.appendingPathComponent("outside")
        let sentinel = Data("do not touch".utf8)
        try sentinel.write(to: outside)
        let malicious = progressiveJob(partName: "../outside", state: .completed)
        try JSONEncoder().encode([malicious]).write(
            to: storage.directory.appendingPathComponent("transfers.json"), options: .atomic)

        let reloaded = try storage.reloadedStore()

        #expect(await reloaded.all().isEmpty)
        #expect(try Data(contentsOf: outside) == sentinel)
        #expect(FileManager.default.fileExists(
            atPath: storage.directory.appendingPathComponent("transfers.corrupt.json").path))
    }

    @Test func malformedPersistedSavedFilenameIsQuarantinedBeforeRecovery() async throws {
        let storage = try TemporaryTransferJobStore()
        var malicious = progressiveJob(partName: "safe.part", state: .merging)
        malicious.savedFilename = "../outside.mp4"
        try JSONEncoder().encode([malicious]).write(
            to: storage.directory.appendingPathComponent("transfers.json"), options: .atomic)

        let reloaded = try storage.reloadedStore()

        #expect(await reloaded.all().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: storage.directory.appendingPathComponent("transfers.corrupt.json").path))
    }

    @Test func rejectedTraversalCannotEscapeDuringRemovalOrReconciliation() async throws {
        let storage = try TemporaryTransferJobStore()
        let outside = storage.directory.appendingPathComponent("outside")
        let sentinel = Data("keep".utf8)
        try sentinel.write(to: outside)
        let malicious = progressiveJob(partName: "../outside")

        do { try await storage.store.upsert(malicious) } catch {}
        try await storage.store.remove(id: malicious.id)
        _ = try await storage.store.reconcileOrphanParts()

        #expect(try Data(contentsOf: outside) == sentinel)
    }

    @Test func inBasePartSymlinkCannotBeReadWrittenTruncatedOrDeletedThroughStorePaths() async throws {
        let storage = try TemporaryTransferJobStore()
        let job = progressiveJob(partName: "safe.part", state: .downloading)
        try await storage.store.upsert(job)

        let outside = storage.directory.appendingPathComponent("outside-sentinel")
        let sentinel = Data("outside must survive".utf8)
        try sentinel.write(to: outside)
        let link = storage.store.partFileURL(for: "safe.part")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        do {
            let escaped = try storage.store.validatedPartFileURL(for: "safe.part")
            _ = try Data(contentsOf: escaped)
            Issue.record("Expected a symbolic-link part to be rejected before reading")
        } catch {}
        do {
            let escaped = try storage.store.validatedPartFileURL(for: "safe.part")
            try PartFile(url: escaped).truncate(to: 0)
            Issue.record("Expected a symbolic-link part to be rejected before truncating")
        } catch {}
        do {
            let escaped = try storage.store.validatedPartFileURL(for: "safe.part")
            try PartFile(url: escaped).append(Data("overwrite".utf8))
            Issue.record("Expected a symbolic-link part to be rejected before appending")
        } catch {}

        try await storage.store.remove(id: job.id)

        #expect(try Data(contentsOf: outside) == sentinel)
        #expect(FileManager.default.fileExists(atPath: link.path))
    }

    @Test func symlinkedTransferBaseIsRejectedBeforeStoreCreationWritesThroughIt() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let realBase = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: realBase, withIntermediateDirectories: true)
        let sentinel = realBase.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let alias = root.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: realBase)

        #expect(throws: (any Error).self) {
            _ = try TransferJobStore(directory: alias)
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: realBase.appendingPathComponent("parts", isDirectory: true).path))
    }

    @Test func symlinkedPartsDirectoryIsRejectedWithoutTouchingItsTarget() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let base = root.appendingPathComponent("store", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("parts", isDirectory: true),
            withDestinationURL: outside)

        #expect(throws: (any Error).self) {
            _ = try TransferJobStore(directory: base)
        }
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }

    @Test func duplicatePartOwnershipAcrossJobsRejectsCaseAndUnicodeAliases() async throws {
        let storage = try TemporaryTransferJobStore()
        let owner = progressiveJob(partName: "Caf\u{00E9}.part")
        let alias = progressiveJob(partName: "CAFE\u{0301}.PART")
        try await storage.store.upsert(owner)

        do {
            try await storage.store.upsert(alias)
            Issue.record("Expected canonically equivalent part ownership to be rejected")
        } catch {}

        #expect(await storage.store.all() == [owner])
    }

    @Test func dashJobCannotOwnTheSamePartThroughCaseAliases() async throws {
        let storage = try TemporaryTransferJobStore()
        var duplicate = progressiveJob(partName: "unused.part")
        duplicate.kind = .dash(
            video: track(partName: "media.part"),
            audio: track(partName: "MEDIA.PART"))

        do {
            try await storage.store.upsert(duplicate)
            Issue.record("Expected duplicate DASH part ownership to be rejected")
        } catch {}

        #expect(await storage.store.all().isEmpty)
    }

    @Test func duplicateOwnershipUpdateRollsBackAndRemovalCannotDeleteSurvivorPart() async throws {
        let storage = try TemporaryTransferJobStore()
        let first = progressiveJob(partName: "first.part")
        let survivor = progressiveJob(partName: "survivor.part")
        try await storage.store.upsert(first)
        try await storage.store.upsert(survivor)
        let survivorPart = storage.store.partFileURL(for: "survivor.part")
        let bytes = Data("survivor".utf8)
        try bytes.write(to: survivorPart)

        do {
            try await storage.store.update(id: first.id) {
                $0.kind = .progressive(self.track(partName: "SURVIVOR.PART"))
            }
            Issue.record("Expected an alias of another job's part to be rejected")
        } catch {}
        try await storage.store.remove(id: first.id)

        #expect(await storage.store.job(id: survivor.id) == survivor)
        #expect(try Data(contentsOf: survivorPart) == bytes)
    }

    @Test func duplicatePartOwnershipInPersistedStoreIsQuarantined() async throws {
        let storage = try TemporaryTransferJobStore()
        let first = progressiveJob(partName: "Caf\u{00E9}.part")
        let second = progressiveJob(partName: "cafe\u{0301}.PART")
        try JSONEncoder().encode([first, second]).write(
            to: storage.directory.appendingPathComponent("transfers.json"), options: .atomic)

        let reloaded = try storage.reloadedStore()

        #expect(await reloaded.all().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: storage.directory.appendingPathComponent("transfers.corrupt.json").path))
    }

    @Test func duplicateJobIDsInPersistedStoreAreQuarantined() async throws {
        let storage = try TemporaryTransferJobStore()
        let id = UUID()
        let first = progressiveJob(id: id, partName: "first.part")
        let second = progressiveJob(id: id, partName: "second.part")
        try JSONEncoder().encode([first, second]).write(
            to: storage.directory.appendingPathComponent("transfers.json"), options: .atomic)

        let reloaded = try storage.reloadedStore()

        #expect(await reloaded.all().isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: storage.directory.appendingPathComponent("transfers.corrupt.json").path))
    }

    @Test(arguments: [".", "..", "../outside", "/tmp/outside",
                      "nested/file", "nested\\file", "\\absolute"])
    func rejectsUnsafeSavedFilenameComponents(_ component: String) async throws {
        let storage = try TemporaryTransferJobStore()
        var job = progressiveJob(partName: "safe.part", state: .merging)
        job.savedFilename = component

        do {
            try await storage.store.upsert(job)
            Issue.record("Expected unsafe saved filename to be rejected: \(component)")
        } catch {}

        #expect(await storage.store.all().isEmpty)
    }

    @Test func removeDeletesJobAndItsPartFiles() async throws {
        let storage = try TemporaryTransferJobStore()
        let job = TransferFixtures.progressiveJob(track: .transferFixture(part: "p.part"))
        try await storage.store.upsert(job)
        // Create the part file this job owns (partFileURL is nonisolated — no await).
        let partURL = storage.store.partFileURL(for: "p.part")
        try Data([1, 2, 3]).write(to: partURL)
        let checkpointURL = storage.store.partFileURL(
            for: job.finalizationPromotionCheckpointFileName)
        try Data([4, 5, 6]).write(to: checkpointURL)

        try await storage.store.remove(id: job.id)

        #expect(await storage.store.all().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: partURL.path))
        #expect(!FileManager.default.fileExists(atPath: checkpointURL.path))
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

    @Test func reconcileOrphanPartsRemovesUnreferencedFilesOnly() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        try await store.upsert(
            TransferFixtures.progressiveJob(track: .transferFixture(part: "keep.part"))
        )
        // One referenced part, one orphan left behind by a crash between cancel and cleanup.
        try Data([1]).write(to: store.partFileURL(for: "keep.part"))
        try Data([2]).write(to: store.partFileURL(for: "orphan.part"))

        let removed = try await store.reconcileOrphanParts()

        #expect(removed == ["orphan.part"])
        #expect(FileManager.default.fileExists(atPath: store.partFileURL(for: "keep.part").path))
        #expect(!FileManager.default.fileExists(atPath: store.partFileURL(for: "orphan.part").path))
    }

    @Test func reconcileOrphanPartsNoopWhenAllReferenced() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        try await store.upsert(progressiveJob(partName: "p.part"))
        try Data([1]).write(to: store.partFileURL(for: "p.part"))
        let removed = try await store.reconcileOrphanParts()
        #expect(removed.isEmpty)
    }

    @Test func reconcileReportsOnlySafelyDeletedChildrenAndNeverFollowsSymlinks() async throws {
        let storage = try TemporaryTransferJobStore()
        let store = storage.store
        let sentinel = storage.directory.appendingPathComponent("outside-sentinel")
        let sentinelBytes = Data("keep".utf8)
        try sentinelBytes.write(to: sentinel)
        let partsDirectory = await store.partsDirectory
        let stale = partsDirectory.appendingPathComponent("stale.part")
        try Data("stale".utf8).write(to: stale)
        let hostileLink = partsDirectory.appendingPathComponent("hostile-link")
        try FileManager.default.createSymbolicLink(at: hostileLink, withDestinationURL: sentinel)
        let unsafeName = partsDirectory.appendingPathComponent("hostile\\name")
        try Data("also stale".utf8).write(to: unsafeName)
        let retainedDirectory = partsDirectory.appendingPathComponent("not-a-file", isDirectory: true)
        try FileManager.default.createDirectory(at: retainedDirectory,
                                                withIntermediateDirectories: true)

        let removed = try await store.reconcileOrphanParts()

        #expect(removed == ["hostile-link", "hostile\\name", "stale.part"])
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        #expect(!FileManager.default.fileExists(atPath: hostileLink.path))
        #expect(!FileManager.default.fileExists(atPath: unsafeName.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: retainedDirectory.path))
    }

    private func makeReadOnly(_ directory: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: directory.path)
    }

    private func makeWritable(_ directory: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: directory.path)
    }

    private func track(partName: String) -> TrackJob {
        TrackJob(remoteURL: URL(string: "https://cdn.example/p.mp4")!, urlExpiresAt: nil,
                 chunkSize: nil, partFileName: partName, bytesWritten: 0, totalBytes: nil,
                 resumeData: nil, taskIdentifier: nil)
    }
}
