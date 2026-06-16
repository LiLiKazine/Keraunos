import SwiftUI
import WebKit

/// A `WKWebView` on the shared cookie store, presented as a sheet so the user can
/// log into a site. Cookies the site sets land in `dataStore`, which CookieStore
/// later exports. Done/Cancel are owned by the presenting sheet's toolbar.
struct LoginWebView: UIViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
