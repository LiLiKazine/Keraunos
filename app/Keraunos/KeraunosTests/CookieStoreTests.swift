import Testing
import Foundation
import WebKit
import KeraunosCore
@testable import Keraunos

@MainActor
struct CookieStoreTests {
    private func freshStore() -> (CookieStore, WKWebsiteDataStore) {
        let data = WKWebsiteDataStore.nonPersistent()   // no UI, deterministic
        return (CookieStore(dataStore: data), data)
    }
    private func setCookie(_ store: WKWebsiteDataStore, name: String, domain: String) async {
        let c = HTTPCookie(properties: [
            .name: name, .value: "v", .domain: domain, .path: "/",
            .expires: Date(timeIntervalSinceNow: 3600),
        ])!
        await store.httpCookieStore.setCookie(c)
    }

    @Test func emptyStoreReturnsNilCookieFile() async {
        let (store, _) = freshStore()
        #expect(await store.cookieFile() == nil)
    }

    @Test func exportsCookiesToNetscapeFile() async throws {
        let (store, data) = freshStore()
        await setCookie(data, name: "sessionid", domain: "x.test")
        await setCookie(data, name: "token", domain: "y.test")
        let url = try #require(await store.cookieFile())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("# Netscape HTTP Cookie File"))
        #expect(text.contains("sessionid"))
        #expect(text.contains("token"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func signedInHostsAreDistinctAndDotStripped() async {
        let (store, data) = freshStore()
        await setCookie(data, name: "a", domain: "x.test")
        await setCookie(data, name: "b", domain: "x.test")
        let hosts = await store.signedInHosts()
        #expect(hosts == ["x.test"])
    }

    @Test func signOutRemovesOneHost() async {
        let (store, data) = freshStore()
        await setCookie(data, name: "a", domain: "x.test")
        await setCookie(data, name: "b", domain: "y.test")
        await store.signOut(host: "x.test")
        #expect(await store.signedInHosts() == ["y.test"])
    }

    @Test func signOutAllEmptiesTheStore() async {
        let (store, data) = freshStore()
        await setCookie(data, name: "a", domain: "x.test")
        await store.signOutAll()
        #expect(await store.signedInHosts().isEmpty)
        #expect(await store.cookieFile() == nil)
    }
}
