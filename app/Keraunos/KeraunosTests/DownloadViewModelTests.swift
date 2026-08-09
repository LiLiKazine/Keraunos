import Testing
import Foundation
import KeraunosCore
@testable import Keraunos

@MainActor
struct DownloadViewModelTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func progressive(_ name: String) -> ResolvedMedia {
        AppTestMedia.progressive(
            filename: name,
            title: "t",
            remoteURL: URL(string: "https://x.test/v.mp4")!)
    }
    private func vm(extractor: any MediaExtracting, dir: URL,
                    enqueuer: any JobEnqueuing = SpyEnqueuer()) -> DownloadViewModel {
        DownloadViewModel(extractor: extractor, store: DownloadStore(directory: dir), enqueuer: enqueuer)
    }
    private func choices(_ options: [FormatOption]) -> MockExtractor {
        var m = MockExtractor(result: .success(progressive("picked.mp4")))
        m.listing = .success(.choices(options))
        return m
    }
    private var sampleOption: FormatOption {
        AppTestMedia.option()
    }

    final class MockPhotoSaver: PhotoSaving {
        var result: PhotoSaveResult
        private(set) var savedURLs: [URL] = []
        init(result: PhotoSaveResult) { self.result = result }
        func save(_ fileURL: URL) async -> PhotoSaveResult {
            savedURLs.append(fileURL); return result
        }
    }

    private func saverVM(_ saver: any PhotoSaving) -> DownloadViewModel {
        DownloadViewModel(extractor: MockExtractor(),
                          store: DownloadStore(directory: tempDir()),
                          photoSaver: saver)
    }

    @Test func saveToPhotosReportsSuccess() async {
        let saver = MockPhotoSaver(result: .saved)
        let model = saverVM(saver)
        let file = URL(fileURLWithPath: "/tmp/clip.mp4")
        await model.saveToPhotos(file)
        #expect(saver.savedURLs == [file])
        #expect(model.saveMessage == "Saved to Photos.")
    }

    @Test func saveToPhotosReportsPermissionDenied() async {
        let model = saverVM(MockPhotoSaver(result: .permissionDenied))
        await model.saveToPhotos(URL(fileURLWithPath: "/tmp/clip.mp4"))
        #expect(model.saveMessage == "Allow Photos access in Settings to save videos.")
    }

    @Test func saveToPhotosReportsFailure() async {
        let model = saverVM(MockPhotoSaver(result: .failed))
        await model.saveToPhotos(URL(fileURLWithPath: "/tmp/clip.mp4"))
        #expect(model.saveMessage == "Couldn't save to Photos.")
    }

    @Test func saveToPhotosSkipsIncompatibleFileAndDoesNotCallSaver() async {
        let saver = MockPhotoSaver(result: .saved)
        let model = saverVM(saver)
        await model.saveToPhotos(URL(fileURLWithPath: "/tmp/clip.mkv"))
        #expect(saver.savedURLs.isEmpty)
        #expect(model.saveMessage == nil)
    }

    @Test func successfulProgressiveResolveEnqueuesJob() async {
        let harness = DownloadViewModelHarness.ready(.progressive(filename: "clip.mp4"))

        await harness.start("https://x.test/post/1")

        #expect(harness.model.errorMessage == nil)
        #expect(harness.model.isWorking == false)
        #expect(harness.enqueuedJob?.sourcePageURL == URL(string: "https://x.test/post/1"))
        #expect(harness.enqueuedJob?.suggestedFilename == "clip.mp4")
    }

    @Test func harnessDeinitRemovesOwnedStorageAndPreferences() throws {
        var harness: DownloadViewModelHarness? = .ready(.progressive(filename: "clip.mp4"))
        let directory = try #require(harness?.storageDirectory)
        let suite = try #require(harness?.defaultsSuiteIdentifier)
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "cleanup-marker")

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(UserDefaults.standard.persistentDomain(forName: suite) != nil)

        harness = nil

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(UserDefaults.standard.persistentDomain(forName: suite) == nil)
    }

    @Test func resolvedDownloadProjectsIntoTheQueue() async throws {
        let download = DownloadViewModelHarness.ready(
            .progressive(filename: "Harness Clip.mp4"))

        await download.start("x.test/post/1")

        let job = try #require(download.enqueuedJob)
        let row = try #require(QueueProjectionHarness(jobs: [job]).onlyRow)
        #expect(job.sourcePageURL == URL(string: "https://x.test/post/1"))
        #expect(row.title == "Harness Clip")
        #expect(row.sourceHost == "x.test")
        #expect(row.rowState == .queued)
    }

    // Merge failures now surface from the engine/finalizer (Task B-series), not this view
    // model — there is no longer a VM-level assertion to make about a merge outcome; the VM's
    // job ends at enqueue.

    @Test func extractionErrorShowsMessage() async {
        let harness = DownloadViewModelHarness.failing(.needsFfmpeg)

        await harness.start("https://x.test/post/1")

        #expect(harness.model.errorMessage == KeraunosError.needsFfmpeg.errorDescription)
    }

    @Test func openIncomingDeepLinkFillsFieldAndEnqueues() async {
        let spy = SpyEnqueuer()
        let model = vm(extractor: MockExtractor(result: .success(progressive("clip.mp4"))),
                       dir: tempDir(), enqueuer: spy)
        model.openIncoming(URL(string: "keraunos://download?url=https://x.test/v")!)
        await model.currentTask?.value
        #expect(model.urlText == "https://x.test/v")
        #expect(spy.enqueued.count == 1)
        #expect(spy.enqueued.first?.sourcePageURL == URL(string: "https://x.test/v"))
    }

    @Test func openIncomingIgnoresUnsupportedURL() async {
        let model = vm(extractor: MockExtractor(), dir: tempDir())
        model.openIncoming(URL(string: "ftp://x.test/v")!)
        #expect(model.urlText == "")          // untouched
        #expect(model.currentTask == nil)     // no download started
    }

    @Test(arguments: [KeraunosError.extractNetwork, .timedOut, .downloadNetwork])
    func autoRetriesOnceOnTransientColdStart(_ first: KeraunosError) async {
        // Transient transport faults — a YouTube cold-start surfacing as extract_network
        // or a watchdog timeout (the EJS-in-JSC solve is heavy on the first run), or a
        // mid-transfer download blip — clear on a warm retry, which succeeds.
        let harness = DownloadViewModelHarness(listings: [
            .failure(first),
            .success(.ready(.progressive(filename: "clip.mp4"))),
        ])

        await harness.start("https://x.test/post/1")

        #expect(harness.model.errorMessage == nil)     // the transient blip was never surfaced
        #expect(harness.enqueuedJobs.count == 1)       // exactly one job — succeeded on the auto-retry
    }

    @Test func doesNotAutoRetryTerminalErrors() async {
        // A second attempt won't help unsupported, so it must surface immediately.
        let spy = SpyEnqueuer()
        let extractor = SequenceExtractor(results: [
            .failure(.unsupported),
            .success(progressive("clip.mp4")),   // would be consumed only if it wrongly retried
        ])
        let model = DownloadViewModel(
            extractor: extractor,
            store: DownloadStore(directory: tempDir()),
            enqueuer: spy)
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == KeraunosError.unsupported.errorDescription)
        #expect(spy.enqueued.isEmpty)
    }

    @Test func doesNotAutoRetryRateLimited() async {
        // A rate-limit means "wait" — re-hammering immediately is exactly wrong, so it
        // must surface at once. The queued success is left UNCONSUMED, proving no auto-
        // retry fired; manual retry is still offered.
        let spy = SpyEnqueuer()
        let extractor = SequenceExtractor(results: [
            .failure(.rateLimited),
            .success(progressive("clip.mp4")),
        ])
        let model = DownloadViewModel(
            extractor: extractor,
            store: DownloadStore(directory: tempDir()),
            enqueuer: spy)
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == KeraunosError.rateLimited.errorDescription)
        #expect(spy.enqueued.isEmpty)   // success not consumed → no auto-retry
        #expect(model.canRetry == true)
    }

    @Test func transientFailureOffersRetryButNotSignIn() async {
        let model = vm(extractor: MockExtractor(result: .failure(.downloadNetwork)), dir: tempDir())
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.canRetry == true)
        #expect(model.requiresSignIn == false)
    }

    @Test func terminalFailureDoesNotOfferRetry() async {
        let model = vm(extractor: MockExtractor(result: .failure(.unsupported)), dir: tempDir())
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.canRetry == false)
    }

    @Test func rejectsInvalidURL() async {
        let model = vm(extractor: MockExtractor(), dir: tempDir())
        model.urlText = "not a url"
        await model.startDownload()
        #expect(model.errorMessage != nil)
    }

    @Test func requiresAuthShowsSignInForHost() async {
        let model = vm(extractor: MockExtractor(result: .failure(.requiresAuth)), dir: tempDir())
        model.urlText = "https://www.instagram.com/reel/ABC/"
        await model.startDownload()
        #expect(model.requiresSignIn == true)
        // Sign-in targets the site origin root, not the deep reel link (which can redirect
        // to an app scheme and never set the site's guest cookies).
        #expect(model.signInURL?.absoluteString == "https://www.instagram.com/")
        #expect(model.errorMessage == KeraunosError.requiresAuth.errorDescription)
    }

    @Test func cancelStopsInFlightDownloadWithoutSurfacingAnError() async {
        let extractor = HangingExtractor()
        let spy = SpyEnqueuer()
        let model = vm(extractor: extractor, dir: tempDir(), enqueuer: spy)
        model.urlText = "https://x.test/post/1"
        model.start()

        // Block until resolve() is actually running, so the cancel is genuinely
        // in-flight rather than racing the task's start (deterministic, no sleeps).
        var resolving = extractor.resolving.makeAsyncIterator()
        _ = await resolving.next()
        #expect(model.isWorking == true)

        model.cancel()
        await model.currentTask?.value   // let the cancellation unwind

        #expect(model.isWorking == false)
        #expect(model.errorMessage == nil)   // a user-initiated cancel is not an error
        #expect(spy.enqueued.isEmpty)
    }

    @Test func multipleFormatsShowPickerAndDoNotDownloadYet() async {
        let options = [sampleOption,
            FormatOption(height: 360, codecLabel: "H.264", approxBytes: nil,
                         formatID: "18", isAdaptive: false)]
        let harness = DownloadViewModelHarness.choices(
            options, resolvingTo: .progressive(filename: "picked.mp4"))

        await harness.start("https://x.test/v")

        #expect(harness.model.pendingOptions?.count == 2)
        #expect(harness.enqueuedJobs.isEmpty)          // nothing enqueued yet
        #expect(harness.model.savedFiles.isEmpty)
    }

    @Test func selectFormatResolvesAndEnqueues() async {
        let harness = DownloadViewModelHarness.choices(
            [sampleOption], resolvingTo: .progressive(filename: "picked.mp4"))

        await harness.start("x.test/v")
        await harness.select(sampleOption)

        let expectedURL = URL(string: "https://x.test/v")!
        let resolutions = await harness.resolveCommands
        #expect(await harness.listedURLs == [expectedURL])
        #expect(resolutions.count == 1)
        #expect(resolutions.first?.url == expectedURL)
        #expect(resolutions.first?.option == sampleOption)
        #expect(harness.model.pendingOptions == nil)
        #expect(harness.enqueuedJob?.formatSelection.formatID == sampleOption.formatID)
    }

    @Test func cancelSelectionClearsPickerWithoutDownloading() async {
        let spy = SpyEnqueuer()
        let model = vm(extractor: choices([sampleOption]), dir: tempDir(), enqueuer: spy)
        model.urlText = "https://x.test/v"
        await model.startDownload()
        model.cancelSelection()
        #expect(model.pendingOptions == nil)
        #expect(spy.enqueued.isEmpty)
    }

    @Test func listFormatsErrorMapsLikeResolveError() async {
        var mock = MockExtractor()
        mock.listing = .failure(.requiresAuth)
        let model = vm(extractor: mock, dir: tempDir())
        model.urlText = "https://x.test/v"
        await model.startDownload()
        #expect(model.requiresSignIn)                        // same routing as a resolve failure
        #expect(model.pendingOptions == nil)
    }

    @Test func bestOptionPrefersHighestMuxedOverAdaptive() {
        let options = [
            FormatOption(height: 2160, codecLabel: "HEVC", approxBytes: nil, formatID: "a", isAdaptive: true),
            FormatOption(height: 1080, codecLabel: "H.264", approxBytes: nil, formatID: "b", isAdaptive: false),
            FormatOption(height: 720, codecLabel: "H.264", approxBytes: nil, formatID: "c", isAdaptive: false),
        ]
        // A 2160p adaptive stream needs a separate audio track + merge, so the highest
        // already-muxed stream (1080p) is preferred for a no-question download.
        #expect(DownloadViewModel.bestOption(options)?.formatID == "b")
    }

    @Test func highestQualityPreferenceSkipsPickerAndEnqueuesBest() async {
        let options = [
            FormatOption(height: 360, codecLabel: "H.264", approxBytes: nil, formatID: "18", isAdaptive: false),
            FormatOption(height: 1080, codecLabel: "H.264", approxBytes: nil, formatID: "137", isAdaptive: false),
        ]
        let harness = DownloadViewModelHarness.choices(
            options,
            resolvingTo: .progressive(filename: "picked.mp4"),
            quality: .highest)

        await harness.start("x.test/v")

        let expectedURL = URL(string: "https://x.test/v")!
        let resolutions = await harness.resolveCommands
        #expect(await harness.listedURLs == [expectedURL])
        #expect(resolutions.count == 1)
        #expect(resolutions.first?.url == expectedURL)
        #expect(resolutions.first?.option == options[1])
        #expect(harness.model.pendingOptions == nil)      // picker skipped entirely
        #expect(harness.enqueuedJobs.count == 1)          // resolved and enqueued without asking
        #expect(harness.enqueuedJob?.formatSelection.formatID == "137")
    }

    @Test func autoSaveToPhotosPreferencePersistsOnEnqueuedJob() async {
        // The VM no longer performs the Photos save itself (that moved to the engine's
        // finalize pass) — it only needs to carry the preference onto the job.
        let saver = MockPhotoSaver(result: .saved)
        let harness = DownloadViewModelHarness.ready(
            .progressive(filename: "clip.mp4"),
            autoSaveToPhotos: true,
            photoSaver: saver)

        await harness.start("https://x.test/v")

        #expect(harness.enqueuedJobs.count == 1)
        #expect(harness.enqueuedJob?.autoSaveToPhotos == true)
        #expect(saver.savedURLs.isEmpty)                  // not called from the VM anymore
    }

    @Test func retryAfterLoginSucceedsAndClearsSignIn() async {
        let harness = DownloadViewModelHarness(listings: [
            .failure(.requiresAuth),
            .success(.ready(.progressive(filename: "clip.mp4"))),
        ])

        await harness.start("https://www.instagram.com/reel/ABC/")
        #expect(harness.model.requiresSignIn == true)
        await harness.model.retry()

        #expect(harness.model.requiresSignIn == false)
        #expect(harness.enqueuedJobs.count == 1)
        #expect(harness.model.errorMessage == nil)
    }
}

/// Returns a queued sequence of results across successive phase-1 calls.
final class SequenceExtractor: MediaExtracting, @unchecked Sendable {
    private var results: [Result<ResolvedMedia, KeraunosError>]
    init(results: [Result<ResolvedMedia, KeraunosError>]) { self.results = results }
    private func next() throws -> ResolvedMedia {
        try (results.isEmpty ? .failure(.runtime(detail: "no more results")) : results.removeFirst()).get()
    }
    func listFormats(_ url: URL) async throws -> FormatListing { .ready(try next()) }
    func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia { try next() }
}

/// Suspends inside phase 1 until cancelled, signalling when it has actually entered so a
/// test can cancel a genuinely in-flight download.
final class HangingExtractor: MediaExtracting, @unchecked Sendable {
    let resolving: AsyncStream<Void>
    private let entered: AsyncStream<Void>.Continuation
    init() {
        var continuation: AsyncStream<Void>.Continuation!
        resolving = AsyncStream { continuation = $0 }
        entered = continuation
    }
    func listFormats(_ url: URL) async throws -> FormatListing {
        entered.yield(())
        try await Task.sleep(for: .seconds(60))
        throw KeraunosError.runtime(detail: "should have been cancelled")
    }
    func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia {
        entered.yield(())
        try await Task.sleep(for: .seconds(60))
        throw KeraunosError.runtime(detail: "should have been cancelled")
    }
}

/// Records jobs handed to `enqueue`, standing in for `TransferEngine` so tests can assert
/// what would have been enqueued without touching the filesystem/URLSession-backed singleton.
final class SpyEnqueuer: JobEnqueuing {
    private(set) var enqueued: [TransferJob] = []
    func enqueue(_ job: TransferJob) async { enqueued.append(job) }
}
