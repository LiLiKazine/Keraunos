import Testing
import Foundation
import KeraunosCore

@Suite(.serialized)   // mutates the shared StubURLProtocol.handler; tests run in parallel by default
struct DownloaderTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savesFileToDestinationWithSuggestedName() async throws {
        let payload = Data("fake mp4 bytes".utf8)
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        let dir = tempDir()
        let saved = try await Downloader(session: StubURLProtocol.session()).download(media, to: dir)

        #expect(saved.lastPathComponent == "clip.mp4")
        #expect(try Data(contentsOf: saved) == payload)
    }

    @Test func mapsHTTPErrorToNetwork() async throws {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        await #expect(throws: KeraunosError.network) {
            try await Downloader(session: StubURLProtocol.session()).download(media, to: tempDir())
        }
    }

    @Test func mapsCancellationToCancelled() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        await #expect(throws: KeraunosError.cancelled) {
            try await Downloader(session: StubURLProtocol.session()).download(media, to: tempDir())
        }
    }
}
