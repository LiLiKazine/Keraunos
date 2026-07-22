import Foundation
import KeraunosCore

/// A scriptable `TransferSession` double. It hands out monotonic task identifiers, records
/// every started request (so a test can read the `Range` header the coordinator built), and
/// keeps a mutable `live` set a test can mutate to simulate tasks the OS killed while the
/// app was suspended. Events are delivered by the test calling the coordinator's ingress
/// methods directly with an id this session handed out.
actor ScriptedTransferSession: TransferSession {
    private(set) var started: [(id: Int, request: URLRequest)] = []
    private(set) var startedResumeData: [(id: Int, data: Data)] = []
    private(set) var cancelled: [Int] = []
    var live: Set<Int> = []
    var resumeDataOnCancel: Data?
    private var nextID = 0

    func startDownloadTask(for request: URLRequest) async throws -> Int {
        nextID += 1
        started.append((nextID, request))
        live.insert(nextID)
        return nextID
    }

    func startDownloadTask(withResumeData resumeData: Data) async throws -> Int {
        nextID += 1
        startedResumeData.append((nextID, resumeData))
        live.insert(nextID)
        return nextID
    }

    @discardableResult
    func cancelTask(_ identifier: Int) async -> Data? {
        cancelled.append(identifier)
        live.remove(identifier)
        return resumeDataOnCancel
    }

    func liveTaskIdentifiers() async -> [Int] { Array(live) }

    /// The `Range` header of the most recently started (ranged) task, for assertions.
    func lastRange() -> String? { started.last?.request.value(forHTTPHeaderField: "Range") }
    func setLive(_ ids: Set<Int>) { live = ids }
}
