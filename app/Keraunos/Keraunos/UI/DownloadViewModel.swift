import Foundation
import Observation
import KeraunosCore

@Observable
final class DownloadViewModel {   // main-actor by default (app target)
    var urlText: String = ""
    private(set) var isWorking = false
    private(set) var statusText: String?
    private(set) var errorMessage: String?
    private(set) var requiresSignIn = false
    private(set) var signInURL: URL?
    private(set) var lastSavedName: String?
    private(set) var savedFiles: [URL] = []

    private let extractor: any MediaExtracting
    private let assembler: MediaAssembler
    private let store: DownloadStore

    init(extractor: any MediaExtracting, assembler: MediaAssembler, store: DownloadStore) {
        self.extractor = extractor
        self.assembler = assembler
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
        requiresSignIn = false
        signInURL = nil
        statusText = "Resolving…"
        defer { isWorking = false; statusText = nil }
        do {
            let media = try await extractor.resolve(url)
            let saved = try await assembler.assemble(media, into: store) { phase in
                self.statusText = Self.label(for: phase)
            }
            lastSavedName = saved.lastPathComponent
            savedFiles = store.savedFiles()
        } catch let error as KeraunosError {
            errorMessage = error.errorDescription
            if error == .requiresAuth {
                requiresSignIn = true
                signInURL = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            errorMessage = KeraunosError.runtime(detail: error.localizedDescription).errorDescription
        }
    }

    func retry() async { await startDownload() }

    private static func label(for phase: MediaAssembler.Phase) -> String {
        switch phase {
        case .downloading:      return "Downloading…"
        case .downloadingVideo: return "Downloading video…"
        case .downloadingAudio: return "Downloading audio…"
        case .merging:          return "Combining…"
        }
    }
}
