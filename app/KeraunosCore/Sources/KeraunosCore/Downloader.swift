import Foundation

public protocol FileDownloading: Sendable {
    /// Downloads one track to `destination` (a full file URL), replacing any existing
    /// file. `onProgress` reports completion fraction (0...1) when the total size is
    /// known; it may not be called at all for length-unknown responses.
    func download(_ track: MediaTrack, to destination: URL,
                  onProgress: @escaping @Sendable (Double) -> Void) async throws
}

public extension FileDownloading {
    /// Progress-free convenience for callers that don't display it.
    func download(_ track: MediaTrack, to destination: URL) async throws {
        try await download(track, to: destination, onProgress: { _ in })
    }
}

/// Downloads a single track with URLSession and moves it into place. A task-specific
/// delegate surfaces byte progress while keeping the efficient async download-task
/// transfer (and Task-cancellation propagation). Background/resume is out of scope here.
public struct Downloader: FileDownloading {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ track: MediaTrack, to destination: URL,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            if let chunk = track.chunkSize, chunk > 0 {
                try await downloadChunked(track, chunkSize: chunk, to: destination, onProgress: onProgress)
                return
            }
            var request = URLRequest(url: track.url)
            for (field, value) in track.httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
            let (tempURL, response) = try await session.download(
                for: request, delegate: DownloadProgressDelegate(onProgress: onProgress))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw KeraunosError.downloadNetwork
            }
            // A real media file is never 0 bytes; an empty/truncated body is a failed
            // transfer, not a download — reject it (retryable) rather than save a dud.
            let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { throw KeraunosError.downloadNetwork }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch let error as KeraunosError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw KeraunosError.cancelled
        } catch is CancellationError {
            throw KeraunosError.cancelled
        } catch {
            throw KeraunosError.downloadNetwork
        }
    }

    /// Downloads a track in sequential HTTP Range chunks (for hosts like googlevideo that
    /// throttle unranged full-file GETs), assembling into a temp file then moving into place.
    /// A `200` response means the server ignored `Range` — that body IS the whole file.
    private func downloadChunked(_ track: MediaTrack, chunkSize: Int, to destination: URL,
                                 onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw KeraunosError.downloadNetwork
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        var closed = false
        defer { if !closed { try? handle.close() } }

        var offset = 0
        var total: Int64?
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: track.url)
            for (field, value) in track.httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
            request.setValue("bytes=\(offset)-\(offset + chunkSize - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KeraunosError.downloadNetwork }
            if http.statusCode == 200 {          // server ignored Range → whole file
                // Only valid as "whole file" on the very first request; a 200 after
                // prior 206s already wrote bytes would corrupt the file if appended.
                guard offset == 0 else { throw KeraunosError.downloadNetwork }
                try handle.write(contentsOf: data)
                offset += data.count
                onProgress(1.0)
                break
            } else if http.statusCode == 206 {
                if total == nil { total = Self.totalBytes(fromContentRange: http) }
                try handle.write(contentsOf: data)
                offset += data.count
                if let t = total, t > 0 { onProgress(min(1.0, Double(offset) / Double(t))) }
                // A chunk shorter than requested means the resource ended — needed to
                // terminate when the server never reports a total (Content-Range: */*).
                if data.isEmpty || data.count < chunkSize { break }
                if let t = total, Int64(offset) >= t { break }
            } else {
                throw KeraunosError.downloadNetwork
            }
        }

        try handle.close(); closed = true
        let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw KeraunosError.downloadNetwork
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Parses the total size out of a `Content-Range: bytes a-b/total` header. Returns nil
    /// for an unknown total (`.../*`), in which case progress isn't reported but assembly
    /// still terminates on a short/empty chunk.
    private static func totalBytes(fromContentRange http: HTTPURLResponse) -> Int64? {
        guard let value = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}

/// Forwards URLSession download progress as a 0...1 fraction. Ignores callbacks whose
/// expected total is unknown (`<= 0`) so we never report a bogus or negative fraction.
final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    // The async download(for:delegate:) handles file completion itself; this delegate
    // requirement is unused but must exist to conform to URLSessionDownloadDelegate.
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
