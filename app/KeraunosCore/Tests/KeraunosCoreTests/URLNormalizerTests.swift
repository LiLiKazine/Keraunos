import Testing
import Foundation
import KeraunosCore

struct URLNormalizerTests {
    @Test func originStripsAVideoLinkToTheSiteRoot() {
        // Sign-in should target the site root, not the deep/short link that redirects.
        #expect(URLNormalizer.origin(of: URL(string: "https://v.douyin.com/AbCdEf/?x=1")!)?
            .absoluteString == "https://v.douyin.com/")
        #expect(URLNormalizer.origin(of: URL(string: "https://www.instagram.com/reel/XYZ/")!)?
            .absoluteString == "https://www.instagram.com/")
    }

    @Test func originPreservesAnExplicitPort() {
        #expect(URLNormalizer.origin(of: URL(string: "http://localhost:8080/v/1")!)?
            .absoluteString == "http://localhost:8080/")
    }

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

    @Test func lowercasesScheme() {
        // RFC 3986 §3.1: scheme is case-insensitive; normalise to lowercase so that
        // downstream `url.scheme == "https"` comparisons are always stable.
        let url = URLNormalizer.normalize("HTTPS://youtube.com/v")
        #expect(url?.scheme == "https")
        #expect(url?.absoluteString.hasPrefix("https://") == true)
    }

    @Test func lowercasesHostButPreservesPathAndQueryCase() {
        // RFC 3986 §3.2.2: host is case-insensitive; path and query are not.
        let url = URLNormalizer.normalize("https://WWW.YouTube.com/Watch?V=AbC")
        #expect(url?.host == "www.youtube.com")
        #expect(url?.absoluteString.contains("/Watch") == true)
        #expect(url?.absoluteString.contains("V=AbC") == true)
    }

    // MARK: - Embedded URL extraction (share-blob paste)

    @Test func extractsURLFromDouyinShareBlob() {
        // Douyin's share button copies promo text with the link buried in it, and
        // even appends domain-shaped noise ("A@G.iP") that must NOT be mistaken for it.
        let blob = "2.02 复制打开抖音，看看【雉鸣minz的作品】凡凡 可爱美丽又迷人 # 萤火虫漫展 # 漫展养眼...https://v.douyin.com/9GUjWCxpa18/ 凡凡  可爱美丽又迷人 #萤火虫漫展 #漫展养眼造型大赏 #夜晚拍照才有感觉 #yi凡凡 - 抖音 A@G.iP NWz:/ :2pm 05/25"
        #expect(URLNormalizer.normalize(blob)?.absoluteString == "https://v.douyin.com/9GUjWCxpa18/")
    }

    @Test func extractsURLFromBilibiliShareBlob() {
        let blob = "【高能预警！】 bilibili 我正在看这个视频 https://b23.tv/AbCd123 复制此链接，打开手机B站"
        #expect(URLNormalizer.normalize(blob)?.absoluteString == "https://b23.tv/AbCd123")
    }

    @Test func extractsURLFromRedNoteShareBlob() {
        let blob = "59 今天分享一个超好看的视频😆 http://xhslink.com/a/Xy9Zk2 点击链接查看，或复制本条信息打开【小红书】App"
        #expect(URLNormalizer.normalize(blob)?.absoluteString == "http://xhslink.com/a/Xy9Zk2")
    }

    @Test func stopsAtNonURLCharacterWhenNoTrailingSpace() {
        // A link butted directly against CJK text (no separating space) ends at the
        // first character that can't appear in a URL.
        #expect(URLNormalizer.normalize("看这个https://v.douyin.com/9GUjWCxpa18凡凡")?.absoluteString
                == "https://v.douyin.com/9GUjWCxpa18")
    }

    @Test func stripsTrailingSentencePunctuation() {
        // A URL ending a sentence shouldn't capture the period/comma or a wrapping paren.
        #expect(URLNormalizer.normalize("watch it here: https://v.douyin.com/abc.")?.absoluteString
                == "https://v.douyin.com/abc")
        #expect(URLNormalizer.normalize("see (https://v.douyin.com/abc) now")?.absoluteString
                == "https://v.douyin.com/abc")
    }

    @Test func picksFirstURLWhenBlobHasSeveral() {
        let blob = "first https://v.douyin.com/first then https://v.douyin.com/second"
        #expect(URLNormalizer.normalize(blob)?.absoluteString == "https://v.douyin.com/first")
    }

    @Test func findsEmbeddedURLRegardlessOfSchemeCase() {
        #expect(URLNormalizer.normalize("看 HTTPS://v.douyin.com/abc 吧")?.absoluteString
                == "https://v.douyin.com/abc")
    }
}
