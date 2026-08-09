import Testing
import Foundation
import KeraunosCore
@testable import Keraunos

@MainActor
struct CookieStoreTests {
    @Test func emptyStoreReturnsNilCookieFile() async throws {
        let cookies = CookieStoreHarness()
        #expect(try await cookies.exportedText() == nil)
    }

    @Test func exportsCookiesToNetscapeFile() async throws {
        let cookies = CookieStoreHarness()
        await cookies.givenCookie("sessionid", domain: "x.test")
        await cookies.givenCookie("token", domain: "y.test")

        let text = try #require(try await cookies.exportedText())

        #expect(text.hasPrefix("# Netscape HTTP Cookie File"))
        #expect(text.contains("sessionid"))
        #expect(text.contains("token"))
    }

    @Test func signedInHostsAreDistinctAndDotStripped() async {
        let cookies = CookieStoreHarness()
        await cookies.givenCookie("a", domain: ".x.test")
        await cookies.givenCookie("b", domain: "x.test")

        #expect(await cookies.signedInHosts() == ["x.test"])
    }

    @Test func signOutRemovesOneHost() async {
        let cookies = CookieStoreHarness()
        await cookies.givenCookie("a", domain: "x.test")
        await cookies.givenCookie("b", domain: "y.test")

        await cookies.signOut(host: "x.test")

        #expect(await cookies.signedInHosts() == ["y.test"])
    }

    @Test func signOutAllEmptiesTheStore() async throws {
        let cookies = CookieStoreHarness()
        await cookies.givenCookie("a", domain: "x.test")

        await cookies.signOutAll()

        #expect(await cookies.signedInHosts().isEmpty)
        #expect(try await cookies.exportedText() == nil)
    }
}
