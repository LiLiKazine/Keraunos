import Testing
import Foundation
import KeraunosCore

@Suite(.serialized)
struct DownloaderTests {
    private func tempFile(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    private func track(_ s: String = "https://x.test/v.mp4") -> MediaTrack {
        MediaTrack(url: URL(string: s)!, httpHeaders: [:], codec: "avc1", fileExtension: "mp4")
    }

    @Test func savesFileToDestination() async throws {
        let payload = Data("fake mp4 bytes".utf8)
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let dest = tempFile("clip.mp4")
        try await Downloader(session: StubURLProtocol.session()).download(track(), to: dest)
        #expect(try Data(contentsOf: dest) == payload)
    }

    @Test func mapsHTTPErrorToNetwork() async throws {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await #expect(throws: KeraunosError.network) {
            try await Downloader(session: StubURLProtocol.session()).download(track(), to: tempFile("clip.mp4"))
        }
    }

    @Test func mapsCancellationToCancelled() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await #expect(throws: KeraunosError.cancelled) {
            try await Downloader(session: StubURLProtocol.session()).download(track(), to: tempFile("clip.mp4"))
        }
    }
}
