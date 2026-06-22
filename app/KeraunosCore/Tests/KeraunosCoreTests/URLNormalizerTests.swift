import Testing
import Foundation
import KeraunosCore

struct URLNormalizerTests {
    @Test func keepsAValidHTTPSURL() {
        #expect(URLNormalizer.normalize("https://youtu.be/abc?si=x")?.absoluteString
                == "https://youtu.be/abc?si=x")
    }

    @Test func keepsAnExplicitHTTPURL() {
        // Don't silently upgrade an explicit http:// scheme.
        #expect(URLNormalizer.normalize("http://x.test/v.mp4")?.scheme == "http")
    }

    @Test func trimsSurroundingWhitespaceAndNewlines() {
        // Clipboard contents frequently carry a trailing newline or stray spaces.
        #expect(URLNormalizer.normalize("  https://x.com/v\n")?.absoluteString
                == "https://x.com/v")
    }

    @Test func prependsHTTPSWhenSchemeIsMissing() {
        #expect(URLNormalizer.normalize("youtube.com/watch?v=abc")?.absoluteString
                == "https://youtube.com/watch?v=abc")
        #expect(URLNormalizer.normalize("www.instagram.com/reel/xyz/")?.scheme == "https")
    }

    @Test func rejectsEmptyOrWhitespaceOnly() {
        #expect(URLNormalizer.normalize("") == nil)
        #expect(URLNormalizer.normalize("   \n ") == nil)
    }

    @Test func rejectsNonURLText() {
        // A bare word or free text has no dotted host and isn't a link.
        #expect(URLNormalizer.normalize("not a url") == nil)
        #expect(URLNormalizer.normalize("hello") == nil)
    }

    @Test func rejectsUnsupportedSchemes() {
        // Only http(s) reaches the downloader; reject anything else outright.
        #expect(URLNormalizer.normalize("ftp://x.com/v") == nil)
        #expect(URLNormalizer.normalize("javascript:alert(1)") == nil)
        #expect(URLNormalizer.normalize("file:///etc/passwd") == nil)
    }
}
