import Testing
import Foundation
import KeraunosCore

extension StubNetworkSuite {
struct MediaAssemblerTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func track(_ s: String, _ ext: String) -> MediaTrack {
        MediaTrack(url: URL(string: s)!, httpHeaders: [:], codec: "c", fileExtension: ext)
    }
    private func bytesHandler() {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(req.url!.lastPathComponent.utf8))
        }
    }

    @Test func progressiveDownloadsOneFileAndSkipsMerge() async throws {
        bytesHandler()
        let store = DownloadStore(directory: tempDir())
        let merger = MockMerger()
        let media = ResolvedMedia(kind: .progressive(track("https://x.test/v.mp4", "mp4")),
                                  title: "t", suggestedFilename: "clip.mp4")
        let saved = try await MediaAssembler(downloader: Downloader(session: StubURLProtocol.session()),
                                             merger: merger).assemble(media, into: store)
        #expect(saved.lastPathComponent == "clip.mp4")
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(merger.received == nil)               // progressive never merges
    }

    @Test func adaptiveDownloadsBothThenMerges() async throws {
        bytesHandler()
        let store = DownloadStore(directory: tempDir())
        let merger = MockMerger()
        let media = ResolvedMedia(kind: .adaptive(video: track("https://x.test/v.m4v", "mp4"),
                                                  audio: track("https://x.test/a.m4a", "m4a")),
                                  title: "t", suggestedFilename: "clip.webm")
        let saved = try await MediaAssembler(downloader: Downloader(session: StubURLProtocol.session()),
                                             merger: merger).assemble(media, into: store)
        #expect(saved.lastPathComponent == "clip.mp4")          // forced to .mp4
        #expect(merger.received?.output == saved)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        // temp video/audio inputs were cleaned up
        #expect(!FileManager.default.fileExists(atPath: merger.received!.video.path))
        #expect(!FileManager.default.fileExists(atPath: merger.received!.audio.path))
    }

    @Test func cleansUpTempWhenMergeFails() async throws {
        bytesHandler()
        let store = DownloadStore(directory: tempDir())
        let merger = MockMerger(); merger.shouldFail = true
        let media = ResolvedMedia(kind: .adaptive(video: track("https://x.test/v.m4v", "mp4"),
                                                  audio: track("https://x.test/a.m4a", "m4a")),
                                  title: "t", suggestedFilename: "clip.mp4")
        await #expect(throws: KeraunosError.mergeFailed) {
            try await MediaAssembler(downloader: Downloader(session: StubURLProtocol.session()),
                                     merger: merger).assemble(media, into: store)
        }
        #expect(!FileManager.default.fileExists(atPath: merger.received!.video.path))
        #expect(!FileManager.default.fileExists(atPath: merger.received!.audio.path))
        #expect(store.savedFiles().isEmpty)             // no half-file in Documents
    }
}
}
