import Foundation

/// One user-selectable resolution from the picker. `formatID` is yt-dlp's format id,
/// replayed in phase 2 to re-select exactly this stream; `isAdaptive` marks a video-only
/// stream that must be paired with a separate audio track (vs. an already-muxed file).
public struct FormatOption: Equatable, Sendable {
    public let height: Int
    public let codecLabel: String
    public let approxBytes: Int64?
    public let formatID: String
    public let isAdaptive: Bool

    public init(height: Int, codecLabel: String, approxBytes: Int64?,
                formatID: String, isAdaptive: Bool) {
        self.height = height
        self.codecLabel = codecLabel
        self.approxBytes = approxBytes
        self.formatID = formatID
        self.isAdaptive = isAdaptive
    }

    /// Picker row text, e.g. "1080p · H.264 · 45 MB". Codec and size segments are
    /// dropped when unavailable so a bare "720p" is still shown.
    public var displayLabel: String {
        var parts = ["\(height)p"]
        if !codecLabel.isEmpty { parts.append(codecLabel) }
        if let approxBytes {
            parts.append(approxBytes.formatted(.byteCount(style: .file)))
        }
        return parts.joined(separator: " · ")
    }
}
