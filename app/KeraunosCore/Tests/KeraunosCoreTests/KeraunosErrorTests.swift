import Testing
import Foundation
import KeraunosCore

struct KeraunosErrorTests {
    @Test func mapsKnownErrorKinds() {
        #expect(KeraunosError(errorKind: "unsupported") == .unsupported)
        #expect(KeraunosError(errorKind: "needs_ffmpeg") == .needsFfmpeg)
        #expect(KeraunosError(errorKind: "requires_auth") == .requiresAuth)
        #expect(KeraunosError(errorKind: "extract_network") == .extractNetwork)
        #expect(KeraunosError(errorKind: "download_network") == .downloadNetwork)
        #expect(KeraunosError(errorKind: "timeout") == .timedOut)
    }

    @Test func mapsLegacyNetworkKindToExtractNetwork() {
        // Extraction is the only Python-side source of a bare "network" kind, so an
        // un-split legacy value resolves to the extraction half rather than runtime.
        #expect(KeraunosError(errorKind: "network") == .extractNetwork)
    }

    @Test func mapsUnknownKindToRuntimeWithDetail() {
        #expect(KeraunosError(errorKind: "weird", detail: "boom") == .runtime(detail: "boom"))
    }

    @Test func everyCaseHasAUserMessage() {
        let cases: [KeraunosError] = [.unsupported, .needsFfmpeg, .requiresAuth, .extractNetwork, .downloadNetwork, .runtime(detail: "x"), .cancelled, .mergeFailed, .timedOut]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func mergeFailedHasAMessage() {
        #expect(KeraunosError.mergeFailed.errorDescription?.isEmpty == false)
        #expect(KeraunosError.mergeFailed.errorDescription == "Couldn't combine the video and audio tracks.")
    }
}
