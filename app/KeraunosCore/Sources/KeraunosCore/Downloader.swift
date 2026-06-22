import Foundation

public protocol FileDownloading: Sendable {
    /// Downloads one track to `destination` (a full file URL), replacing any existing file.
    func download(_ track: MediaTrack, to destination: URL) async throws
}

/// Downloads a single track with URLSession and moves it into place.
public struct Downloader: FileDownloading {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ track: MediaTrack, to destination: URL) async throws {
        do {
            var request = URLRequest(url: track.url)
            for (field, value) in track.httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
            let (tempURL, response) = try await session.download(for: request)
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
