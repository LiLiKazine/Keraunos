import Foundation

/// Turns a `ResolvedMedia` into a finished file in the store's directory:
/// progressive = download one file; adaptive = download both tracks to a temp
/// dir, mux into one MP4, and clean up the temp inputs.
public struct MediaAssembler {
    public enum Phase: Sendable { case downloading, downloadingVideo, downloadingAudio, merging }

    private let downloader: any FileDownloading
    private let merger: any MediaMerging

    public init(downloader: any FileDownloading, merger: any MediaMerging) {
        self.downloader = downloader
        self.merger = merger
    }

    public func assemble(_ media: ResolvedMedia,
                         into store: DownloadStore,
                         isolation: isolated (any Actor)? = #isolation,
                         onPhase: (Phase) -> Void = { _ in },
                         onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        switch media.kind {
        case .progressive(let track):
            onPhase(.downloading)
            let destination = store.uniqueDestination(for: media.suggestedFilename)
            try await downloader.download(track, to: destination, onProgress: onProgress)
            return destination

        case .adaptive(let video, let audio):
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            let videoURL = scratch.appendingPathComponent("video.\(video.fileExtension)")
            let audioURL = scratch.appendingPathComponent("audio.\(audio.fileExtension)")
            // Two transfers share one bar: video fills 0...0.5, audio 0.5...1.0.
            onPhase(.downloadingVideo)
            try await downloader.download(video, to: videoURL) { onProgress($0 * 0.5) }
            onPhase(.downloadingAudio)
            try await downloader.download(audio, to: audioURL) { onProgress(0.5 + $0 * 0.5) }

            onPhase(.merging)
            let base = (media.suggestedFilename as NSString).deletingPathExtension
            // Uniqued, so a same-titled prior download isn't clobbered (no removeItem).
            let destination = store.uniqueDestination(for: "\(base).mp4")
            try await merger.merge(video: videoURL, audio: audioURL, into: destination)
            return destination
        }
    }
}
