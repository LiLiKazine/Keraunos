import Foundation
import UIKit
import KeraunosCore

/// Adapts the on-device `FailureLog` (append-only, redacted, UI-visible) to the transfer
/// stack's `TransferDiagnostics` seam, so non-fatal failures deep in the engine are recorded
/// where the owner can inspect them.
struct FailureLogDiagnostics: TransferDiagnostics {
    let log: FailureLog
    func record(kind: String, detail: String) {
        log.record(url: "", errorKind: kind, detail: detail, date: Date())
    }
}

/// Composition root for the background-transfer stack and owner of the launch sequence. A
/// process-wide singleton because the background `URLSession` must be unique per identifier.
///
/// The live download UI still uses the existing foreground path; this engine is available
/// infrastructure the queue UI (Phase 6) will switch `start()` over to.
@MainActor
final class TransferEngine {
    static let shared = TransferEngine()

    let store: TransferJobStore
    let service: BackgroundTransferService
    let coordinator: TransferCoordinator
    let finalizer: TransferFinalizer
    let progress: TransferProgress

    private let downloadStore = DownloadStore()
    private let photoSaver: any PhotoSaving = PhotoLibrarySaver()
    private let diagnostics: any TransferDiagnostics

    private var didStart = false
    /// The OS completion handler from `handleEventsForBackgroundURLSession`, held on the main
    /// actor and fired once the session reports all events drained.
    private var backgroundCompletion: (() -> Void)?
    /// Live assertion keeping the app awake across a finalize/merge pass.
    private var mergeAssertion: UIBackgroundTaskIdentifier = .invalid

    /// Titles of jobs that landed in Library since the UI last consumed them (drives the
    /// coalescing "Saved to Library" toast). The VM reads and clears this.
    private(set) var recentlySavedTitles: [String] = []

    func consumeRecentlySaved() -> [String] {
        let titles = recentlySavedTitles
        recentlySavedTitles = []
        return titles
    }

    private init() {
        // 1. Load the durable store synchronously (it is tiny) so the job map exists before
        //    any background event can arrive.
        let base = TransferJobStore.defaultDirectory
        let diagnostics = FailureLogDiagnostics(log: FailureLog(directory: base))
        self.diagnostics = diagnostics
        // A store that can't even be created is unrecoverable — surface it loudly rather than
        // limp along; the app cannot run background transfers without it.
        store = Self.makeStore(directory: base, diagnostics: diagnostics)
        service = BackgroundTransferService(
            stagingDirectory: base.appendingPathComponent("staging", isDirectory: true),
            diagnostics: diagnostics)
        progress = TransferProgress()
        coordinator = TransferCoordinator(store: store, session: service,
                                          diagnostics: diagnostics, progress: progress)
        finalizer = TransferFinalizer(store: store, merger: AVFoundationMerger(),
                                      downloadStore: downloadStore, diagnostics: diagnostics,
                                      progress: progress)
    }

    private static func makeStore(directory: URL, diagnostics: any TransferDiagnostics) -> TransferJobStore {
        do {
            return try TransferJobStore(directory: directory, diagnostics: diagnostics)
        } catch {
            fatalError("TransferEngine: cannot create the transfer store at \(directory): \(error)")
        }
    }

    /// The launch sequence, in the mandated order (load store → wire delegate → create
    /// session). Idempotent — safe to call from both `onAppear` and the app-delegate hook.
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        // 2. wire the delegate target (+ the "events drained" signal — a @Sendable closure
        //    that hops to the main actor to fire the OS completion handler we hold there).
        service.attach(coordinator: coordinator,
                       onFinishEvents: { Task { @MainActor in TransferEngine.shared.fireBackgroundCompletion() } })
        service.createSession()                     // 3. create session — opens the floodgates
        Task {
            await coordinator.reassociateAndResume()   // rebind live tasks, resume vanished ones
            await reconcileOrphans()                    // sweep parts with no owning job
            await runFinalizePass()                     // pick up any .readyToMerge from last run
        }
    }

    /// Called by `AppDelegate` when iOS relaunches to finish background events. The handler
    /// stays on the main actor (never crosses into the nonisolated service).
    func handleBackgroundEvents(completion: @escaping () -> Void) {
        startIfNeeded()
        backgroundCompletion = completion
    }

    /// Called on every scene-phase activation (cold launch and every subsequent foreground).
    /// First activation runs the full launch sequence via `startIfNeeded()`. Every later
    /// activation re-kicks any tasks the OS silently dropped and finalizes jobs the
    /// coordinator advanced to `.readyToMerge` while the app was backgrounded — otherwise
    /// they'd sit on "Merging…" until a cold relaunch instead of landing in Library.
    func handleForegroundActivation() {
        guard didStart else {
            startIfNeeded()
            return
        }
        Task {
            await coordinator.reassociateAndResume()
            await runFinalizePass()
        }
    }

    /// Invokes and clears the stored OS completion handler once events have drained.
    func fireBackgroundCompletion() {
        let handler = backgroundCompletion
        backgroundCompletion = nil
        handler?()
    }

    // MARK: - Launch steps

    private func reconcileOrphans() async {
        do {
            _ = try await store.reconcileOrphanParts()
        } catch {
            // Best-effort housekeeping (retried next launch); record why it was skipped.
            diagnostics.record(kind: "transfer_reconcile_failed", detail: "\(error)")
        }
    }

    /// Finalizes ready jobs under a background-task assertion (S2 conservative default: run in
    /// the foreground rather than gamble on the background-launch window), then auto-saves any
    /// completed job flagged for Photos.
    private func runFinalizePass() async {
        mergeAssertion = UIApplication.shared.beginBackgroundTask(withName: "transfer-merge") { [weak self] in
            self?.endMergeAssertion()
        }
        defer { endMergeAssertion() }

        let completed = await finalizer.finalizeReadyJobs()
        for id in completed {
            if let job = await store.job(id: id), job.autoSaveToPhotos, let name = job.savedFilename {
                let fileURL = downloadStore.directory.appendingPathComponent(name)
                if PhotosCompatibility.canSave(fileURL) {
                    switch await photoSaver.save(fileURL) {
                    case .saved:
                        break
                    case .permissionDenied, .failed:
                        diagnostics.record(kind: "transfer_photos_save",
                                           detail: "job \(id): could not save \(name)")
                    }
                }
            }
            if let name = await store.job(id: id)?.savedFilename {
                recentlySavedTitles.append((name as NSString).deletingPathExtension)
            }
            await removeFromStoreAndBus(id: id)
        }
    }

    private func endMergeAssertion() {
        guard mergeAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(mergeAssertion)
        mergeAssertion = .invalid
    }

    // MARK: - Queue actions (Phase 6)

    /// Enqueues a freshly built job and starts its first track.
    func enqueue(_ job: TransferJob) async {
        do {
            try await coordinator.start(job)
        } catch {
            diagnostics.record(kind: "transfer_enqueue_failed", detail: "job \(job.id): \(error)")
        }
    }

    func pause(_ id: UUID) async { await coordinator.pause(jobID: id) }

    func resume(_ id: UUID) async {
        do { try await coordinator.resume(jobID: id) }
        catch { diagnostics.record(kind: "transfer_resume_failed", detail: "job \(id): \(error)") }
    }

    /// Cancels a job: stops any in-flight task and drops it from the store (which deletes its
    /// part files). Terminal — the row disappears. Ignored while the job is finalizing
    /// (`.readyToMerge`/`.merging`): the `TransferFinalizer` may be mid-move/mid-mux on the
    /// part files on its own actor, so deleting them here would race that I/O and could leave
    /// a partial output file behind. Letting the in-progress finalize run to completion is
    /// safe, and the queue UI doesn't offer a cancel button on merging rows anyway.
    func cancel(_ id: UUID) async {
        let state = await store.job(id: id)?.state
        if state == .readyToMerge || state == .merging {
            diagnostics.record(kind: "transfer_cancel_ignored_finalizing",
                               detail: "job \(id): cancel ignored while finalizing")
            return
        }
        await coordinator.pause(jobID: id)          // stop the in-flight task first (bounded)
        await removeFromStoreAndBus(id: id)
    }

    /// Retry a failed job: reset the failed track offset conservatively and re-drive.
    func retry(_ id: UUID) async {
        do {
            try await store.update(id: id) { $0.state = .downloading }
            await coordinator.reassociateAndResume()
            await runFinalizePass()
        } catch {
            diagnostics.record(kind: "transfer_retry_failed", detail: "job \(id): \(error)")
        }
    }

    /// Dismiss a terminal (failed/completed) row.
    func remove(_ id: UUID) async { await removeFromStoreAndBus(id: id) }

    private func removeFromStoreAndBus(id: UUID) async {
        do { try await store.remove(id: id) }
        catch { diagnostics.record(kind: "transfer_remove_failed", detail: "job \(id): \(error)") }
        await progress.remove(id)
    }
}
