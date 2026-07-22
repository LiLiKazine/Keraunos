import Foundation
import KeraunosCore

/// Composition root for the background-transfer stack and owner of the launch sequence. A
/// process-wide singleton because the background `URLSession` must be unique per identifier.
///
/// This wires the Phase-1/2/4/5 core (`TransferJobStore`, `TransferCoordinator`,
/// `TransferFinalizer`) to the concrete `BackgroundTransferService`. The live download UI still
/// uses the existing foreground path; this engine is available infrastructure the queue UI
/// (Phase 6) will switch `start()` over to.
@MainActor
final class TransferEngine {
    static let shared = TransferEngine()

    let store: TransferJobStore
    let service: BackgroundTransferService
    let coordinator: TransferCoordinator
    let finalizer: TransferFinalizer

    private var didStart = false
    /// The OS completion handler from `handleEventsForBackgroundURLSession`, held on the main
    /// actor and fired once the session reports all events drained.
    private var backgroundCompletion: (() -> Void)?

    private init() {
        // 1. Load the durable store synchronously (it is tiny) so the job map exists before
        //    any background event can arrive.
        let base = TransferJobStore.defaultDirectory
        store = try! TransferJobStore(directory: base)
        service = BackgroundTransferService(
            stagingDirectory: base.appendingPathComponent("staging", isDirectory: true))
        coordinator = TransferCoordinator(store: store, session: service)
        finalizer = TransferFinalizer(store: store, merger: AVFoundationMerger(),
                                      downloadStore: DownloadStore())
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
            // Orphan GC is deliberately best-effort: a failure here is harmless (orphaned
            // parts waste only disk and are swept on the next launch), so it must not block
            // the launch sequence — hence the discarded error rather than a propagated throw.
            _ = try? await store.reconcileOrphanParts()
            await finalizer.finalizeReadyJobs()         // pick up any .readyToMerge from last run
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
}
