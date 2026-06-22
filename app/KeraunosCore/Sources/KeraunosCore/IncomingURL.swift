import Foundation

/// Resolves a URL the app was *opened with* to the http(s) media link to download.
/// Accepts a direct http(s) link or a `keraunos://download?url=<encoded>` deep link
/// (what a Share Extension or Shortcut hands over); returns nil for anything else.
/// The actual target is run through `URLNormalizer`, so scheme-less inner links work too.
public enum IncomingURL {
    public static func target(from url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "http", "https":
            return URLNormalizer.normalize(url.absoluteString)
        case "keraunos":
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "url" }?.value
            return raw.flatMap(URLNormalizer.normalize)
        default:
            return nil
        }
    }
}
