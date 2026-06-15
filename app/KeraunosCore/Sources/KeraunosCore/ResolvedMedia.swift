import Foundation

/// A resolved, directly-downloadable media file (a single progressive stream).
public struct ResolvedMedia: Equatable, Sendable {
    public let directURL: URL
    public let suggestedFilename: String
    public let title: String

    public init(directURL: URL, suggestedFilename: String, title: String) {
        self.directURL = directURL
        self.suggestedFilename = suggestedFilename
        self.title = title
    }
}

/// Wire format returned by the Python extraction module.
private struct ExtractionResult: Decodable {
    let ok: Bool
    let directURL: String?
    let filename: String?
    let title: String?
    let errorKind: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case ok, filename, title, detail
        case directURL = "direct_url"
        case errorKind = "error_kind"
    }
}

/// Decodes the Python module's JSON into `ResolvedMedia`, throwing a mapped
/// `KeraunosError` for failure payloads or malformed data.
public enum ExtractionDecoder {
    public static func decode(_ data: Data) throws -> ResolvedMedia {
        let result: ExtractionResult
        do {
            result = try JSONDecoder().decode(ExtractionResult.self, from: data)
        } catch {
            throw KeraunosError.runtime(detail: "malformed extraction result")
        }
        guard result.ok, let urlString = result.directURL, let url = URL(string: urlString) else {
            throw KeraunosError(errorKind: result.errorKind ?? "runtime", detail: result.detail ?? "")
        }
        let filename = result.filename.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        return ResolvedMedia(directURL: url, suggestedFilename: filename, title: result.title ?? "")
    }
}
