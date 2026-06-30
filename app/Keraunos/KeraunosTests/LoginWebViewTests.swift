import Testing
@testable import Keraunos

struct LoginWebViewTests {
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
