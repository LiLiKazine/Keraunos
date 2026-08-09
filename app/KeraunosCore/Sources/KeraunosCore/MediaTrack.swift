import Foundation

/// One directly-downloadable media stream (progressive file, or a video-only /
/// audio-only track of a DASH source). `httpHeaders` are yt-dlp's per-format
/// request headers, replayed by the downloader so CDNs accept the request.
public struct MediaTrack: Equatable, Sendable {
    public let url: URL
    public let httpHeaders: [String: String]
    public let codec: String
    public let fileExtension: String
    /// Preferred HTTP Range chunk size in bytes, from yt-dlp's
    /// `downloader_options.http_chunk_size`. `nil` for hosts that download fine in one
    /// request; a positive value opts the track into ranged/chunked downloading
    /// (googlevideo throttles unranged full-file GETs).
    public let chunkSize: Int?
    /// yt-dlp's `filesize` (exact) or `filesize_approx` (derived from bitrate) for this format.
    /// **Display only** — it lets the queue show a determinate bar before the first response,
    /// and must never gate control flow: it can be well under the real size, which as a
    /// `totalBytes` would end a chunked transfer mid-file. `nil` when yt-dlp reports neither.
    public let approxBytes: Int64?

    public init(url: URL, httpHeaders: [String: String], codec: String,
                fileExtension: String, chunkSize: Int? = nil, approxBytes: Int64? = nil) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.codec = codec
        self.fileExtension = fileExtension
        self.chunkSize = chunkSize
        self.approxBytes = approxBytes
    }
}
