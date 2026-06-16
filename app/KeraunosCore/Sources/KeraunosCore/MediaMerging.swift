import Foundation

/// Muxes a video-only and an audio-only file into one container at `output`.
/// The native implementation (AVFoundationMerger) ships now; an ffmpeg-backed
/// implementation can replace it later with no change to callers.
public protocol MediaMerging: Sendable {
    func merge(video videoURL: URL, audio audioURL: URL, into output: URL) async throws
}

/// Deterministic test double: records its inputs and writes a marker file, or
/// fails on demand.
public final class MockMerger: MediaMerging, @unchecked Sendable {
    public private(set) var received: (video: URL, audio: URL, output: URL)?
    public var shouldFail = false
    public init() {}

    public func merge(video videoURL: URL, audio audioURL: URL, into output: URL) async throws {
        received = (videoURL, audioURL, output)
        if shouldFail { throw KeraunosError.mergeFailed }
        try Data("merged".utf8).write(to: output)
    }
}
