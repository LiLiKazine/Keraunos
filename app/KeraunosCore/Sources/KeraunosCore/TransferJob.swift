import Foundation

/// Why a job ended up in `.failed`. Surfaced in the UI and drives the recovery action.
public enum FailureReason: String, Codable, Sendable, Equatable {
    case network
    case insufficientSpace
    case refreshFailed
    case integrityCheckFailed
    /// The parts downloaded intact (integrity passed) but muxing them into one file failed —
    /// typically a codec AVFoundation can't passthrough-remux (the "needs ffmpeg" case).
    /// Distinct from `integrityCheckFailed` so the UI doesn't blame the data as "incomplete".
    case mergeFailed
}

/// The durable state of a transfer job. `failed` carries the reason so the UI can offer
/// the right recovery (retry / manage storage) after a relaunch.
public enum JobState: Codable, Sendable, Equatable {
    case queued
    case downloading
    case paused
    case needsRefresh
    case readyToMerge
    case merging
    case completed
    case failed(FailureReason)
    case cancelled
}

/// Enough to deterministically re-pick the SAME format on a refresh re-extraction, so a
/// resumed download continues the byte-identical file rather than a different rendition.
public struct FormatSelection: Codable, Sendable, Equatable {
    public let formatID: String
    public let height: Int?
    public let isAdaptive: Bool

    public init(formatID: String, height: Int?, isAdaptive: Bool) {
        self.formatID = formatID
        self.height = height
        self.isAdaptive = isAdaptive
    }
}

/// One downloadable track's durable state. `partFileName` is a NAME resolved against the
/// store's parts directory at runtime — never a persisted absolute URL (the app container
/// path drifts across installs). `bytesWritten` is the authoritative resume offset.
public struct TrackJob: Codable, Sendable, Equatable {
    /// The resolved direct-media URL. Mutable because a `.needsRefresh` recovery replaces it
    /// with a freshly re-extracted URL (the old one expired).
    public var remoteURL: URL
    public var urlExpiresAt: Date?
    public let chunkSize: Int?
    public let partFileName: String
    public var bytesWritten: Int64
    public var totalBytes: Int64?
    public var resumeData: Data?
    public var taskIdentifier: Int?
    /// yt-dlp's per-format request headers (User-Agent, Referer, and — for authenticated
    /// sources — Cookie), replayed on every request including post-relaunch resumes so CDNs
    /// accept the transfer. Persisted with the job.
    public var requestHeaders: [String: String]
    /// The extraction-time size estimate (yt-dlp `filesize`/`filesize_approx`), carried so the
    /// queue can show a determinate bar before the first response — adaptive tracks download
    /// sequentially, so the second track's real total isn't known until it starts.
    ///
    /// **Display only, never control flow.** `totalBytes` gates chunk termination
    /// (`length >= total`), `firstIncompleteTrackIndex`, and the finalizer's integrity check;
    /// an estimate low by even a byte would truncate the download there.
    public var approxBytes: Int64?

    public init(remoteURL: URL, urlExpiresAt: Date?, chunkSize: Int?, partFileName: String,
                bytesWritten: Int64, totalBytes: Int64?, resumeData: Data?, taskIdentifier: Int?,
                requestHeaders: [String: String] = [:], approxBytes: Int64? = nil) {
        self.remoteURL = remoteURL
        self.urlExpiresAt = urlExpiresAt
        self.chunkSize = chunkSize
        self.partFileName = partFileName
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.resumeData = resumeData
        self.taskIdentifier = taskIdentifier
        self.requestHeaders = requestHeaders
        self.approxBytes = approxBytes
    }
}

/// A durable, queued/in-flight download. Persisted verbatim; the store owns the array.
public struct TransferJob: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: Codable, Sendable, Equatable {
        case progressive(TrackJob)
        case adaptive(video: TrackJob, audio: TrackJob)
    }

    /// Durable checkpoint for the filesystem half of finalization. The ready checkpoint is
    /// persisted before promoting the job-owned stage into Downloads, which makes a crash after
    /// that atomic move distinguishable from an unrelated file occupying the reserved name.
    public enum FinalizationPhase: String, Codable, Sendable, Equatable {
        case preparing
        case readyToPromote
    }

    public let id: UUID
    public let sourcePageURL: URL
    public let formatSelection: FormatSelection
    public let credentialRef: String?
    public let createdAt: Date
    public var state: JobState
    public var kind: Kind
    public let suggestedFilename: String
    /// Reserved before finalization I/O, then retained on completion (relative name of the file
    /// placed in the DownloadStore). The absolute destination URL is never persisted because the
    /// app container path can drift across installs.
    public var savedFilename: String?
    public let autoSaveToPhotos: Bool
    public var finalizationPhase: FinalizationPhase?

    public init(id: UUID, sourcePageURL: URL, formatSelection: FormatSelection,
                credentialRef: String?, createdAt: Date, state: JobState, kind: Kind,
                suggestedFilename: String, savedFilename: String?, autoSaveToPhotos: Bool,
                finalizationPhase: FinalizationPhase? = nil) {
        self.id = id
        self.sourcePageURL = sourcePageURL
        self.formatSelection = formatSelection
        self.credentialRef = credentialRef
        self.createdAt = createdAt
        self.state = state
        self.kind = kind
        self.suggestedFilename = suggestedFilename
        self.savedFilename = savedFilename
        self.autoSaveToPhotos = autoSaveToPhotos
        self.finalizationPhase = finalizationPhase
    }

    /// The job's tracks in a stable order: `[progressive]` or `[video, audio]`.
    public var tracks: [TrackJob] {
        switch kind {
        case .progressive(let track): return [track]
        case .adaptive(let video, let audio): return [video, audio]
        }
    }

    /// Part-file names this job owns — used for cleanup and orphan reconciliation.
    public var trackPartFileNames: [String] { tracks.map(\.partFileName) }

    /// Deterministic private output stages. There is no user-facing filename allocation here:
    /// retries reuse these job-owned names, and the finalizer bounds them to at most one file.
    public var finalizationPartialFileName: String {
        "\(id.uuidString).finalizing.partial.\(finalizationStageExtension)"
    }

    public var finalizationReadyFileName: String {
        "\(id.uuidString).finalizing.ready.\(finalizationStageExtension)"
    }

    /// A hard-link identity anchor created before the ready stage is promoted. Because promotion
    /// is a same-volume rename, this entry and the destination retain the same device/inode. It
    /// lets crash recovery distinguish our output from a same-sized replacement without hashing
    /// or copying multi-gigabyte media.
    public var finalizationPromotionCheckpointFileName: String {
        "\(id.uuidString).finalizing.promoted.\(finalizationStageExtension)"
    }

    /// Deterministic media-daemon aliases used by `AVFoundationMerger`. A crash can leave at most
    /// these two hard links per job; retry and store cleanup reuse/remove the same owned names.
    public var finalizationVideoScratchFileName: String {
        "\(finalizationPartialFileName).scratch-video.mp4"
    }

    public var finalizationAudioScratchFileName: String {
        "\(finalizationPartialFileName).scratch-audio.m4a"
    }

    /// Every file in the private parts directory owned by this durable job. Store-level orphan
    /// reconciliation uses this superset; transfer/finalizer integrity checks remain track-only.
    public var ownedPartFileNames: [String] {
        trackPartFileNames + [
            finalizationPartialFileName,
            finalizationReadyFileName,
            finalizationPromotionCheckpointFileName,
            finalizationVideoScratchFileName,
            finalizationAudioScratchFileName
        ]
    }

    private var finalizationStageExtension: String {
        switch kind {
        case .progressive: "media"
        case .adaptive: "mp4"
        }
    }
}
