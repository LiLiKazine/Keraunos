import Foundation

/// All failures surfaced to the UI. Python exceptions are mapped to these at the
/// extraction boundary so nothing above the boundary sees a Python object.
public enum KeraunosError: Error, Equatable {
    case unsupported
    case needsFfmpeg
    case requiresAuth
    case network
    case runtime(detail: String)
    case cancelled
    case mergeFailed
    case timedOut
}

public extension KeraunosError {
    /// Maps an `error_kind` string emitted by the Python extraction module.
    init(errorKind: String, detail: String = "") {
        switch errorKind {
        case "unsupported":   self = .unsupported
        case "needs_ffmpeg":  self = .needsFfmpeg
        case "requires_auth": self = .requiresAuth
        case "network":       self = .network
        default:              self = .runtime(detail: detail.isEmpty ? errorKind : detail)
        }
    }
}

extension KeraunosError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupported:        return "This link isn't supported."
        case .needsFfmpeg:        return "This video needs format-merging support, coming in a later version."
        case .requiresAuth:       return "This video requires sign-in (cookies), which isn't supported yet."
        case .network:            return "Download failed — check your connection."
        case .runtime(let detail): return "Something went wrong: \(detail)"
        case .cancelled:          return "Download cancelled."
        case .mergeFailed:        return "Couldn't combine the video and audio tracks."
        case .timedOut:           return "Extraction took too long and was stopped."
        }
    }
}
