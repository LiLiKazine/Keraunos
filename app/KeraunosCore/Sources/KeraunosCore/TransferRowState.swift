import Foundation

/// The nine presentation states of a queue row (from the design's `TransferStates.dc.html`),
/// derived purely from a `TransferJob`. Kept in Core (no SwiftUI) so the mapping is
/// `swift test`-able and stays the single source of truth for JobState → row.
public enum TransferRowState: Sendable, Equatable {
    case downloading         // active, receiving bytes
    case paused              // user-paused
    case queued              // waiting its turn
    case waitingBackground   // .downloading but no in-flight task (iOS-deferred / between resumes)
    case merging             // readyToMerge or merging — automatic
    case refreshing          // .needsRefresh, anonymous — silent re-extraction, automatic
    case needsSignIn         // .needsRefresh, credentialed — needs foreground re-auth
    case failed(FailureReason)
}

public extension TransferJob {
    /// The row this job renders as, or nil if it should not appear in the queue
    /// (`.completed`/`.cancelled` move to Library / disappear).
    var rowState: TransferRowState? {
        switch state {
        case .queued:
            return .queued
        case .downloading:
            let hasLiveTask = tracks.first(where: { track in
                guard let total = track.totalBytes else { return true }
                return track.bytesWritten < total
            })?.taskIdentifier != nil
            return hasLiveTask ? .downloading : .waitingBackground
        case .paused:
            return .paused
        case .needsRefresh:
            return credentialRef == nil ? .refreshing : .needsSignIn
        case .readyToMerge, .merging:
            return .merging
        case .failed(let reason):
            return .failed(reason)
        case .completed, .cancelled:
            return nil
        }
    }
}
