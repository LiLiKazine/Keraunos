import Foundation

/// Turns raw user/clipboard text into a downloadable http(s) URL, or nil if it isn't a
/// link. Tolerates the common messy cases (trailing newline, missing scheme) without
/// accepting non-web schemes or free text.
public enum URLNormalizer {
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Share buttons (Douyin/Bilibili/RedNote) copy promo text with the link buried
        // inside, e.g. "…看看抖音…https://v.douyin.com/abc/ … A@G.iP …". Pull out the first
        // explicit http(s):// link when there is one; a scheme-less whole-string input
        // ("youtube.com/…") has no match and falls through to the path below.
        let extracted = embeddedURL(in: trimmed) ?? trimmed

        // A scheme-less but link-shaped input ("youtube.com/…") gets https:// so the
        // user doesn't have to type it; anything with an explicit scheme is left as-is.
        let candidate = hasScheme(extracted) ? extracted : "https://\(extracted)"

        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, host.contains(".")   // reject "hello" / "not a url"
        else { return nil }
        // RFC 3986 §3.1/§3.2.2: scheme and host are case-insensitive, so normalise them
        // to lowercase for stable `url.scheme == "https"` / host comparisons and display.
        // Path, query, and fragment are case-sensitive and are left untouched.
        components.scheme = scheme
        components.host = host.lowercased()
        return components.url
    }

    /// The scheme+host root (`https://host/`) of a URL — the page to load when signing in
    /// to a site. A raw video URL is often a deep/short link (e.g. `v.douyin.com/abc/`)
    /// that 302-redirects toward an app scheme, which WKWebView can't follow, so it never
    /// lands anywhere that sets the site's (guest) cookies. The origin root renders, lets
    /// the user log in via the site's own UI, and seeds those cookies. Returns nil if the
    /// URL has no scheme/host.
    public static func origin(of url: URL) -> URL? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port { components.port = port }
        components.path = "/"
        return components.url
    }

    /// The first `http(s)://` link embedded in free text, or nil if there isn't one.
    /// The link runs from the scheme up to the first character not legal in a URI
    /// (whitespace, CJK, a quote …); trailing sentence punctuation is then trimmed.
    private static func embeddedURL(in text: String) -> String? {
        guard let start = text.range(of: "https?://",
                                     options: [.regularExpression, .caseInsensitive])?.lowerBound
        else { return nil }

        var url = text[start...].prefix { allowedURLCharacters.contains($0) }
        // Trim trailing punctuation that reads as sentence/wrapping, not part of the link:
        // ".,;!" always, and a ")" only when it isn't balanced by a "(" inside the URL
        // (so "…/Foo_(bar)" is kept intact).
        while let last = url.last {
            if ".,;!".contains(last) {
                url = url.dropLast()
            } else if last == ")", !url.contains("(") {
                url = url.dropLast()
            } else {
                break
            }
        }
        return url.isEmpty ? nil : String(url)
    }

    /// Characters legal in a URI per RFC 3986 (unreserved + reserved + "%"). A character
    /// outside this set marks the end of an embedded link.
    private static let allowedURLCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=%"
    )

    private static func hasScheme(_ s: String) -> Bool {
        // RFC 3986 scheme prefix: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
        guard let colon = s.firstIndex(of: ":") else { return false }
        let scheme = s[s.startIndex..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
}
