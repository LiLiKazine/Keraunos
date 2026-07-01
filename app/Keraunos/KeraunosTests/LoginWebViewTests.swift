import Testing
import Foundation
@testable import Keraunos

// LoginWebView (and its statics) are MainActor-isolated — the app target builds with
// -default-isolation=MainActor — so the test type is too, to reach them without warnings.
@MainActor
struct LoginWebViewTests {
    // The login WebView must not blank a working page on a non-fatal navigation error.
    // These pin the classifier that decides when to surface a blocking failure overlay.

    @Test func ignoresFrameLoadInterruptedByPolicyChange() {
        // WebKit 102 fires on a normal redirect / custom-scheme hop — e.g. v.douyin.com
        // bouncing toward a deep link. Surfacing it blanked a usable Douyin page.
        let e = NSError(domain: "WebKitErrorDomain", code: 102)
        #expect(LoginWebView.failureReason(for: e, hasCommittedAPage: false) == nil)
    }

    @Test func ignoresCancelledLoad() {
        let e = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        #expect(LoginWebView.failureReason(for: e, hasCommittedAPage: false) == nil)
    }

    @Test func ignoresAnyErrorOnceAPageHasLoaded() {
        // After a page is up, a later failed navigation leaves the user on it — don't blank.
        let e = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        #expect(LoginWebView.failureReason(for: e, hasCommittedAPage: true) == nil)
    }

    @Test func surfacesAGenuineInitialLoadFailure() {
        // A real failure on the first load (host not found / offline) leaves a blank page
        // and should be explained.
        let e = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let reason = LoginWebView.failureReason(for: e, hasCommittedAPage: false)
        #expect(reason != nil)
        #expect(reason?.contains("\(NSURLErrorCannotFindHost)") == true)
    }
    // x.com 302-redirects non-Safari user agents to the private, unloadable
    // `x-safari-https://` scheme, which breaks the embedded WebView (WebKitErrorDomain
    // 102, blank page). The login WebView must present a Safari UA so x.com serves real
    // HTML. Guards against the UA being dropped — which would silently resurrect the bug.
    @Test func loginWebViewUsesASafariUserAgent() {
        let ua = LoginWebView.safariUserAgent
        #expect(ua.contains("Safari/"))
        #expect(ua.contains("Mozilla/5.0"))
        #expect(ua.contains("Version/"))
    }
}
