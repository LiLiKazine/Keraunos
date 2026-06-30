import Foundation

/// The `keraunos://` deep-link contract, shared by the *producers* (the Share Extension
/// and any Shortcut) and the *consumer* (`IncomingURL`). Keeping the scheme/host/param
/// names and the encoding in one place — guarded by a round-trip test — stops the two
/// sides from silently drifting apart.
///
/// Shape: `keraunos://download?url=<percent-encoded media URL>`.
public enum KeraunosDeepLink {
    public static let scheme = "keraunos"
    public static let host = "download"
    public static let queryName = "url"

    /// Characters left un-escaped in the encoded inner URL: RFC 3986 *unreserved* only.
    /// Crucially this excludes `?`, `&`, `=`, `+`, `/`, `:` — every reserved character is
    /// percent-encoded so the inner link survives as one opaque token. Using
    /// `URLComponents.queryItems` (or `.urlQueryAllowed`) would leave `&`/`=` intact and a
    /// link like `…/watch?v=x&t=30` would be mis-parsed, dropping everything after `&`.
    private static let innerURLAllowed =
        CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// Builds `keraunos://download?url=<encoded>` for a media link, or nil if it can't be
    /// percent-encoded.
    public static func url(forMediaURL mediaURL: String) -> URL? {
        guard let encoded = mediaURL.addingPercentEncoding(withAllowedCharacters: innerURLAllowed)
        else { return nil }
        return URL(string: "\(scheme)://\(host)?\(queryName)=\(encoded)")
    }

    /// The media link carried by a `keraunos://` deep link, or nil if the scheme doesn't
    /// match or the `url` query item is absent. The value is returned percent-decoded.
    public static func mediaURL(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == queryName }?.value
    }
}
