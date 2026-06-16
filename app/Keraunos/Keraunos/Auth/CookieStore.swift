import Foundation
import WebKit
import KeraunosCore

/// Owns the persistent cookie jar (a `WKWebsiteDataStore`, shared with the login
/// web view) and exports it to a short-lived, file-protected Netscape `cookies.txt`
/// for yt-dlp. `@MainActor` because WebKit's cookie store is main-actor-friendly.
@MainActor
final class CookieStore: CookieProviding {
    /// The store the login `WKWebView` must also use, so captured cookies are visible.
    let dataStore: WKWebsiteDataStore
    private let tempDir: URL

    init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keraunos-cookies", isDirectory: true)
        // Clear any cookie files orphaned by a prior crash.
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func cookieFile() async -> URL? {
        let httpCookies = await allCookies()
        guard !httpCookies.isEmpty else { return nil }
        let cookies = httpCookies.map(Self.map)
        let text = NetscapeCookieWriter.write(cookies)
        let file = tempDir.appendingPathComponent("\(UUID().uuidString).txt")
        do {
            try text.data(using: .utf8)?.write(to: file, options: .completeFileProtection)
            return file
        } catch {
            return nil   // fail open: behave as no cookies
        }
    }

    func signedInHosts() async -> [String] {
        let domains = await allCookies().map { $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain }
        return Array(Set(domains)).sorted()
    }

    func signOut(host: String) async {
        let store = dataStore.httpCookieStore
        for cookie in await allCookies() where Self.matches(cookie, host: host) {
            await store.deleteCookie(cookie)
        }
    }

    func signOutAll() async {
        await dataStore.removeData(ofTypes: [WKWebsiteDataTypeCookies],
                                   modifiedSince: Date(timeIntervalSince1970: 0))
    }

    private func allCookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
    }

    private static func matches(_ cookie: HTTPCookie, host: String) -> Bool {
        let d = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return d == host
    }

    private static func map(_ c: HTTPCookie) -> Cookie {
        Cookie(name: c.name, value: c.value, domain: c.domain,
               path: c.path.isEmpty ? "/" : c.path, isSecure: c.isSecure,
               expires: c.expiresDate, includeSubdomains: c.domain.hasPrefix("."))
    }
}
