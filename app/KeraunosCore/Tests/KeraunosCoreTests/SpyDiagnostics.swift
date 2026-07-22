import Foundation
import KeraunosCore

/// Records everything sent to it so a test can assert a failure was actually surfaced
/// (rather than silently swallowed).
final class SpyDiagnostics: TransferDiagnostics, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [(kind: String, detail: String)] = []

    var entries: [(kind: String, detail: String)] {
        lock.lock(); defer { lock.unlock() }
        return _entries
    }
    var kinds: [String] { entries.map(\.kind) }

    func record(kind: String, detail: String) {
        lock.lock(); defer { lock.unlock() }
        _entries.append((kind, detail))
    }
}
