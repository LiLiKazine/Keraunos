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
    /// 0...1 transfer progress while downloading; nil when not downloading or size unknown.
    private(set) var downloadProgress: Double?

    /// The in-flight download task, retained so the UI can cancel it. Readable in tests.
    private(set) var currentTask: Task<Void, Never>?

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
        guard let url = URLNormalizer.normalize(urlText) else {
            errorMessage = "Enter a valid http(s) link."
            return
        }
        isWorking = true
        errorMessage = nil
        requiresSignIn = false
        signInURL = nil
        downloadProgress = nil
        statusText = "Resolving…"
        defer { isWorking = false; statusText = nil; downloadProgress = nil }
        do {
            let media = try await extractor.resolve(url)
            let saved = try await assembler.assemble(media, into: store, onPhase: { phase in
                self.statusText = Self.label(for: phase)
            }, onProgress: { fraction in
                // The download delegate fires off the main actor; hop back to mutate state.
                Task { @MainActor in self.downloadProgress = fraction }
            })
            lastSavedName = saved.lastPathComponent
            savedFiles = store.savedFiles()
        } catch is CancellationError {
            // User tapped Cancel — leave the screen clean, surface nothing.
        } catch let error as KeraunosError {
            guard error != .cancelled else { return }   // also a user-initiated cancel
            errorMessage = error.errorDescription
            if error == .requiresAuth {
                requiresSignIn = true
                signInURL = url
            }
        } catch {
            errorMessage = KeraunosError.runtime(detail: error.localizedDescription).errorDescription
        }
    }

    /// Starts a download as a cancellable task (the UI entry point). Any prior task is
    /// cancelled first so a re-tap can't run two downloads at once.
    func start() {
        currentTask?.cancel()
        currentTask = Task { await startDownload() }
    }

    /// Cancels the in-flight download; `startDownload`'s catch treats it as non-error.
    func cancel() { currentTask?.cancel() }

    func retry() async { await startDownload() }

    /// Human-readable size of a finished download (e.g. "12.4 MB"), or nil if unreadable.
    func fileSizeText(_ file: URL) -> String? {
        store.fileSize(file).map { $0.formatted(.byteCount(style: .file)) }
    }

    /// Removes a finished download from disk and refreshes the list. A failed delete is
    /// surfaced inline rather than thrown — it shouldn't tear down the screen.
    func deleteDownload(_ file: URL) {
        do {
            try store.delete(file)
            savedFiles = store.savedFiles()
        } catch {
            errorMessage = "Couldn't delete \(file.lastPathComponent)."
        }
    }

    private static func label(for phase: MediaAssembler.Phase) -> String {
        switch phase {
        case .downloading:      return "Downloading…"
        case .downloadingVideo: return "Downloading video…"
        case .downloadingAudio: return "Downloading audio…"
        case .merging:          return "Combining…"
        }
    }
}
