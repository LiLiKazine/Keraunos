import Foundation

/// Turns raw user/clipboard text into a downloadable http(s) URL, or nil if it isn't a
/// link. Tolerates the common messy cases (trailing newline, missing scheme) without
/// accepting non-web schemes or free text.
public enum URLNormalizer {
    public static func normalize(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // A scheme-less but link-shaped input ("youtube.com/…") gets https:// so the
        // user doesn't have to type it; anything with an explicit scheme is left as-is.
        let candidate = hasScheme(trimmed) ? trimmed : "https://\(trimmed)"

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

    private static func hasScheme(_ s: String) -> Bool {
        // RFC 3986 scheme prefix: ALPHA *( ALPHA / DIGIT / "+" / "-" / "." ) ":"
        guard let colon = s.firstIndex(of: ":") else { return false }
        let scheme = s[s.startIndex..<colon]
        guard let first = scheme.first, first.isLetter else { return false }
        return scheme.allSatisfy { $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }
    }
}
