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
    /// True when the last failure was transient, so a plain "Try again" may succeed.
    private(set) var canRetry = false
    private(set) var lastSavedName: String?
    private(set) var savedFiles: [URL] = []
    /// 0...1 transfer progress while downloading; nil when not downloading or size unknown.
    private(set) var downloadProgress: Double?

    /// The in-flight download task, retained so the UI can cancel it. Readable in tests.
    private(set) var currentTask: Task<Void, Never>?

    private let extractor: any MediaExtracting
    private let assembler: MediaAssembler
    private let store: DownloadStore
    private let failureLog: FailureLog

    init(extractor: any MediaExtracting, assembler: MediaAssembler, store: DownloadStore,
         failureLog: FailureLog? = nil) {
        self.extractor = extractor
        self.assembler = assembler
        self.store = store
        self.failureLog = failureLog ?? FailureLog(directory: store.directory)
        self.savedFiles = store.savedFiles()
        self.failureLogURL = self.failureLog.hasEntries ? self.failureLog.fileURL : nil
    }

    /// Local failure log file, if any failures have been recorded (for diagnostics export).
    /// A stored property (not computed off the filesystem) so SwiftUI observes changes.
    private(set) var failureLogURL: URL?

    /// Clears the local failure log and hides the diagnostics affordance.
    func clearFailureLog() {
        failureLog.clear()
        failureLogURL = nil
    }

    func startDownload(isAutoRetry: Bool = false) async {
        guard let url = URLNormalizer.normalize(urlText) else {
            errorMessage = "Enter a valid http(s) link."
            return
        }
        isWorking = true
        errorMessage = nil
        requiresSignIn = false
        signInURL = nil
        canRetry = false
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
            // One transparent retry for a transient cold-start failure: YouTube's first
            // run mints a PoT and solves n/sig by running yt-dlp's EJS bundle in
            // JavaScriptCore — heavy enough to occasionally exceed the watchdog (timeout)
            // or blip the network. The warm retry runs against cached player/nsig and a
            // minted token, so it's fast. Done before surfacing/logging, so it's invisible.
            if (error == .extractNetwork || error == .timedOut), !isAutoRetry {
                statusText = "Retrying…"
                await startDownload(isAutoRetry: true)
                return
            }
            errorMessage = error.errorDescription
            canRetry = error.isRetryable
            let detail = { if case .runtime(let d) = error { return d } else { return "" } }()
            failureLog.record(url: url.absoluteString, errorKind: error.kind, detail: detail, date: Date())
            failureLogURL = failureLog.fileURL
            if error == .requiresAuth {
                requiresSignIn = true
                signInURL = url
            }
        } catch {
            errorMessage = KeraunosError.runtime(detail: error.localizedDescription).errorDescription
            canRetry = true   // unknown runtime fault — a retry may clear it
            failureLog.record(url: url.absoluteString, errorKind: "runtime",
                              detail: error.localizedDescription, date: Date())
            failureLogURL = failureLog.fileURL
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

    /// Handles a URL the app was opened with (deep link / share / Shortcut): if it
    /// resolves to a media link, fill the field and start downloading; ignore otherwise.
    func openIncoming(_ url: URL) {
        guard let target = IncomingURL.target(from: url) else { return }
        urlText = target.absoluteString
        start()
    }

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
