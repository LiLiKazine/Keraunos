import Foundation

public protocol FileDownloading: Sendable {
    func download(_ media: ResolvedMedia, to destinationDirectory: URL) async throws -> URL
}

/// Downloads a resolved media file with URLSession and moves it into place.
/// Milestone 1: simple await-to-completion. Background sessions come later.
public struct Downloader: FileDownloading {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ media: ResolvedMedia, to destinationDirectory: URL) async throws -> URL {
        do {
            let (tempURL, response) = try await session.download(from: media.directURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw KeraunosError.network
            }
            let destination = destinationDirectory.appendingPathComponent(media.suggestedFilename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            return destination
        } catch let error as KeraunosError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw KeraunosError.cancelled
        } catch is CancellationError {
            throw KeraunosError.cancelled
        } catch {
            throw KeraunosError.network
        }
    }
}
