import Foundation

/// Supplies a Netscape `cookies.txt` for the next extraction. The returned file
/// is a short-lived, caller-owned temp file (the caller deletes it). Returns nil
/// when there are no cookies. `Sendable` so the `PythonExtractor` actor can hold it.
public protocol CookieProviding: Sendable {
    func cookieFile() async -> URL?
}
