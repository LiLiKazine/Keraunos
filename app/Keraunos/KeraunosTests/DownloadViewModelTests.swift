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
        ResolvedMedia(kind: .progressive(MediaTrack(url: URL(string: "https://x.test/v.mp4")!,
                      httpHeaders: [:], codec: "avc1", fileExtension: "mp4")),
                      title: "t", suggestedFilename: name)
    }
    private func vm(extractor: any MediaExtracting, merger: MediaMerging, dir: URL) -> DownloadViewModel {
        DownloadViewModel(extractor: extractor,
                          assembler: MediaAssembler(downloader: SpyDownloader(), merger: merger),
                          store: DownloadStore(directory: dir))
    }
    private func choices(_ options: [FormatOption]) -> MockExtractor {
        var m = MockExtractor(result: .success(progressive("picked.mp4")))
        m.listing = .success(.choices(options))
        return m
    }
    private var sampleOption: FormatOption {
        FormatOption(height: 720, codecLabel: "H.264", approxBytes: nil,
                     formatID: "22", isAdaptive: false)
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
                          assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
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

    @Test func successfulProgressiveDownloadAddsFile() async {
        let dir = tempDir()
        let model = vm(extractor: MockExtractor(result: .success(progressive("clip.mp4"))),
                       merger: MockMerger(), dir: dir)
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == nil)
        #expect(model.lastSavedName == "clip.mp4")
        #expect(model.isWorking == false)
    }

    @Test func mergeFailureShowsMessage() async {
        let merger = MockMerger(); merger.shouldFail = true
        let media = ResolvedMedia(kind: .adaptive(
            video: MediaTrack(url: URL(string: "https://x.test/v.m4v")!, httpHeaders: [:], codec: "hvc1", fileExtension: "mp4"),
            audio: MediaTrack(url: URL(string: "https://x.test/a.m4a")!, httpHeaders: [:], codec: "mp4a", fileExtension: "m4a")),
            title: "t", suggestedFilename: "clip.mp4")
        let model = vm(extractor: MockExtractor(result: .success(media)), merger: merger, dir: tempDir())
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == KeraunosError.mergeFailed.errorDescription)
        #expect(model.isWorking == false)
    }

    @Test func extractionErrorShowsMessage() async {
        let model = vm(extractor: MockExtractor(result: .failure(.needsFfmpeg)), merger: MockMerger(), dir: tempDir())
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == KeraunosError.needsFfmpeg.errorDescription)
    }

    @Test func openIncomingDeepLinkFillsFieldAndDownloads() async {
        let model = vm(extractor: MockExtractor(result: .success(progressive("clip.mp4"))),
                       merger: MockMerger(), dir: tempDir())
        model.openIncoming(URL(string: "keraunos://download?url=https://x.test/v")!)
        await model.currentTask?.value
        #expect(model.urlText == "https://x.test/v")
        #expect(model.lastSavedName == "clip.mp4")
    }

    @Test func openIncomingIgnoresUnsupportedURL() async {
        let model = vm(extractor: MockExtractor(), merger: MockMerger(), dir: tempDir())
        model.openIncoming(URL(string: "ftp://x.test/v")!)
        #expect(model.urlText == "")          // untouched
        #expect(model.currentTask == nil)     // no download started
    }

    @Test(arguments: [KeraunosError.extractNetwork, .timedOut, .downloadNetwork])
    func autoRetriesOnceOnTransientColdStart(_ first: KeraunosError) async {
        // Transient transport faults — a YouTube cold-start surfacing as extract_network
        // or a watchdog timeout (the EJS-in-JSC solve is heavy on the first run), or a
        // mid-transfer download blip — clear on a warm retry, which succeeds.
        let extractor = SequenceExtractor(results: [
            .failure(first),
            .success(progressive("clip.mp4")),
        ])
        let model = DownloadViewModel(
            extractor: extractor,
            assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
            store: DownloadStore(directory: tempDir()))
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.lastSavedName == "clip.mp4")   // succeeded on the auto-retry
        #expect(model.errorMessage == nil)            // the transient blip was never surfaced
    }

    @Test func doesNotAutoRetryTerminalErrors() async {
        // A second attempt won't help unsupported, so it must surface immediately.
        let extractor = SequenceExtractor(results: [
            .failure(.unsupported),
            .success(progressive("clip.mp4")),   // would be consumed only if it wrongly retried
        ])
        let model = DownloadViewModel(
            extractor: extractor,
            assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
            store: DownloadStore(directory: tempDir()))
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == KeraunosError.unsupported.errorDescription)
        #expect(model.lastSavedName == nil)
    }

    @Test func doesNotAutoRetryRateLimited() async {
        // A rate-limit means "wait" — re-hammering immediately is exactly wrong, so it
        // must surface at once. The queued success is left UNCONSUMED, proving no auto-
        // retry fired; manual retry is still offered.
        let extractor = SequenceExtractor(results: [
            .failure(.rateLimited),
            .success(progressive("clip.mp4")),
        ])
        let model = DownloadViewModel(
            extractor: extractor,
            assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
            store: DownloadStore(directory: tempDir()))
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == KeraunosError.rateLimited.errorDescription)
        #expect(model.lastSavedName == nil)   // success not consumed → no auto-retry
        #expect(model.canRetry == true)
    }

    @Test func transientFailureOffersRetryButNotSignIn() async {
        let model = vm(extractor: MockExtractor(result: .failure(.downloadNetwork)),
                       merger: MockMerger(), dir: tempDir())
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.canRetry == true)
        #expect(model.requiresSignIn == false)
    }

    @Test func terminalFailureDoesNotOfferRetry() async {
        let model = vm(extractor: MockExtractor(result: .failure(.unsupported)),
                       merger: MockMerger(), dir: tempDir())
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.canRetry == false)
    }

    @Test func rejectsInvalidURL() async {
        let model = vm(extractor: MockExtractor(), merger: MockMerger(), dir: tempDir())
        model.urlText = "not a url"
        await model.startDownload()
        #expect(model.errorMessage != nil)
    }

    @Test func requiresAuthShowsSignInForHost() async {
        let model = vm(extractor: MockExtractor(result: .failure(.requiresAuth)),
                       merger: MockMerger(), dir: tempDir())
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
        let model = vm(extractor: extractor, merger: MockMerger(), dir: tempDir())
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
        #expect(model.lastSavedName == nil)
    }

    @Test func multipleFormatsShowPickerAndDoNotDownloadYet() async {
        let dir = tempDir()
        let model = vm(extractor: choices([sampleOption,
            FormatOption(height: 360, codecLabel: "H.264", approxBytes: nil,
                         formatID: "18", isAdaptive: false)]),
                       merger: MockMerger(), dir: dir)
        model.urlText = "https://x.test/v"
        await model.startDownload()
        #expect(model.pendingOptions?.count == 2)
        #expect(model.lastSavedName == nil)                 // nothing downloaded yet
        #expect(model.savedFiles.isEmpty)
    }

    @Test func selectFormatResolvesAndSaves() async {
        let dir = tempDir()
        let model = vm(extractor: choices([sampleOption]), merger: MockMerger(), dir: dir)
        model.urlText = "https://x.test/v"
        await model.startDownload()
        model.selectFormat(sampleOption)
        await model.currentTask?.value
        #expect(model.pendingOptions == nil)
        #expect(model.lastSavedName == "picked.mp4")
    }

    @Test func cancelSelectionClearsPickerWithoutDownloading() async {
        let model = vm(extractor: choices([sampleOption]), merger: MockMerger(), dir: tempDir())
        model.urlText = "https://x.test/v"
        await model.startDownload()
        model.cancelSelection()
        #expect(model.pendingOptions == nil)
        #expect(model.lastSavedName == nil)
    }

    @Test func listFormatsErrorMapsLikeResolveError() async {
        var mock = MockExtractor()
        mock.listing = .failure(.requiresAuth)
        let model = vm(extractor: mock, merger: MockMerger(), dir: tempDir())
        model.urlText = "https://x.test/v"
        await model.startDownload()
        #expect(model.requiresSignIn)                        // same routing as a resolve failure
        #expect(model.pendingOptions == nil)
    }

    private func prefs(quality: DefaultQuality = .ask, autoSave: Bool = false) -> Preferences {
        let p = Preferences(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        p.defaultQuality = quality
        p.autoSaveToPhotos = autoSave
        return p
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

    @Test func highestQualityPreferenceSkipsPickerAndDownloadsBest() async {
        let dir = tempDir()
        let options = [
            FormatOption(height: 360, codecLabel: "H.264", approxBytes: nil, formatID: "18", isAdaptive: false),
            FormatOption(height: 1080, codecLabel: "H.264", approxBytes: nil, formatID: "137", isAdaptive: false),
        ]
        let model = DownloadViewModel(
            extractor: choices(options),
            assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
            store: DownloadStore(directory: dir),
            preferences: prefs(quality: .highest))
        model.urlText = "https://x.test/v"
        await model.startDownload()
        #expect(model.pendingOptions == nil)              // picker skipped entirely
        #expect(model.lastSavedName == "picked.mp4")      // resolved and saved without asking
    }

    @Test func autoSaveToPhotosSavesAfterCompatibleDownload() async {
        let saver = MockPhotoSaver(result: .saved)
        let model = DownloadViewModel(
            extractor: MockExtractor(result: .success(progressive("clip.mp4"))),
            assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
            store: DownloadStore(directory: tempDir()),
            photoSaver: saver,
            preferences: prefs(autoSave: true))
        model.urlText = "https://x.test/v"
        await model.startDownload()
        #expect(model.lastSavedName == "clip.mp4")
        #expect(saver.savedURLs.count == 1)               // auto-saved without a manual tap
        #expect(model.saveMessage == "Saved to Photos.")
    }

    @Test func retryAfterLoginSucceedsAndClearsSignIn() async {
        let dir = tempDir()
        let extractor = SequenceExtractor(results: [
            .failure(.requiresAuth),
            .success(progressive("clip.mp4")),
        ])
        let model = DownloadViewModel(
            extractor: extractor,
            assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
            store: DownloadStore(directory: dir))
        model.urlText = "https://www.instagram.com/reel/ABC/"
        await model.startDownload()
        #expect(model.requiresSignIn == true)
        await model.retry()
        #expect(model.requiresSignIn == false)
        #expect(model.lastSavedName == "clip.mp4")
        #expect(model.errorMessage == nil)
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

/// Writes a marker to the destination so progressive assembly produces a file.
struct SpyDownloader: FileDownloading {
    func download(_ track: MediaTrack, to destination: URL,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws {
        try Data("x".utf8).write(to: destination)
    }
}
