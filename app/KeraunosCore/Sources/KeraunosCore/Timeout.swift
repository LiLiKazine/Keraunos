import Foundation

/// Runs `operation` with an overall wall-clock bound. Returns its value if it
/// finishes within `duration`; otherwise throws `KeraunosError.timedOut`. The
/// operation and a sleeping timer race in a task group — whichever finishes first
/// wins and the loser is cancelled.
///
/// Note: cancelling the operation does not interrupt a synchronous blocking call
/// that has no cancellation point (e.g. a CPython C call); such work keeps running
/// until it returns. Callers that wrap blocking work must run it on a dedicated
/// executor so an orphaned call does not occupy a shared thread — see PythonExtractor.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw KeraunosError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw KeraunosError.timedOut
        }
        return result
    }
}
