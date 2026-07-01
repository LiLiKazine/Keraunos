import Foundation

/// Outcome of a save-to-Photos attempt; the view model maps it to a user-facing message.
enum PhotoSaveResult {
    case saved
    case permissionDenied
    case failed
}

/// Saves a finished download into the Photos library. Injected into `DownloadViewModel`
/// so the result→message mapping is testable with a mock; the real Photos call is
/// device-only. Not `Sendable` — the view model and the saver are both MainActor.
protocol PhotoSaving {
    func save(_ fileURL: URL) async -> PhotoSaveResult
}
