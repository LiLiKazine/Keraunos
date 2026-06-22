import Foundation

/// A local, append-only record of extraction/download failures for owner debugging.
/// Deliberately on-device only — no network, no telemetry (the project's whole premise).
/// One tab-separated line per failure: ISO-8601 timestamp, error kind, URL, detail.
public struct FailureLog: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) { self.fileURL = fileURL }
    public init(directory: URL) { self.fileURL = directory.appendingPathComponent("failures.log") }

    /// True once at least one failure has been recorded (so a UI can hide an empty log).
    public var hasEntries: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    public func record(url: String, errorKind: String, detail: String = "", date: Date) {
        guard let data = (Self.line(date: date, kind: errorKind, url: url, detail: detail) + "\n")
            .data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)   // first entry creates the file
        }
    }

    public func contents() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    static func line(date: Date, kind: String, url: String, detail: String) -> String {
        // Tabs separate fields, so flatten any newlines/tabs in free-text detail.
        let flatDetail = detail.replacingOccurrences(of: "\n", with: " ")
                               .replacingOccurrences(of: "\t", with: " ")
        return [ISO8601DateFormatter().string(from: date), kind, url, flatDetail]
            .joined(separator: "\t")
    }
}
