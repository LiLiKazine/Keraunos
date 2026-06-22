import Testing
import Foundation
import KeraunosCore

struct IncomingURLTests {
    @Test func passesThroughADirectHTTPSLink() {
        let target = IncomingURL.target(from: URL(string: "https://youtu.be/abc?si=x")!)
        #expect(target?.absoluteString == "https://youtu.be/abc?si=x")
    }

    @Test func extractsTheTargetFromADeepLink() {
        // A share extension / Shortcut hands the video URL via keraunos://download?url=…
        let deep = URL(string: "keraunos://download?url=https://x.test/v%3Fa%3D1")!
        #expect(IncomingURL.target(from: deep)?.absoluteString == "https://x.test/v?a=1")
    }

    @Test func normalizesASchemeLessTargetInsideADeepLink() {
        let deep = URL(string: "keraunos://download?url=youtube.com/watch%3Fv%3Dabc")!
        #expect(IncomingURL.target(from: deep)?.absoluteString == "https://youtube.com/watch?v=abc")
    }

    @Test func rejectsUnsupportedSchemesAndMissingTarget() {
        #expect(IncomingURL.target(from: URL(string: "ftp://x.test/v")!) == nil)
        #expect(IncomingURL.target(from: URL(string: "keraunos://download")!) == nil)
        #expect(IncomingURL.target(from: URL(string: "keraunos://download?url=not%20a%20url")!) == nil)
    }
}
