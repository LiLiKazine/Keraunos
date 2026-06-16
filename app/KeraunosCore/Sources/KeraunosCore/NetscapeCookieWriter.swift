import Foundation

/// Serializes cookies to the Netscape `cookies.txt` format yt-dlp loads via its
/// `cookiefile` option (parsed by Python's `http.cookiejar.MozillaCookieJar`).
/// The header line is required or the parser rejects the file.
public enum NetscapeCookieWriter {
    public static func write(_ cookies: [Cookie]) -> String {
        var out = "# Netscape HTTP Cookie File\n"
        for c in cookies {
            let expiry = c.expires.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let fields = [
                c.domain,
                c.includeSubdomains ? "TRUE" : "FALSE",
                c.path.isEmpty ? "/" : c.path,
                c.isSecure ? "TRUE" : "FALSE",
                expiry,
                c.name,
                c.value,
            ]
            out += fields.joined(separator: "\t") + "\n"
        }
        return out
    }
}
