import Foundation

/// A resolved download: either one already-muxed file, or a video+audio pair to mux.
public struct ResolvedMedia: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case progressive(MediaTrack)
        case adaptive(video: MediaTrack, audio: MediaTrack)
    }
    public let kind: Kind
    public let title: String
    public let suggestedFilename: String

    public init(kind: Kind, title: String, suggestedFilename: String) {
        self.kind = kind
        self.title = title
        self.suggestedFilename = suggestedFilename
    }
}

/// Wire format emitted by keraunos_extract.py.
private struct TrackPayload: Decodable {
    let url: String
    let headers: [String: String]?
    let vcodec: String?
    let acodec: String?
    let ext: String?
    let chunkSize: Int?
    enum CodingKeys: String, CodingKey {
        case url, headers, vcodec, acodec, ext
        case chunkSize = "chunk_size"
    }
}

private struct ExtractionResult: Decodable {
    let ok: Bool
    let kind: String?
    let title: String?
    let filename: String?
    let media: TrackPayload?
    let video: TrackPayload?
    let audio: TrackPayload?
    let errorKind: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case ok, kind, title, filename, media, video, audio, detail
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
        guard result.ok else {
            throw KeraunosError(errorKind: result.errorKind ?? "runtime", detail: result.detail ?? "")
        }
        let title = result.title ?? ""
        switch result.kind {
        case "progressive":
            guard let track = Self.track(result.media) else {
                throw KeraunosError.runtime(detail: "missing progressive media")
            }
            return ResolvedMedia(kind: .progressive(track),
                                 title: title,
                                 suggestedFilename: Self.filename(result.filename, fallbackURL: track.url))
        case "adaptive":
            guard let video = Self.track(result.video), let audio = Self.track(result.audio) else {
                throw KeraunosError.runtime(detail: "missing adaptive tracks")
            }
            return ResolvedMedia(kind: .adaptive(video: video, audio: audio),
                                 title: title,
                                 suggestedFilename: Self.filename(result.filename, fallbackURL: video.url))
        default:
            throw KeraunosError.runtime(detail: "unknown extraction kind")
        }
    }

    private static func track(_ payload: TrackPayload?) -> MediaTrack? {
        guard let payload, let url = URL(string: payload.url) else { return nil }
        return MediaTrack(url: url,
                          httpHeaders: payload.headers ?? [:],
                          codec: payload.vcodec ?? payload.acodec ?? "",
                          fileExtension: payload.ext ?? url.pathExtension,
                          chunkSize: payload.chunkSize)
    }

    private static func filename(_ name: String?, fallbackURL: URL) -> String {
        if let name, !name.isEmpty { return name }
        return fallbackURL.lastPathComponent
    }

    /// Decodes the phase-1 (`list_formats`) payload. A `"choices"` kind yields
    /// `.choices`; any other success kind is delegated to `decode(_:)` and wrapped in
    /// `.ready`; failure payloads throw the mapped `KeraunosError`.
    public static func decodeListing(_ data: Data) throws -> FormatListing {
        struct Envelope: Decodable {
            let ok: Bool
            let kind: String?
            let options: [OptionPayload]?
            let errorKind: String?
            let detail: String?
            enum CodingKeys: String, CodingKey {
                case ok, kind, options, detail
                case errorKind = "error_kind"
            }
        }
        struct OptionPayload: Decodable {
            let height: Int
            let codec: String?
            let approx_bytes: Int64?
            let format_id: String
            let adaptive: Bool
        }
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw KeraunosError.runtime(detail: "malformed extraction result")
        }
        guard envelope.ok else {
            throw KeraunosError(errorKind: envelope.errorKind ?? "runtime", detail: envelope.detail ?? "")
        }
        if envelope.kind == "choices" {
            let options = (envelope.options ?? []).map {
                FormatOption(height: $0.height, codecLabel: $0.codec ?? "",
                             approxBytes: $0.approx_bytes, formatID: $0.format_id,
                             isAdaptive: $0.adaptive)
            }
            return .choices(options)
        }
        return .ready(try decode(data))
    }
}
