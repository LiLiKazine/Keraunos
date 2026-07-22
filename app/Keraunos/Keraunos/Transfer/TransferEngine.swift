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

    private let downloadStore = DownloadStore()
    private let photoSaver: any PhotoSaving = PhotoLibrarySaver()
    private let diagnostics: any TransferDiagnostics

    private var didStart = false
    /// The OS completion handler from `handleEventsForBackgroundURLSession`, held on the main
    /// actor and fired once the session reports all events drained.
    private var backgroundCompletion: (() -> Void)?
    /// Live assertion keeping the app awake across a finalize/merge pass.
    private var mergeAssertion: UIBackgroundTaskIdentifier = .invalid

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
        coordinator = TransferCoordinator(store: store, session: service, diagnostics: diagnostics)
        finalizer = TransferFinalizer(store: store, merger: AVFoundationMerger(),
                                      downloadStore: downloadStore, diagnostics: diagnostics)
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
            guard let job = await store.job(id: id), job.autoSaveToPhotos,
                  let name = job.savedFilename else { continue }
            let fileURL = downloadStore.directory.appendingPathComponent(name)
            guard PhotosCompatibility.canSave(fileURL) else { continue }
            switch await photoSaver.save(fileURL) {
            case .saved:
                break
            case .permissionDenied, .failed:
                diagnostics.record(kind: "transfer_photos_save",
                                   detail: "job \(id): could not save \(name)")
            }
        }
    }

    private func endMergeAssertion() {
        guard mergeAssertion != .invalid else { return }
        UIApplication.shared.endBackgroundTask(mergeAssertion)
        mergeAssertion = .invalid
    }
}
