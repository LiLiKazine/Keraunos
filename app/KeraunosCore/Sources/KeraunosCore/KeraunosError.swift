import Foundation

/// All failures surfaced to the UI. Python exceptions are mapped to these at the
/// extraction boundary so nothing above the boundary sees a Python object.
public enum KeraunosError: Error, Equatable {
    case unsupported
    case needsFfmpeg
    case requiresAuth
    /// Network failure while *resolving* the URL (Python extraction side).
    case extractNetwork
    /// Network failure while *transferring* a track (Swift `Downloader` side).
    case downloadNetwork
    case runtime(detail: String)
    case cancelled
    case mergeFailed
    case timedOut
    /// Content is gone, private (no sign-in path), or geo-blocked — distinct from a
    /// tool-side `unsupported`.
    case unavailable
    /// Host is rate-limiting requests (HTTP 429). Manually retryable after a wait.
    case rateLimited
}

public extension KeraunosError {
    /// Maps an `error_kind` string emitted by the Python extraction module.
    init(errorKind: String, detail: String = "") {
        switch errorKind {
        case "unsupported":   self = .unsupported
        case "needs_ffmpeg":  self = .needsFfmpeg
        case "requires_auth":    self = .requiresAuth
        case "extract_network":  self = .extractNetwork
        case "download_network": self = .downloadNetwork
        // Legacy/un-split value: extraction is the only Python-side source of "network".
        case "network":          self = .extractNetwork
        case "timeout":          self = .timedOut
        case "unavailable":      self = .unavailable
        case "rate_limited":     self = .rateLimited
        default:              self = .runtime(detail: detail.isEmpty ? errorKind : detail)
        }
    }
}

public extension KeraunosError {
    /// Stable lowercase slug, matching the Python `error_kind` vocabulary, for logging.
    var kind: String {
        switch self {
        case .unsupported:     return "unsupported"
        case .needsFfmpeg:     return "needs_ffmpeg"
        case .requiresAuth:    return "requires_auth"
        case .extractNetwork:  return "extract_network"
        case .downloadNetwork: return "download_network"
        case .runtime:         return "runtime"
        case .cancelled:       return "cancelled"
        case .mergeFailed:     return "merge_failed"
        case .timedOut:        return "timeout"
        case .unavailable:     return "unavailable"
        case .rateLimited:     return "rate_limited"
        }
    }

    /// Whether retrying the same URL could plausibly succeed. True for transient faults
    /// (network, timeout, unknown runtime); false for deterministic outcomes and for
    /// auth (which is recovered via sign-in, not a plain retry) and user cancellation.
    var isRetryable: Bool {
        switch self {
        case .extractNetwork, .downloadNetwork, .timedOut, .runtime, .rateLimited:
            return true
        case .unsupported, .needsFfmpeg, .requiresAuth, .cancelled, .mergeFailed, .unavailable:
            return false
        }
    }

    /// Whether we should *transparently* retry once (without surfacing) before giving up.
    /// A STRICT SUBSET of `isRetryable`: only transient transport/cold-start faults a warm
    /// retry clears. `.rateLimited` (re-hammering a throttled host is wrong — the message
    /// says "wait") and `.runtime` (don't auto-loop on unknown faults) stay *manually*
    /// retryable but are NOT auto-retryable.
    var isAutoRetryable: Bool {
        switch self {
        case .extractNetwork, .timedOut, .downloadNetwork:
            return true
        case .rateLimited, .runtime, .unsupported, .needsFfmpeg, .requiresAuth,
             .cancelled, .mergeFailed, .unavailable:
            return false
        }
    }
}

extension KeraunosError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported:        return "This link isn't supported."
        case .needsFfmpeg:        return "This video needs format-merging support, coming in a later version."
        case .requiresAuth:       return "This video requires sign-in (cookies), which isn't supported yet."
        case .extractNetwork:     return "Couldn't reach the site to read the video — check your connection."
        case .downloadNetwork:    return "Download failed — check your connection."
        case .runtime(let detail): return "Something went wrong: \(detail)"
        case .cancelled:          return "Download cancelled."
        case .mergeFailed:        return "Couldn't combine the video and audio tracks."
        case .timedOut:           return "Extraction took too long and was stopped."
        case .unavailable:        return "This video is unavailable — it may be private, removed, or geo-blocked."
        case .rateLimited:        return "The site is limiting requests right now — wait a bit and try again."
        }
    }
}
