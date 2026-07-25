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
        // bytes are a valid MP4. Give it inputs with a media extension.
        //
        // These MUST be HARD links, not symlinks. On a real device `loadTracks`/export parse
        // media out-of-process (the media-services daemon), which is handed a sandbox extension
        // for the path we pass. A symlink resolves to the real `.part` under Application Support,
        // a path the daemon has no extension for → `NSFileReadNoPermissionError` (257) and a
        // spurious `.mergeFailed`. (This passes on the simulator, which doesn't enforce the
        // extension boundary — the gap that let the symlink version ship.) A hard link is another
        // directory entry for the same inode, so the daemon opens the real bytes directly through
        // the path it was granted. `tmp/` and Application Support share the app container's one
        // filesystem, so `linkItem` is valid. (WebM/Opus still can't passthrough — that surfaces
        // as `.mergeFailed`, the ffmpeg-needed case.)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { removeScratch(scratch) }
        let videoLink = scratch.appendingPathComponent("video.mp4")
        let audioLink = scratch.appendingPathComponent("audio.mp4")
        try FileManager.default.linkItem(at: videoURL, to: videoLink)
        try FileManager.default.linkItem(at: audioURL, to: audioLink)

        let videoAsset = AVURLAsset(url: videoLink)
        let audioAsset = AVURLAsset(url: audioLink)
        let composition = AVMutableComposition()
        do {
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
        } catch {
            // Normalize to `.mergeFailed`, but first capture the real cause + codecs — otherwise
            // "mergeFailed" alone can't distinguish an unsupported codec (needs ffmpeg) from a
            // non-media body (e.g. an auth wall that passed the byte-length check).
            await recordMergeFailure(phase: "compose", underlying: error, video: videoAsset, audio: audioAsset)
            throw KeraunosError.mergeFailed
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            await recordMergeFailure(phase: "no-passthrough-session", underlying: nil, video: videoAsset, audio: audioAsset)
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
            await recordMergeFailure(phase: "export", underlying: error, video: videoAsset, audio: audioAsset)
            throw KeraunosError.mergeFailed
        }
    }

    /// Records the real reason a mux failed, with each track's codec, before the caller
    /// normalizes to `.mergeFailed`. Best-effort and never throws — a diagnostic must not
    /// mask the merge error it's describing.
    private func recordMergeFailure(phase: String, underlying: Error?,
                                    video: AVURLAsset, audio: AVURLAsset) async {
        guard let diagnostics else { return }
        let videoCodec = await codec(of: video, mediaType: .video)
        let audioCodec = await codec(of: audio, mediaType: .audio)
        let cause = underlying.map { "\(($0 as NSError).domain)#\(($0 as NSError).code) \($0.localizedDescription)" }
            ?? "no passthrough-compatible export session"
        // When a track had no readable codec, the file may not be media at all (an auth/error
        // page that passed the byte-length check). Sniff its leading bytes so the log says
        // WHY — `html`/`json` means non-media body, `webm`/`ogg` means a codec AVFoundation
        // won't classify (needs ffmpeg), not a bad download.
        var bodyHints = ""
        for (name, codec, asset) in [("video", videoCodec, video), ("audio", audioCodec, audio)]
        where codec == "none" || codec == "unknown" || codec == "unreadable" {
            bodyHints += " \(name)-body=\(bodySignature(of: asset.url))"
        }
        diagnostics.record(kind: "merge_unsupported",
                           detail: "\(phase): video=\(videoCodec) audio=\(audioCodec)\(bodyHints): \(cause)")
    }

    /// Classifies a file by its first bytes so a non-media body is named in the log. Reads at
    /// most 64 bytes and never throws — the handle closes on scope exit.
    private func bodySignature(of url: URL) -> String {
        let head: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            head = try handle.read(upToCount: 64) ?? Data()
        } catch {
            return "unreadable"
        }
        if head.isEmpty { return "empty" }
        // MP4/MOV: an `ftyp` box at offset 4. Matroska/WebM: EBML magic. Ogg: `OggS`.
        if head.count >= 8, Array(head[4..<8]) == Array("ftyp".utf8) { return "mp4" }
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        if head.starts(with: Array("OggS".utf8)) { return "ogg" }
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("<!doctype") || text.hasPrefix("<html") || text.hasPrefix("<") { return "html" }
        if text.hasPrefix("{") || text.hasPrefix("[") { return "json" }
        return "binary"
    }

    /// The four-character codec tag of a track (e.g. `avc1`, `hvc1`, `mp4a`, `Opus`, `vp09`),
    /// or a marker when no track/format is readable. Never throws — reading a codec for a
    /// diagnostic must not itself become a failure.
    private func codec(of asset: AVURLAsset, mediaType: AVMediaType) async -> String {
        do {
            guard let track = try await asset.loadTracks(withMediaType: mediaType).first else { return "none" }
            guard let desc = try await track.load(.formatDescriptions).first else { return "unknown" }
            let subtype = CMFormatDescriptionGetMediaSubType(desc)
            let bytes = [UInt8((subtype >> 24) & 0xFF), UInt8((subtype >> 16) & 0xFF),
                         UInt8((subtype >> 8) & 0xFF), UInt8(subtype & 0xFF)]
            let trimmed = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? String(subtype) : trimmed
        } catch {
            return "unreadable"
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
