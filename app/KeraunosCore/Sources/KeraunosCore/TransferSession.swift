import Foundation

/// The task-based session API the `TransferCoordinator` drives, seamed so the engine is
/// testable without a real background `URLSession`. The app target (Phase 3) provides a
/// concrete implementation wrapping `URLSession(configuration: .background(withIdentifier:))`;
/// tests provide a scripted mock. All methods are `async` because the concrete type is an
/// actor around a session it must not race.
public protocol TransferSession: Sendable {
    /// Starts a download task for `request` and returns the assigned task identifier.
    func startDownloadTask(for request: URLRequest) async throws -> Int
    /// Starts a download task from previously-captured resume data (single-shot resume).
    func startDownloadTask(withResumeData resumeData: Data) async throws -> Int
    /// Cancels the task, returning resume data if the session can produce it (single-shot).
    @discardableResult func cancelTask(_ identifier: Int) async -> Data?
    /// Identifiers of tasks currently in flight — used for relaunch reassociation.
    func liveTaskIdentifiers() async -> [Int]
}
