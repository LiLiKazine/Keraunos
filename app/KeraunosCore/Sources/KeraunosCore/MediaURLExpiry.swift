import Foundation

/// Parses the googlevideo `expire=<unix-ts>` deadline embedded in a resolved media URL.
/// Used to pre-empt a download against an about-to-die URL (→ `.needsRefresh`) before the
/// host returns a `403`.
public enum MediaURLExpiry {
    /// The absolute expiry deadline, or nil if the URL carries no numeric `expire=` param.
    public static func expiry(of url: URL) -> Date? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "expire" })?.value,
              let ts = TimeInterval(value) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
