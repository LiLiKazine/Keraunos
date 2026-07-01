import Testing
import Foundation
import KeraunosCore

struct MockExtractorTests {
    private let media = ResolvedMedia(
        kind: .progressive(MediaTrack(url: URL(string: "https://x.test/v.mp4")!,
                                      httpHeaders: [:], codec: "avc1", fileExtension: "mp4")),
        title: "t", suggestedFilename: "v.mp4")

    @Test func listFormatsDefaultsToReadyFromResult() async throws {
        let mock = MockExtractor(result: .success(media))
        guard case let .ready(m) = try await mock.listFormats(URL(string: "https://x.test")!) else {
            Issue.record("expected ready"); return
        }
        #expect(m == media)
    }

    @Test func listFormatsUsesExplicitListingOverride() async throws {
        let option = FormatOption(height: 720, codecLabel: "H.264", approxBytes: nil,
                                  formatID: "22", isAdaptive: false)
        var mock = MockExtractor(result: .success(media))
        mock.listing = .success(.choices([option]))
        guard case let .choices(opts) = try await mock.listFormats(URL(string: "https://x.test")!) else {
            Issue.record("expected choices"); return
        }
        #expect(opts == [option])
    }

    @Test func resolveWithOptionReturnsResult() async throws {
        let mock = MockExtractor(result: .success(media))
        let m = try await mock.resolve(URL(string: "https://x.test")!, option: nil)
        #expect(m == media)
    }
}
