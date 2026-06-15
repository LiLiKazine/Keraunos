import Testing
import Foundation
import KeraunosCore

struct KeraunosErrorTests {
    @Test func mapsKnownErrorKinds() {
        #expect(KeraunosError(errorKind: "unsupported") == .unsupported)
        #expect(KeraunosError(errorKind: "needs_ffmpeg") == .needsFfmpeg)
        #expect(KeraunosError(errorKind: "requires_auth") == .requiresAuth)
        #expect(KeraunosError(errorKind: "network") == .network)
    }

    @Test func mapsUnknownKindToRuntimeWithDetail() {
        #expect(KeraunosError(errorKind: "weird", detail: "boom") == .runtime(detail: "boom"))
    }

    @Test func everyCaseHasAUserMessage() {
        let cases: [KeraunosError] = [.unsupported, .needsFfmpeg, .requiresAuth, .network, .runtime(detail: "x"), .cancelled]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
