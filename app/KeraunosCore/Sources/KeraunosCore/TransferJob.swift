import Foundation

/// Why a job ended up in `.failed`. Surfaced in the UI and drives the recovery action.
public enum FailureReason: String, Codable, Sendable, Equatable {
    case network
    case insufficientSpace
    case refreshFailed
    case integrityCheckFailed
}

/// The durable state of a transfer job. `failed` carries the reason so the UI can offer
/// the right recovery (retry / manage storage) after a relaunch.
public enum JobState: Codable, Sendable, Equatable {
    case queued
    case downloading
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

    public init(remoteURL: URL, urlExpiresAt: Date?, chunkSize: Int?, partFileName: String,
                bytesWritten: Int64, totalBytes: Int64?, resumeData: Data?, taskIdentifier: Int?) {
        self.remoteURL = remoteURL
        self.urlExpiresAt = urlExpiresAt
        self.chunkSize = chunkSize
        self.partFileName = partFileName
        self.bytesWritten = bytesWritten
        self.totalBytes = totalBytes
        self.resumeData = resumeData
        self.taskIdentifier = taskIdentifier
    }
}

/// A durable, queued/in-flight download. Persisted verbatim; the store owns the array.
public struct TransferJob: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: Codable, Sendable, Equatable {
        case progressive(TrackJob)
        case adaptive(video: TrackJob, audio: TrackJob)
    }

    public let id: UUID
    public let sourcePageURL: URL
    public let formatSelection: FormatSelection
    public let credentialRef: String?
    public let createdAt: Date
    public var state: JobState
    public var kind: Kind
    public let suggestedFilename: String
    /// Set on completion (relative name of the file placed in the DownloadStore). The
    /// absolute destination URL is computed at merge time, not persisted (container drift).
    public var savedFilename: String?
    public let autoSaveToPhotos: Bool

    public init(id: UUID, sourcePageURL: URL, formatSelection: FormatSelection,
                credentialRef: String?, createdAt: Date, state: JobState, kind: Kind,
                suggestedFilename: String, savedFilename: String?, autoSaveToPhotos: Bool) {
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
}
