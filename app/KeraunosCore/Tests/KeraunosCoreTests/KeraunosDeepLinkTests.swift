import Testing
import Foundation
import KeraunosCore

struct KeraunosDeepLinkTests {
    // The contract that makes the Share Extension correct: anything the builder produces,
    // IncomingURL must recover unchanged. If this breaks, shared links download the wrong
    // thing (or nothing) with no other signal.
    @Test(arguments: [
        "https://youtu.be/abc",
        "https://youtube.com/watch?v=abc&t=30s",          // & must survive — the classic trap
        "https://x.com/u/status/1?s=20&utm=foo%20bar",     // pre-existing %-encoding + spaces
        "https://www.bilibili.com/video/BV1?p=2&spm=a.b",
    ])
    func builtDeepLinkRoundTripsThroughIncomingURL(_ media: String) {
        let deep = KeraunosDeepLink.url(forMediaURL: media)
        #expect(deep != nil)
        #expect(IncomingURL.target(from: deep!)?.absoluteString == media)
    }

    @Test func builderPercentEncodesReservedCharacters() {
        // The reserved chars that would break query parsing must be escaped in the output.
        let deep = KeraunosDeepLink.url(forMediaURL: "https://h.test/p?a=1&b=2")!
        let s = deep.absoluteString
        #expect(s.hasPrefix("keraunos://download?url="))
        #expect(!s.contains("&b=2"))        // the inner & is encoded, not a second param
        #expect(s.contains("%3F"))          // ? encoded
        #expect(s.contains("%26"))          // & encoded
        #expect(s.contains("%3D"))          // = encoded
    }

    @Test func parserRejectsForeignSchemes() {
        #expect(KeraunosDeepLink.mediaURL(from: URL(string: "https://h.test/v")!) == nil)
        #expect(KeraunosDeepLink.mediaURL(from: URL(string: "keraunos://download")!) == nil)
    }
}
