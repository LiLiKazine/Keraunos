import Foundation

/// A point-in-time view of one job's transfer progress, published on the `TransferProgress`
/// bus. `fraction` is derived (received / total), nil when the total is unknown — the UI
/// then shows an indeterminate bar (see the spec's "Waiting (background)" / early-adaptive
/// cases). `state` mirrors the durable `JobState` so the bus alone can drive most of the row.
public struct ProgressSnapshot: Sendable, Equatable {
    public let state: JobState
    public let receivedBytes: Int64
    public let totalBytes: Int64?

    public init(state: JobState, receivedBytes: Int64, totalBytes: Int64?) {
        self.state = state
        self.receivedBytes = receivedBytes
        self.totalBytes = totalBytes
    }

    /// 0...1 whole-file fraction, or nil when the total isn't known yet (or is zero).
    public var fraction: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return Double(receivedBytes) / Double(totalBytes)
    }
}

/// The progress event bus. A Core `actor` holding the live `[JobID: ProgressSnapshot]` map,
/// written by the coordinator/finalizer (state changes) and the session delegate (byte
/// deltas), read by the UI via `updates()`. Because it is reconstructed from the persisted
/// store + live task reassociation, the UI reconnects after relaunch with no surviving
/// closure. (`updates()` is added in Task A2.)
public actor TransferProgress {
    private var snapshots: [UUID: ProgressSnapshot] = [:]
    private var continuations: [UUID: AsyncStream<[UUID: ProgressSnapshot]>.Continuation] = [:]

    public init() {}

    public func current() -> [UUID: ProgressSnapshot] { snapshots }

    public func snapshot(for id: UUID) -> ProgressSnapshot? { snapshots[id] }

    public func set(_ snapshot: ProgressSnapshot, for id: UUID) {
        snapshots[id] = snapshot
        broadcast()
    }

    public func remove(_ id: UUID) {
        snapshots[id] = nil
        broadcast()
    }

    /// A stream of the full snapshot map: the current value immediately, then a fresh map on
    /// every `set`/`remove`. Each caller gets an independent stream; the registration is torn
    /// down when the consumer stops iterating.
    public func updates() -> AsyncStream<[UUID: ProgressSnapshot]> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[token] = continuation
            continuation.yield(snapshots)               // seed with the current state
            continuation.onTermination = { [weak self] _ in
                Task { await self?.dropContinuation(token) }
            }
        }
    }

    private func dropContinuation(_ token: UUID) {
        continuations[token] = nil
    }

    private func broadcast() {
        for continuation in continuations.values { continuation.yield(snapshots) }
    }
}
