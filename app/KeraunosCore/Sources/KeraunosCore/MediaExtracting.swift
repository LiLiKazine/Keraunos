import Foundation

/// Resolves a page URL to downloadable media. Two phases: `listFormats` lists the
/// resolutions available (or returns a ready-to-download result when there is no choice);
/// `resolve(_:option:)` re-resolves a specific chosen format.
public protocol MediaExtracting: Sendable {
    func listFormats(_ url: URL) async throws -> FormatListing
    func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia
}

/// Deterministic test/preview double. `listing` overrides the phase-1 result; when nil it
/// is derived from `result` (`.success` → `.ready`, `.failure` → thrown), so existing
/// single-result setups keep working.
public struct MockExtractor: MediaExtracting {
    public var result: Result<ResolvedMedia, KeraunosError>
    public var listing: Result<FormatListing, KeraunosError>?

    public init(result: Result<ResolvedMedia, KeraunosError> = .success(
        ResolvedMedia(
            kind: .progressive(MediaTrack(url: URL(string: "https://example.com/sample.mp4")!,
                                          httpHeaders: [:], codec: "avc1", fileExtension: "mp4")),
            title: "Sample",
            suggestedFilename: "sample.mp4")),
                listing: Result<FormatListing, KeraunosError>? = nil) {
        self.result = result
        self.listing = listing
    }

    public func listFormats(_ url: URL) async throws -> FormatListing {
        if let listing { return try listing.get() }
        return .ready(try result.get())
    }

    public func resolve(_ url: URL, option: FormatOption?) async throws -> ResolvedMedia {
        try result.get()
    }
}
