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
            var request = URLRequest(url: track.url)
            for (field, value) in track.httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
            let (tempURL, response) = try await session.download(
                for: request, delegate: DownloadProgressDelegate(onProgress: onProgress))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw KeraunosError.downloadNetwork
            }
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
