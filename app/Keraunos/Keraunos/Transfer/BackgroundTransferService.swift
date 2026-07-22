import Foundation
import KeraunosCore

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
    private let stagingDirectory: URL
    /// Fired (on the delegate queue) when iOS has delivered all queued background events, so
    /// the engine can invoke the OS completion handler it holds on the main actor. Kept as a
    /// `@Sendable` signal so the non-Sendable OS handler never crosses into this class.
    private var onFinishEvents: (@Sendable () -> Void)?
    private let diagnostics: (any TransferDiagnostics)?

    init(stagingDirectory: URL, diagnostics: (any TransferDiagnostics)? = nil) {
        self.stagingDirectory = stagingDirectory
        self.diagnostics = diagnostics
        super.init()
        do {
            try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        } catch {
            // Without a staging dir, stage-out can't persist bytes — record it so the cause is
            // visible if transfers then fail to land.
            diagnostics?.record(kind: "transfer_staging_dir", detail: "\(error)")
        }
    }

    func attach(coordinator: TransferCoordinator, onFinishEvents: @escaping @Sendable () -> Void) {
        self.coordinator = coordinator
        self.onFinishEvents = onFinishEvents
    }

    /// Creates the background session. MUST be called LAST in the launch sequence — this is
    /// what makes iOS start draining queued events into the (now-wired) delegate.
    func createSession() {
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
        onFinishEvents?()
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // SYNCHRONOUS stage-out — iOS deletes `location` the instant this returns, so move the
        // bytes to a stable staging path BEFORE any async hop. Routing (which job owns them)
        // happens asynchronously on the coordinator actor; if there's no owner it GC's the file.
        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
        do {
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
        Task { [coordinator] in
            await coordinator?.taskDidFinishDownloading(taskIdentifier: id, to: staged,
                                                        statusCode: status, contentRangeTotal: total)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }   // success is handled in didFinishDownloadingTo
        let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        let cancelled = (error as? URLError)?.code == .cancelled
        let id = task.taskIdentifier
        Task { [coordinator] in
            await coordinator?.taskDidFail(taskIdentifier: id, resumeData: resumeData, isCancelled: cancelled)
        }
    }

    private static func contentRangeTotal(_ http: HTTPURLResponse?) -> Int64? {
        guard let value = http?.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
}
