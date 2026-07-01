import SwiftUI
import WebKit

/// A `WKWebView` on the shared cookie store, presented as a sheet so the user can
/// log into a site. Cookies the site sets land in `dataStore`, which CookieStore
/// later exports. Done/Cancel are owned by the presenting sheet's toolbar.
///
/// A navigation delegate surfaces load failures through `status`; without it a failed
/// load just shows a blank white page with no clue why.
struct LoginWebView: UIViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore
    @Binding var status: LoadStatus

    /// A Safari User-Agent. WKWebView's default UA omits the `Version/…`/`Safari/…`
    /// tokens, and some sites bounce non-Safari agents: x.com 302-redirects them to the
    /// private `x-safari-https://` scheme ("eject to Safari"), which WKWebView can't load
    /// — the main frame is interrupted (WebKitErrorFrameLoadInterruptedByPolicyChange,
    /// 102) and the page is blank. Presenting as Safari makes x.com serve normal HTML so
    /// the user can actually sign in. The exact version is cosmetic; the `Safari` token
    /// is what matters.
    static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"

    /// Lifecycle of the page load, surfaced to the UI so a failure isn't silent.
    enum LoadStatus: Equatable {
        case loading
        case finished
        /// A main-frame navigation error or an HTTP >= 400 response.
        case failed(String)
    }

    /// The failure reason to surface for a navigation error, or nil to ignore it. We only
    /// blank the WebView for a genuine failure on the *initial* load (otherwise a mystery
    /// blank page). Ignored cases:
    /// - a page has already committed (`hasCommittedAPage`): a later failed navigation just
    ///   leaves the user on the current page — don't cover a usable view;
    /// - `NSURLErrorCancelled` (-999): a superseded / redirected load;
    /// - WebKit `102` (FrameLoadInterruptedByPolicyChange): a normal redirect or
    ///   custom-scheme hop (e.g. v.douyin.com bouncing to a deep link), not a real failure.
    static func failureReason(for error: NSError, hasCommittedAPage: Bool) -> String? {
        if hasCommittedAPage { return nil }
        if error.code == NSURLErrorCancelled { return nil }
        if error.domain == "WebKitErrorDomain" && error.code == 102 { return nil }
        return "\(error.localizedDescription) (\(error.domain) \(error.code))"
    }

    func makeCoordinator() -> Coordinator { Coordinator(status: $status) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let status: Binding<LoadStatus>
        /// True once any navigation has committed a page. After that, transient errors
        /// (redirects, policy interruptions, mid-flow 4xx) must not blank a usable view.
        private var hasCommittedAPage = false

        init(status: Binding<LoadStatus>) { self.status = status }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            status.wrappedValue = .loading
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            hasCommittedAPage = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            hasCommittedAPage = true
            status.wrappedValue = .finished
        }

        // A reachable-but-error status (e.g. 403/404) on the main frame — but only worth
        // surfacing while the FIRST page is still loading. Once a page is up, sites
        // legitimately return non-2xx main-frame responses mid-flow.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if !hasCommittedAPage,
               let http = navigationResponse.response as? HTTPURLResponse,
               http.statusCode >= 400, navigationResponse.isForMainFrame {
                status.wrappedValue = .failed("Site returned HTTP \(http.statusCode).")
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            record(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            record(error)
        }

        private func record(_ error: Error) {
            if let reason = LoginWebView.failureReason(for: error as NSError,
                                                       hasCommittedAPage: hasCommittedAPage) {
                status.wrappedValue = .failed(reason)
            }
        }
    }
}
