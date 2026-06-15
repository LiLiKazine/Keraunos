import Foundation
import Observation
import KeraunosCore

@Observable
final class DownloadViewModel {   // main-actor by default (app target)
    var urlText: String = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var lastSavedName: String?
    private(set) var savedFiles: [URL] = []

    private let extractor: any MediaExtracting
    private let downloader: any FileDownloading
    private let store: DownloadStore

    init(extractor: any MediaExtracting, downloader: any FileDownloading, store: DownloadStore) {
        self.extractor = extractor
        self.downloader = downloader
        self.store = store
        self.savedFiles = store.savedFiles()
    }

    func startDownload() async {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "http" || url.scheme == "https" else {
            errorMessage = "Enter a valid http(s) link."
            return
        }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            let media = try await extractor.resolve(url)
            let saved = try await downloader.download(media, to: store.directory)
            lastSavedName = saved.lastPathComponent
            savedFiles = store.savedFiles()
        } catch let error as KeraunosError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = KeraunosError.runtime(detail: error.localizedDescription).errorDescription
        }
    }
}
