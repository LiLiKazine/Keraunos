import Foundation

/// Owns the download destination and lists finished downloads.
public struct DownloadStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public func savedFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "mp4" }
            // Newest first — the file just downloaded belongs at the top of the list.
            .sorted { Self.modifiedAt($0) > Self.modifiedAt($1) }
    }

    /// Size of a downloaded file in bytes, or nil if it's missing/unreadable.
    public func fileSize(_ file: URL) -> Int64? {
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return Int64(size)
    }

    private static func modifiedAt(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    /// Removes a downloaded file. Absent files are treated as already-deleted (no throw)
    /// so clearing a stale list row never surfaces an error; other I/O failures propagate.
    public func delete(_ file: URL) throws {
        do {
            try FileManager.default.removeItem(at: file)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        }
    }
}
