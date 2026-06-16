import Foundation

/// One directly-downloadable media stream (progressive file, or a video-only /
/// audio-only track of an adaptive source). `httpHeaders` are yt-dlp's per-format
/// request headers, replayed by the downloader so CDNs accept the request.
public struct MediaTrack: Equatable, Sendable {
    public let url: URL
    public let httpHeaders: [String: String]
    public let codec: String
    public let fileExtension: String

    public init(url: URL, httpHeaders: [String: String], codec: String, fileExtension: String) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.codec = codec
        self.fileExtension = fileExtension
    }
}
