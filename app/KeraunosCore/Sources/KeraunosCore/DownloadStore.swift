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

    /// A destination URL in the store's directory that doesn't collide with an existing
    /// file: "clip.mp4" → "clip (2).mp4" → "clip (3).mp4", so a second download of a
    /// same-titled video never silently overwrites the first.
    public func uniqueDestination(for filename: String) -> URL {
        let safe = Self.sanitizedFilename(filename)
        let ext = (safe as NSString).pathExtension
        let base = (safe as NSString).deletingPathExtension
        var candidate = directory.appendingPathComponent(safe)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            candidate = directory.appendingPathComponent(name)
            n += 1
        }
        return candidate
    }

    /// Collapses a yt-dlp-suggested filename to a single safe path component: path
    /// separators / colons / control chars become "_" (so "AC/DC.mp4" can't become a
    /// subdirectory and "../x" can't escape the store), with a "video" fallback for
    /// names that sanitize to empty or all-dots.
    static func sanitizedFilename(_ raw: String) -> String {
        let cleaned = String(raw.map { "/\\:\u{0}".contains($0) ? "_" : $0 })
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = (cleaned as NSString).deletingPathExtension
        guard !base.isEmpty, !base.allSatisfy({ $0 == "." }) else {
            let ext = (cleaned as NSString).pathExtension
            return ext.isEmpty ? "video" : "video.\(ext)"
        }
        return cleaned
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
