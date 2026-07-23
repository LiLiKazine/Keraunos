import Foundation

/// A single accumulating download part on disk, with the crash-consistency discipline the
/// chunked resume path relies on: `append` flushes to disk (fsync) before returning, so the
/// file is never shorter than a reported length; `truncate(to:)` drops any tail written but
/// not yet recorded before a crash, so a resume from the persisted offset can't double-append.
public struct PartFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// Current on-disk byte length (0 if the file is absent). Read fresh each call.
    public func length() -> Int64 {
        // An absent/unreadable file legitimately reads as length 0 (not yet created).
        let attrs: [FileAttributeKey: Any]
        do {
            attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch {
            return 0
        }
        return (attrs[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Appends `data`, flushes it to stable storage, and returns the new length.
    @discardableResult
    public func append(_ data: Data) throws -> Int64 {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { closeQuietly(handle) }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()   // fsync — bytes are durable before we return the length
        return length()
    }

    /// Truncates the file down to `offset` bytes (creating an empty file if absent).
    public func truncate(to offset: Int64) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { closeQuietly(handle) }
        try handle.truncate(atOffset: UInt64(offset))
        try handle.synchronize()
    }

    /// Closes a handle whose bytes are already `synchronize()`d — a close failure at this
    /// point cannot lose data, so it is deliberately ignored (in `defer`, can't propagate).
    private func closeQuietly(_ handle: FileHandle) {
        do { try handle.close() } catch { /* durable already; nothing to recover */ }
    }
}
