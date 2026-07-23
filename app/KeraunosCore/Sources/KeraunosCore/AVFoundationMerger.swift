import Foundation
import AVFoundation

/// Muxes a video-only and an audio-only file into one MP4 using AVFoundation
/// passthrough (container remux, no transcoding). Fails cleanly with
/// `.mergeFailed` when a track is missing or the codec can't be carried.
public struct AVFoundationMerger: MediaMerging {
    private let diagnostics: (any TransferDiagnostics)?

    public init(diagnostics: (any TransferDiagnostics)? = nil) {
        self.diagnostics = diagnostics
    }

    public func merge(video videoURL: URL, audio audioURL: URL, into output: URL) async throws {
        // `AVURLAsset` classifies a file by its extension and refuses one it can't ("Cannot
        // Open") — our part files are named `…-video.part`, so it rejects them even though the
        // bytes are a valid MP4. Hand it symlinks with a media extension; AVFoundation follows
        // the link and reads the real bytes. (WebM/Opus still can't passthrough — that surfaces
        // as `.mergeFailed`, the ffmpeg-needed case.)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { removeScratch(scratch) }
        let videoLink = scratch.appendingPathComponent("video.mp4")
        let audioLink = scratch.appendingPathComponent("audio.mp4")
        try FileManager.default.createSymbolicLink(at: videoLink, withDestinationURL: videoURL)
        try FileManager.default.createSymbolicLink(at: audioLink, withDestinationURL: audioURL)

        let composition = AVMutableComposition()
        do {
            let videoAsset = AVURLAsset(url: videoLink)
            let audioAsset = AVURLAsset(url: audioLink)
            guard let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let srcAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
                  let dstVideo = composition.addMutableTrack(withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid),
                  let dstAudio = composition.addMutableTrack(withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw KeraunosError.mergeFailed
            }
            let videoDuration = try await videoAsset.load(.duration)
            let audioDuration = try await audioAsset.load(.duration)
            try dstVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: srcVideo, at: .zero)
            try dstAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: srcAudio, at: .zero)
            dstVideo.preferredTransform = try await srcVideo.load(.preferredTransform)
        } catch let error as KeraunosError {
            throw error
        } catch {
            throw KeraunosError.mergeFailed
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw KeraunosError.mergeFailed
        }
        // `uniqueDestination` gives a fresh path, but clear a stale collision defensively. A
        // missing file is the expected case, so only remove when one is actually present —
        // handling the removal error explicitly rather than discarding it.
        if FileManager.default.fileExists(atPath: output.path) {
            do {
                try FileManager.default.removeItem(at: output)
            } catch {
                diagnostics?.record(kind: "merge_output_replace",
                                    detail: "\(output.lastPathComponent): \(error)")
            }
        }
        do {
            try await export.export(to: output, as: .mp4)
        } catch {
            throw KeraunosError.mergeFailed
        }
    }

    /// Removes the temp symlink directory. Best-effort — a leftover symlink in the OS temp dir
    /// is harmless — but recorded (never silently swallowed) so a chronic failure stays visible.
    private func removeScratch(_ url: URL) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            diagnostics?.record(kind: "merge_scratch_cleanup",
                                detail: "\(url.lastPathComponent): \(error)")
        }
    }
}
