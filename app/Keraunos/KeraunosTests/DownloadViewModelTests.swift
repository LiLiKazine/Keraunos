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

    @Test func successfulDownloadAddsFileAndClearsError() async {
        let dir = tempDir()
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        let vm = DownloadViewModel(
            extractor: MockExtractor(result: .success(media)),
            downloader: SpyDownloader(behavior: .succeed(dir.appendingPathComponent("clip.mp4"))),
            store: DownloadStore(directory: dir))
        vm.urlText = "https://x.test/post/1"

        await vm.startDownload()

        #expect(vm.errorMessage == nil)
        #expect(vm.lastSavedName == "clip.mp4")
        #expect(vm.isWorking == false)
    }

    @Test func extractionErrorShowsMessage() async {
        let vm = DownloadViewModel(
            extractor: MockExtractor(result: .failure(.needsFfmpeg)),
            downloader: SpyDownloader(behavior: .succeed(URL(fileURLWithPath: "/x"))),
            store: DownloadStore(directory: tempDir()))
        vm.urlText = "https://x.test/post/1"

        await vm.startDownload()

        #expect(vm.errorMessage == KeraunosError.needsFfmpeg.errorDescription)
        #expect(vm.isWorking == false)
    }

    @Test func rejectsInvalidURL() async {
        let vm = DownloadViewModel(
            extractor: MockExtractor(),
            downloader: SpyDownloader(behavior: .succeed(URL(fileURLWithPath: "/x"))),
            store: DownloadStore(directory: tempDir()))
        vm.urlText = "not a url"

        await vm.startDownload()

        #expect(vm.errorMessage != nil)
    }
}

/// Minimal downloader double for view-model tests.
struct SpyDownloader: FileDownloading {
    enum Behavior: Sendable { case succeed(URL); case fail(KeraunosError) }
    let behavior: Behavior
    func download(_ media: ResolvedMedia, to destinationDirectory: URL) async throws -> URL {
        switch behavior {
        case .succeed(let url): return url
        case .fail(let error): throw error
        }
    }
}
