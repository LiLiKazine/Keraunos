import Foundation

/// Builds a durable `TransferJob` from a foreground extraction result. Pure and Core-side so
/// enqueue logic is `swift test`-able: it copies each `MediaTrack`'s replayable request
/// headers and chunk-size hint onto the persisted `TrackJob`, assigns deterministic part-file
/// NAMES (never absolute URLs), and starts the job `.queued` with a zero offset.
public enum TransferJobFactory {
    public static func make(id: UUID, from media: ResolvedMedia, sourcePageURL: URL,
                            selection: FormatSelection, autoSaveToPhotos: Bool,
                            credentialRef: String?, createdAt: Date, partPrefix: String) -> TransferJob {
        let kind: TransferJob.Kind
        switch media.kind {
        case .progressive(let t):
            kind = .progressive(trackJob(t, name: "\(partPrefix)-media.part"))
        case .adaptive(let v, let a):
            kind = .adaptive(video: trackJob(v, name: "\(partPrefix)-video.part"),
                             audio: trackJob(a, name: "\(partPrefix)-audio.part"))
        }
        return TransferJob(id: id, sourcePageURL: sourcePageURL, formatSelection: selection,
                           credentialRef: credentialRef, createdAt: createdAt, state: .queued,
                           kind: kind, suggestedFilename: media.suggestedFilename,
                           savedFilename: nil, autoSaveToPhotos: autoSaveToPhotos)
    }

    private static func trackJob(_ t: MediaTrack, name: String) -> TrackJob {
        TrackJob(remoteURL: t.url, urlExpiresAt: MediaURLExpiry.expiry(of: t.url),
                 chunkSize: t.chunkSize, partFileName: name, bytesWritten: 0, totalBytes: nil,
                 resumeData: nil, taskIdentifier: nil, requestHeaders: t.httpHeaders)
    }
}
