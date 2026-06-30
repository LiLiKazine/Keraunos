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

        init(status: Binding<LoadStatus>) { self.status = status }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            status.wrappedValue = .loading
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            status.wrappedValue = .finished
        }

        // Server reachable but returned an error status (e.g. 403/404) on the main frame.
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if let http = navigationResponse.response as? HTTPURLResponse,
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
            let ns = error as NSError
            // -999 (cancelled) is normal — a superseded/redirected load, not a failure.
            guard ns.code != NSURLErrorCancelled else { return }
            status.wrappedValue = .failed("\(ns.localizedDescription) (\(ns.domain) \(ns.code))")
        }
    }
}
