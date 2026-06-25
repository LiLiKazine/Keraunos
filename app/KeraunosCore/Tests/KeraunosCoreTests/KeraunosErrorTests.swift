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

    @Test func mapsContentStateErrorKinds() {
        #expect(KeraunosError(errorKind: "unavailable") == .unavailable)
        #expect(KeraunosError(errorKind: "rate_limited") == .rateLimited)
        #expect(KeraunosError(errorKind: "restricted_or_empty") == .restrictedOrEmpty)
    }

    @Test func restrictedOrEmptyIsNotRetryableAndHasASignInMessage() {
        // Like requiresAuth, the recovery path is sign-in, not a plain retry — so it's
        // neither retryable nor auto-retryable, and the message points the owner at sign-in.
        #expect(KeraunosError.restrictedOrEmpty.isRetryable == false)
        #expect(KeraunosError.restrictedOrEmpty.isAutoRetryable == false)
        #expect(KeraunosError.restrictedOrEmpty.errorDescription?.contains("sign in") == true)
    }

    @Test func contentStateRetryability() {
        // A gone/private/geo-blocked video won't change on retry; a rate-limit can
        // succeed once the user waits (manual retry, never auto-hammered).
        #expect(KeraunosError.unavailable.isRetryable == false)
        #expect(KeraunosError.rateLimited.isRetryable == true)
    }

    @Test func everyCaseHasAUserMessage() {
        let cases: [KeraunosError] = [.unsupported, .needsFfmpeg, .requiresAuth, .extractNetwork, .downloadNetwork, .runtime(detail: "x"), .cancelled, .mergeFailed, .timedOut, .unavailable, .rateLimited, .restrictedOrEmpty]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }

    @Test func transientFailuresAreRetryable() {
        // Network blips, timeouts, and unknown runtime faults can succeed on a second try.
        for error in [KeraunosError.extractNetwork, .downloadNetwork, .timedOut, .runtime(detail: "x")] {
            #expect(error.isRetryable, "\(error) should be retryable")
        }
    }

    @Test func autoRetryableSetIsTheTransientTransportKinds() {
        // Only transient transport/cold-start faults a warm retry clears.
        for error in [KeraunosError.extractNetwork, .timedOut, .downloadNetwork] {
            #expect(error.isAutoRetryable, "\(error) should be auto-retryable")
        }
        for error in [KeraunosError.rateLimited, .runtime(detail: "x"), .unsupported,
                      .needsFfmpeg, .requiresAuth, .cancelled, .mergeFailed, .unavailable,
                      .restrictedOrEmpty] {
            #expect(!error.isAutoRetryable, "\(error) should not be auto-retryable")
        }
    }

    @Test func autoRetryableIsSubsetOfRetryable() {
        // Every auto-retryable kind is also manually retryable (the invariant).
        for error in [KeraunosError.extractNetwork, .timedOut, .downloadNetwork] {
            #expect(error.isRetryable, "\(error) auto-retryable kinds must also be retryable")
        }
        // ...but rateLimited/runtime are manually retryable WITHOUT being auto-retried.
        #expect(KeraunosError.rateLimited.isRetryable == true)
        #expect(KeraunosError.rateLimited.isAutoRetryable == false)
        #expect(KeraunosError.runtime(detail: "x").isRetryable == true)
        #expect(KeraunosError.runtime(detail: "x").isAutoRetryable == false)
    }

    @Test func deterministicAndUserDrivenFailuresAreNotRetryable() {
        // Re-running won't change an unsupported site, a missing-ffmpeg need, a failed
        // mux, a user cancel, or an auth wall (that one is handled by the sign-in flow).
        for error in [KeraunosError.unsupported, .needsFfmpeg, .mergeFailed, .cancelled, .requiresAuth, .restrictedOrEmpty] {
            #expect(!error.isRetryable, "\(error) should not be retryable")
        }
    }

    @Test func kindSlugRoundTripsWithErrorKindInit() {
        // The stable slug must match the Python error_kind vocabulary so a logged failure
        // reads the same as what the extractor emitted.
        for slug in ["unsupported", "needs_ffmpeg", "requires_auth",
                     "extract_network", "download_network", "timeout",
                     "unavailable", "rate_limited"] {
            #expect(KeraunosError(errorKind: slug).kind == slug)
        }
        #expect(KeraunosError.runtime(detail: "x").kind == "runtime")
        #expect(KeraunosError.cancelled.kind == "cancelled")
        #expect(KeraunosError.mergeFailed.kind == "merge_failed")
    }

    @Test func requiresAuthMessagePointsToSignInNotUnsupported() {
        // The LoginWebView -> CookieStore -> cookiefile flow is wired and functional, so
        // the message must direct the owner to sign in — not claim sign-in "isn't
        // supported yet" (the old, stale wording).
        let message = KeraunosError.requiresAuth.errorDescription?.lowercased()
        #expect(message?.contains("sign in") == true)
        #expect(message?.contains("isn't supported") == false)
    }

    @Test func mergeFailedHasAMessage() {
        #expect(KeraunosError.mergeFailed.errorDescription?.isEmpty == false)
        #expect(KeraunosError.mergeFailed.errorDescription == "Couldn't combine the video and audio tracks.")
    }
}
