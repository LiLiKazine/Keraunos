import Foundation
import Observation
import KeraunosCore

/// Seam over `TransferEngine.enqueue(_:)` so `DownloadViewModel` can be driven by a spy in
/// tests instead of touching the real engine's filesystem/URLSession-backed singleton.
protocol JobEnqueuing {
    func enqueue(_ job: TransferJob) async
}
extension TransferEngine: JobEnqueuing {}

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
    private(set) var savedFiles: [URL] = []
    /// Message from the last Save-to-Photos attempt; drives a one-off alert. nil when idle.
    private(set) var saveMessage: String?

    /// Non-nil when the picker is showing: the resolutions available for the pasted link.
    private(set) var pendingOptions: [FormatOption]?
    /// The URL the pending options were listed for; resolved in `selectFormat`.
    private var pendingURL: URL?

    /// The in-flight resolve/pick task, retained so the UI can cancel it. Readable in tests.
    private(set) var currentTask: Task<Void, Never>?

    private let extractor: any MediaExtracting
    private let store: DownloadStore
    private let failureLog: FailureLog
    private let photoSaver: (any PhotoSaving)?
    private let preferences: Preferences
    private let enqueuer: any JobEnqueuing

    init(extractor: any MediaExtracting, store: DownloadStore,
         failureLog: FailureLog? = nil, photoSaver: (any PhotoSaving)? = nil,
         preferences: Preferences = Preferences(), enqueuer: any JobEnqueuing = TransferEngine.shared) {
        self.extractor = extractor
        self.store = store
        self.failureLog = failureLog ?? FailureLog(directory: store.directory)
        self.photoSaver = photoSaver
        self.preferences = preferences
        self.enqueuer = enqueuer
        self.savedFiles = store.savedFiles()
        self.failureLogURL = self.failureLog.hasEntries ? self.failureLog.fileURL : nil
    }

    /// The stream to download when the user hasn't chosen: the highest muxed (non-adaptive)
    /// resolution, or the highest overall if every option needs a separate audio track.
    static func bestOption(_ options: [FormatOption]) -> FormatOption? {
        let muxed = options.filter { !$0.isAdaptive }
        return (muxed.isEmpty ? options : muxed).max { $0.height < $1.height }
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
        beginWork()
        defer { endWork() }
        do {
            switch try await extractor.listFormats(url) {
            case .ready(let media):
                let isAdaptive: Bool
                switch media.kind {
                case .progressive: isAdaptive = false
                case .adaptive: isAdaptive = true
                }
                await enqueue(media, from: url, selection: FormatSelection(formatID: "", height: nil, isAdaptive: isAdaptive))
            case .choices(let options):
                // Honor the "highest available" preference by skipping the picker entirely.
                if preferences.defaultQuality == .highest, let best = Self.bestOption(options) {
                    let media = try await extractor.resolve(url, option: best)
                    await enqueue(media, from: url, selection: selection(from: best))
                } else {
                    pendingOptions = options
                    pendingURL = url
                }
            }
        } catch {
            await handleFailure(error, url: url, isAutoRetry: isAutoRetry) {
                await self.startDownload(isAutoRetry: true)
            }
        }
    }

    /// Downloads the user's chosen resolution. Cancels any prior task first.
    func selectFormat(_ option: FormatOption) {
        guard let url = pendingURL else { return }
        pendingOptions = nil
        pendingURL = nil
        currentTask?.cancel()
        currentTask = Task { await self.resolveSelected(url: url, option: option) }
    }

    /// Dismisses the picker without downloading.
    func cancelSelection() {
        pendingOptions = nil
        pendingURL = nil
    }

    private func resolveSelected(url: URL, option: FormatOption, isAutoRetry: Bool = false) async {
        beginWork()
        defer { endWork() }
        do {
            let media = try await extractor.resolve(url, option: option)
            await enqueue(media, from: url, selection: selection(from: option))
        } catch {
            await handleFailure(error, url: url, isAutoRetry: isAutoRetry) {
                await self.resolveSelected(url: url, option: option, isAutoRetry: true)
            }
        }
    }

    private func beginWork() {
        isWorking = true
        errorMessage = nil
        requiresSignIn = false
        signInURL = nil
        canRetry = false
        statusText = "Resolving…"
    }

    private func endWork() {
        isWorking = false
        statusText = nil
    }

    /// Maps a picked format to the durable `FormatSelection` persisted on the job, so a
    /// `.needsRefresh` re-extraction re-picks the SAME format rather than showing the picker
    /// again.
    private func selection(from option: FormatOption) -> FormatSelection {
        FormatSelection(formatID: option.formatID, height: option.height, isAdaptive: option.isAdaptive)
    }

    /// Enqueues a resolved media onto the background engine instead of downloading in the
    /// foreground. Transfer, merge, Photos-save, and Library-landing are then owned by the
    /// engine + queue, not this view model.
    private func enqueue(_ media: ResolvedMedia, from url: URL, selection: FormatSelection) async {
        let id = UUID()
        let job = TransferJobFactory.make(
            id: id, from: media, sourcePageURL: url, selection: selection,
            autoSaveToPhotos: preferences.autoSaveToPhotos, credentialRef: nil,
            createdAt: Date(), partPrefix: id.uuidString)
        await enqueuer.enqueue(job)
    }

    /// Shared failure handling for both phases: transparent one-shot auto-retry for
    /// transient faults (via `retry`), else surface/log the error and route auth walls
    /// to the Sign-In flow.
    private func handleFailure(_ error: Error, url: URL, isAutoRetry: Bool,
                               retry: () async -> Void) async {
        switch error {
        case is CancellationError:
            return
        case let error as KeraunosError:
            guard error != .cancelled else { return }
            if error.isAutoRetryable, !isAutoRetry {
                statusText = "Retrying…"
                await retry()
                return
            }
            errorMessage = error.errorDescription
            canRetry = error.isRetryable
            let detail = { if case .runtime(let d) = error { return d } else { return "" } }()
            failureLog.record(url: url.absoluteString, errorKind: error.kind, detail: detail, date: Date())
            failureLogURL = failureLog.fileURL
            if error == .requiresAuth || error == .restrictedOrEmpty {
                requiresSignIn = true
                signInURL = URLNormalizer.origin(of: url) ?? url
            }
        default:
            errorMessage = KeraunosError.runtime(detail: error.localizedDescription).errorDescription
            canRetry = true
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

    /// Short saved date (e.g. "Jul 12") from the file's modification date, or nil.
    func savedDateText(_ file: URL) -> String? {
        guard let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else { return nil }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    /// Uppercased container type for a file (e.g. "MP4"), for a metadata chip.
    func fileTypeLabel(_ file: URL) -> String { file.pathExtension.uppercased() }

    /// A metadata subtitle from what we can read off disk: size, then saved date.
    func librarySubtitle(_ file: URL) -> String {
        [fileSizeText(file), savedDateText(file)].compactMap { $0 }.joined(separator: " · ")
    }

    /// Total on-device size of all finished downloads, formatted (e.g. "3.4 GB").
    var totalDownloadsSizeText: String {
        savedFiles.reduce(Int64(0)) { $0 + (store.fileSize($1) ?? 0) }
            .formatted(.byteCount(style: .file))
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

    /// Whether the Downloads UI should offer "Save to Photos" for this file.
    func canSaveToPhotos(_ file: URL) -> Bool { PhotosCompatibility.canSave(file) }

    /// Saves a finished download to Photos and reports the outcome via `saveMessage`.
    func saveToPhotos(_ file: URL) async {
        guard canSaveToPhotos(file), let photoSaver else { return }
        switch await photoSaver.save(file) {
        case .saved:            saveMessage = "Saved to Photos."
        case .permissionDenied: saveMessage = "Allow Photos access in Settings to save videos."
        case .failed:           saveMessage = "Couldn't save to Photos."
        }
    }

    /// Clears the Save-to-Photos alert message.
    func dismissSaveMessage() { saveMessage = nil }
}
