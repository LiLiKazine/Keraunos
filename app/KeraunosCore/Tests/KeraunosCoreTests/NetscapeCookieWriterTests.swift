import Testing
import Foundation
import KeraunosCore

struct NetscapeCookieWriterTests {
    private func cookie(_ name: String, _ value: String, domain: String,
                        path: String = "/", secure: Bool = false,
                        expires: Date? = nil, includeSubdomains: Bool = false) -> Cookie {
        Cookie(name: name, value: value, domain: domain, path: path,
               isSecure: secure, expires: expires, includeSubdomains: includeSubdomains)
    }

    @Test func startsWithNetscapeHeader() {
        let out = NetscapeCookieWriter.write([cookie("a", "b", domain: "x.test")])
        #expect(out.hasPrefix("# Netscape HTTP Cookie File\n"))
    }

    @Test func writesSevenTabSeparatedFields() {
        let out = NetscapeCookieWriter.write([
            cookie("sessionid", "abc", domain: "x.test", path: "/", secure: true,
                   expires: Date(timeIntervalSince1970: 1_900_000_000), includeSubdomains: false)
        ])
        let line = out.split(separator: "\n").last.map(String.init) ?? ""
        let fields = line.components(separatedBy: "\t")
        #expect(fields.count == 7)
        #expect(fields == ["x.test", "FALSE", "/", "TRUE", "1900000000", "sessionid", "abc"])
    }

    @Test func includeSubdomainsFlagAndSecureFlag() {
        let out = NetscapeCookieWriter.write([
            cookie("k", "v", domain: ".x.test", secure: false, includeSubdomains: true)
        ])
        let fields = (out.split(separator: "\n").last.map(String.init) ?? "").components(separatedBy: "\t")
        #expect(fields[0] == ".x.test")
        #expect(fields[1] == "TRUE")    // includeSubdomains
        #expect(fields[3] == "FALSE")   // not secure
    }

    @Test func sessionCookieHasZeroExpiry() {
        let out = NetscapeCookieWriter.write([cookie("k", "v", domain: "x.test", expires: nil)])
        let fields = (out.split(separator: "\n").last.map(String.init) ?? "").components(separatedBy: "\t")
        #expect(fields[4] == "0")
    }

    @Test func preservesOrderOfMultipleCookies() {
        let out = NetscapeCookieWriter.write([
            cookie("first", "1", domain: "x.test"),
            cookie("second", "2", domain: "y.test"),
        ])
        let lines = out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        #expect(lines.count == 2)
        #expect(lines[0].contains("first"))
        #expect(lines[1].contains("second"))
    }
}
