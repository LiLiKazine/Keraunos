import Foundation

/// Resolves a page URL to a directly-downloadable media file. The real
/// implementation (PythonExtractor, in the app target) arrives in Phase 4;
/// until then the app and tests use MockExtractor.
public protocol MediaExtracting: Sendable {
    func resolve(_ url: URL) async throws -> ResolvedMedia
}

/// Deterministic test/preview double.
public struct MockExtractor: MediaExtracting {
    public var result: Result<ResolvedMedia, KeraunosError>

    public init(result: Result<ResolvedMedia, KeraunosError> = .success(
        ResolvedMedia(directURL: URL(string: "https://example.com/sample.mp4")!,
                      suggestedFilename: "sample.mp4",
                      title: "Sample"))) {
        self.result = result
    }

    public func resolve(_ url: URL) async throws -> ResolvedMedia {
        try result.get()
    }
}
