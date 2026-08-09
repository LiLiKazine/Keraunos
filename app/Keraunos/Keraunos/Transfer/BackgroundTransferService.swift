import Foundation
import KeraunosCore

/// Owns the short-lived files moved out of URLSession's ephemeral download location. Validation
/// brackets directory creation and every use so a terminal symlink or non-directory can never be
/// accepted as the owned staging root.
nonisolated struct TransferStagingStore: Sendable {
    let directory: URL

    init(directory: URL) throws {
        try SafeFileComponent.validateDirectory(directory, allowMissing: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try SafeFileComponent.validateDirectory(directory, allowMissing: false)
        self.directory = directory
    }

    func newFileURL(id: UUID = UUID()) throws -> URL {
        try SafeFileComponent.validateDirectory(directory, allowMissing: false)
        return try SafeFileComponent(id.uuidString).regularFileURL(in: directory)
    }

    /// Removes stale direct children before delegate delivery begins. The shared primitive uses
    /// `unlink`, so hostile symbolic links are removed without following or touching their target.
    @discardableResult
    func reconcile(onFailure: (_ name: String, _ error: any Error) -> Void) throws -> [String] {
        try SafeFileComponent.validateDirectory(directory, allowMissing: false)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var removed: [String] = []
        for name in names {
            do {
                if try SafeFileComponent.removeEnumeratedRegularFileOrSymbolicLink(
                    named: name,
                    from: directory
                ) {
                    removed.append(name)
                }
            } catch {
                onFailure(name, error)
            }
        }
        return removed.sorted()
    }
}

/// Synchronous bookkeeping for progress ingress. The lock is deliberately tiny: it protects only
/// closure replacement and FIFO event submission and is never held while coordinator work awaits.
private nonisolated final class BackgroundProgressCoalescer: @unchecked Sendable {
    private struct Slot {
        var latest: (@Sendable () async -> Void)?
        var eventQueued = false
        var active = false
    }

    private let lock = NSLock()
    private var slots: [Int: Slot] = [:]

    func enqueue(_ operation: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        operation()
    }

    func submit(
        taskIdentifier: Int,
        operation: @escaping @Sendable () async -> Void,
        enqueue: () -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        var slot = slots[taskIdentifier] ?? Slot()
        slot.latest = operation
        if !slot.eventQueued {
            slot.eventQueued = true
            enqueue()
        }
        slots[taskIdentifier] = slot
    }

    func take(taskIdentifier: Int) -> (@Sendable () async -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        guard var slot = slots[taskIdentifier] else { return nil }
        slot.eventQueued = false
        slot.active = true
        let operation = slot.latest
        slot.latest = nil
        slots[taskIdentifier] = slot
        return operation
    }

    func finished(taskIdentifier: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard var slot = slots[taskIdentifier] else { return }
        slot.active = false
        if slot.latest == nil && !slot.eventQueued {
            slots.removeValue(forKey: taskIdentifier)
        } else {
            slots[taskIdentifier] = slot
        }
    }
}

/// Orders URLSession delegate ingress with the async coordinator work it launches. Delegate
/// callbacks submit events synchronously into one FIFO stream, so the session's "events drained"
/// marker cannot overtake work submitted by an earlier callback. The OS-facing signal fires only
/// after every submitted operation has returned, including failure handling/persistence paths.
nonisolated final class BackgroundEventProcessingTracker: Sendable {
    private enum Event: Sendable {
        case work(@Sendable () async -> Void)
        case progress(taskIdentifier: Int)
        case eventsDrained
    }

    private let continuation: AsyncStream<Event>.Continuation
    private let worker: Task<Void, Never>
    private let progressCoalescer: BackgroundProgressCoalescer

    init(onEventsFinished: @escaping @Sendable () async -> Void) {
        let (stream, continuation) = AsyncStream<Event>.makeStream()
        let progressCoalescer = BackgroundProgressCoalescer()
        self.continuation = continuation
        self.progressCoalescer = progressCoalescer
        self.worker = Task {
            for await event in stream {
                switch event {
                case .work(let operation):
                    // One consumer intentionally serializes coordinator ingress in the same order
                    // as the serial URLSession delegate queue submitted it.
                    await operation()
                case .progress(let taskIdentifier):
                    if let operation = progressCoalescer.take(taskIdentifier: taskIdentifier) {
                        await operation()
                    }
                    progressCoalescer.finished(taskIdentifier: taskIdentifier)
                case .eventsDrained:
                    await onEventsFinished()
                }
            }
        }
    }

    deinit {
        continuation.finish()
        worker.cancel()
    }

    func submit(_ operation: @escaping @Sendable () async -> Void) {
        progressCoalescer.enqueue {
            continuation.yield(.work(operation))
        }
    }

    func submitProgress(
        taskIdentifier: Int,
        _ operation: @escaping @Sendable () async -> Void
    ) {
        progressCoalescer.submit(taskIdentifier: taskIdentifier, operation: operation) {
            continuation.yield(.progress(taskIdentifier: taskIdentifier))
        }
    }

    func eventsDidDrain() {
        progressCoalescer.enqueue {
            continuation.yield(.eventsDrained)
        }
    }
}

/// The concrete `TransferSession`: the process-wide owner of the background `URLSession` and
/// its session-level download delegate. Exactly one may exist per background identifier.
///
/// Delegate callbacks arrive on the session's `delegateQueue` (not main), so the whole class
/// is `nonisolated` (the app target defaults to `@MainActor`, which would otherwise trap an
/// off-main callback). `@unchecked Sendable`: its mutable state is either set once during the
/// launch sequence or confined to the serial delegate queue.
nonisolated final class BackgroundTransferService: NSObject, TransferSession, URLSessionDownloadDelegate, @unchecked Sendable {
    static let backgroundIdentifier = "io.github.lilikazine.Keraunos.transfers"

    private var session: URLSession!
    private var coordinator: TransferCoordinator?
    private let stagingStore: TransferStagingStore
    private var eventProcessing: BackgroundEventProcessingTracker?
    private let diagnostics: (any TransferDiagnostics)?

    init(stagingDirectory: URL, diagnostics: (any TransferDiagnostics)? = nil) throws {
        self.diagnostics = diagnostics
        do {
            self.stagingStore = try TransferStagingStore(directory: stagingDirectory)
        } catch {
            diagnostics?.record(kind: "transfer_staging_dir", detail: "\(error)")
            throw error
        }
        super.init()
    }

    func attach(coordinator: TransferCoordinator, onFinishEvents: @escaping @Sendable () -> Void) {
        self.coordinator = coordinator
        self.eventProcessing = BackgroundEventProcessingTracker {
            onFinishEvents()
        }
    }

    /// Creates the background session. MUST be called LAST in the launch sequence — this is
    /// what makes iOS start draining queued events into the (now-wired) delegate.
    func createSession() throws {
        do {
            try stagingStore.reconcile { [diagnostics] name, error in
                diagnostics?.record(kind: "transfer_staging_cleanup",
                                    detail: "\(name): \(error)")
            }
        } catch {
            diagnostics?.record(kind: "transfer_staging_reconcile", detail: "\(error)")
            throw error
        }
        let config = URLSessionConfiguration.background(withIdentifier: Self.backgroundIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: TransferSession

    func startDownloadTask(for request: URLRequest) async throws -> Int {
        let task = session.downloadTask(with: request)
        task.resume()
        return task.taskIdentifier
    }

    func startDownloadTask(withResumeData resumeData: Data) async throws -> Int {
        let task = session.downloadTask(withResumeData: resumeData)
        task.resume()
        return task.taskIdentifier
    }

    func cancelTask(_ identifier: Int) async -> Data? {
        let tasks = await session.allTasks
        guard let task = tasks.first(where: { $0.taskIdentifier == identifier }) as? URLSessionDownloadTask else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            task.cancel(byProducingResumeData: { continuation.resume(returning: $0) })
        }
    }

    func liveTaskIdentifiers() async -> [Int] {
        await session.allTasks.map(\.taskIdentifier)
    }

    // MARK: Background completion handler

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        eventProcessing?.eventsDidDrain()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // SYNCHRONOUS stage-out — iOS deletes `location` the instant this returns, so move the
        // bytes to a stable staging path BEFORE any async hop. Routing (which job owns them)
        // happens asynchronously on the coordinator actor; if there's no owner it GC's the file.
        let staged: URL
        do {
            staged = try stagingStore.newFileURL()
            try FileManager.default.moveItem(at: location, to: staged)
        } catch {
            // The temp file is gone the moment this returns; if we can't stage it, the bytes
            // are lost for this task. Record it and stop — the coordinator will resume the
            // track from its persisted offset on the next launch rather than get a bad file.
            diagnostics?.record(kind: "transfer_stageout_failed",
                                detail: "task \(downloadTask.taskIdentifier): \(error)")
            return
        }
        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let total = Self.contentRangeTotal(http)
        let id = downloadTask.taskIdentifier
        eventProcessing?.submit { [coordinator] in
            await coordinator?.taskDidFinishDownloading(taskIdentifier: id, to: staged,
                                                        statusCode: status, contentRangeTotal: total)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskIdentifier
        eventProcessing?.submitProgress(taskIdentifier: id) { [coordinator] in
            await coordinator?.taskDidWriteData(taskIdentifier: id,
                                                totalBytesWritten: totalBytesWritten,
                                                totalBytesExpectedToWrite: totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }   // success is handled in didFinishDownloadingTo
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as? URLError)?.code == .cancelled
        let id = task.taskIdentifier
        eventProcessing?.submit { [coordinator] in
            await coordinator?.taskDidFail(taskIdentifier: id, resumeData: resumeData, isCancelled: cancelled)
        }
    }

    private static func contentRangeTotal(_ http: HTTPURLResponse?) -> Int64? {
        guard let value = http?.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
