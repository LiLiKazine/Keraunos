import Foundation
import AVFoundation

/// Muxes a video-only and an audio-only file into one MP4 using AVFoundation
/// passthrough (container remux, no transcoding). Fails cleanly with
/// `.mergeFailed` when a track is missing or the codec can't be carried.
public struct AVFoundationMerger: MediaMerging {
    public init() {}

    public func merge(video videoURL: URL, audio audioURL: URL, into output: URL) async throws {
        let composition = AVMutableComposition()
        do {
            let videoAsset = AVURLAsset(url: videoURL)
            let audioAsset = AVURLAsset(url: audioURL)
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
        try? FileManager.default.removeItem(at: output)
        do {
            try await export.export(to: output, as: .mp4)
        } catch {
            throw KeraunosError.mergeFailed
        }
    }
}
