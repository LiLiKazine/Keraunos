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
        #expect(model.signInURL?.host == "www.instagram.com")
        #expect(model.errorMessage == KeraunosError.requiresAuth.errorDescription)
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

/// Returns a queued sequence of results across successive resolve() calls.
final class SequenceExtractor: MediaExtracting, @unchecked Sendable {
    private var results: [Result<ResolvedMedia, KeraunosError>]
    init(results: [Result<ResolvedMedia, KeraunosError>]) { self.results = results }
    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try (results.isEmpty ? .failure(.runtime(detail: "no more results")) : results.removeFirst()).get()
    }
}

/// Writes a marker to the destination so progressive assembly produces a file.
struct SpyDownloader: FileDownloading {
    func download(_ track: MediaTrack, to destination: URL) async throws {
        try Data("x".utf8).write(to: destination)
    }
}
