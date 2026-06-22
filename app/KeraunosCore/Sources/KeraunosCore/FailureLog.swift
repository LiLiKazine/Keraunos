import Foundation

/// A local, append-only record of extraction/download failures for owner debugging.
/// Deliberately on-device only — no network, no telemetry (the project's whole premise).
/// One tab-separated line per failure: ISO-8601 timestamp, error kind, URL, detail.
public struct FailureLog: Sendable {
    public let fileURL: URL
    /// Most recent N entries kept; older ones are dropped so the file can't grow forever.
    let maxEntries: Int

    public init(fileURL: URL, maxEntries: Int = 200) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
    }
    public init(directory: URL, maxEntries: Int = 200) {
        self.init(fileURL: directory.appendingPathComponent("failures.log"), maxEntries: maxEntries)
    }

    /// True once at least one failure has been recorded (so a UI can hide an empty log).
    public var hasEntries: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    public func record(url: String, errorKind: String, detail: String = "", date: Date) {
        var lines = contents().split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        lines.append(Self.line(date: date, kind: errorKind, url: url, detail: detail))
        if lines.count > maxEntries { lines = Array(lines.suffix(maxEntries)) }
        try? (lines.joined(separator: "\n") + "\n").data(using: .utf8)?
            .write(to: fileURL, options: .atomic)
    }

    public func contents() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    /// Removes the log entirely (the "Clear" diagnostics action).
    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    static func line(date: Date, kind: String, url: String, detail: String) -> String {
        // Tabs separate fields, so flatten any newlines/tabs in free-text detail.
        let flatDetail = detail.replacingOccurrences(of: "\n", with: " ")
                               .replacingOccurrences(of: "\t", with: " ")
        // Redact secret-bearing query-param values so exported diagnostics never leak
        // signed-URL credentials (both the page URL and yt-dlp's error detail can embed them).
        return [ISO8601DateFormatter().string(from: date), kind, redact(url), redact(flatDetail)]
            .joined(separator: "\t")
    }

    /// Masks the VALUE of any credential-bearing query parameter, anywhere in `text`
    /// (works on a bare URL or on free text that embeds one). The param name must sit at
    /// a boundary (`?`, `&`, `;`, or whitespace) so `monkey=`/`lowkey=` aren't read as `key=`.
    /// Longer names precede their prefixes in the alternation so the regex prefers the
    /// longer match (e.g. `signature` over `sig`, `key-pair-id`/`keyid` over `key`).
    static func redact(_ text: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return Self.secretParamRegex.stringByReplacingMatches(
            in: text, range: range, withTemplate: "$1REDACTED")
    }

    private static let secretParamRegex = try! NSRegularExpression(
        pattern: "(?i)([?&;\\s](?:x-amz-signature|x-amz-credential|x-amz-security-token|access_token|key-pair-id|authorization|signature|password|passwd|secret|policy|token|keyid|hmac|sig|key|pwd|auth|pot)=)([^&\\s]*)")
}
