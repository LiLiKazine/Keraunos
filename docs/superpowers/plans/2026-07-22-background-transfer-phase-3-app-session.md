# Background Transfer — Phase 3: App-target background URLSession + delegate + relaunch glue — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Provide the concrete, lifecycle-bound glue behind the Phase-2 `TransferSession` seam: a process-wide background `URLSession` singleton + session-level `URLSessionDownloadDelegate` that stages temp files synchronously and forwards events to the `TransferCoordinator`, an `AppDelegate` hosting `handleEventsForBackgroundURLSession`, and a composition root that wires it with the correct launch ordering. Verified by a clean simulator build; behavior is covered by the committed manual device test plan.

**Architecture:** `BackgroundTransferService` (app target) owns a `URLSession(configuration: .background(withIdentifier:))` and conforms to `TransferSession`; its delegate stages the finished temp file *before any async hop* then hands off to the coordinator. `AppDelegate` (new, via `@UIApplicationDelegateAdaptor`) stores the OS completion handler. A `TransferEngine` composition type performs the launch sequence — load store → wire delegate → create session → reassociate → reconcile orphans — matching the spec's launch-ordering rule.

**Tech Stack:** Swift 6 (app target: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`), `Foundation`/`URLSession`, `UIKit` (`UIApplicationDelegate`), `KeraunosCore` (Phases 1/2/4-core/5).

**Spec:** `docs/superpowers/specs/2026-07-21-background-transfer-design.md` ("App target (thin glue)", "Launch ordering (critical)", "The transfer engine → Synchronous stage-out"; phasing step 3).

## Global Constraints

- App target is Swift 6, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; deployment iOS 26.0.
- **`@_cdecl`/off-main entry points must be `nonisolated`** — the delegate callbacks arrive on a URLSession delegate queue, not main; mark them `nonisolated` to avoid a MainActor trap.
- **Exactly one** `URLSession` per background identifier process-wide — `BackgroundTransferService` is a singleton; nothing else may construct one with the same id.
- **Launch ordering (load-bearing):** load `transfers.json` → wire delegate → create the background session (opens the event floodgates) — completed before returning from the app-delegate hook.
- **Synchronous stage-out:** in `didFinishDownloadingTo`, move the temp file to a unique staging path *synchronously, before any `await`* (iOS deletes the temp file the instant the delegate returns).
- Background `URLSession` needs **no** `UIBackgroundModes` entitlement; do not add one.
- Build check: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build`.

## Scope decisions (codebase reality vs spec)

- **Persist per-track request headers** (`TrackJob.requestHeaders`) — googlevideo requires the yt-dlp per-format headers replayed on every request, including post-relaunch resumes. The spec's job model omitted them; this is a necessary Core extension.
- **Anonymous background path only.** The codebase has no Keychain (`Auth/` uses `WKWebsiteDataStore` cookies). A background session can't call WebKit, and persisting auth cookies in `transfers.json` (plaintext, Application Support) would downgrade security. Authenticated-in-background is **deferred** to a follow-on that introduces a Keychain (`AfterFirstUnlock`) credential store — `credentialRef` stays nil here.
- **No live-UI switch-over.** The existing foreground `DownloadViewModel` path is untouched; Phase 3 wires the background engine as available infrastructure. The queue UI + start-flow switch-over is Phase 6.

## What this phase deliberately does NOT do

- No Keychain / authenticated-background (deferred, above). No `beginBackgroundTask`/Photos wrapping the finalizer (Phase 4-glue). No queue UI / start-flow rewrite (Phase 6). No chaos flag beyond the Phase 7 contract (folded into the service as debug-only in a follow-on).

---

## File Structure

- `app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift` — MODIFY: add persisted `TrackJob.requestHeaders`.
- `app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift` — MODIFY: apply `requestHeaders` when building requests.
- `app/Keraunos/Keraunos/Transfer/BackgroundTransferService.swift` — the `TransferSession` conformer + `URLSessionDownloadDelegate` (singleton).
- `app/Keraunos/Keraunos/Transfer/AppDelegate.swift` — `UIApplicationDelegate` storing the background completion handler.
- `app/Keraunos/Keraunos/Transfer/TransferEngine.swift` — composition + launch sequence.
- `app/Keraunos/Keraunos/KeraunosApp.swift` — MODIFY: `@UIApplicationDelegateAdaptor`.

---

### Task 1 (Core): persist per-track request headers

**Files:** MODIFY `TransferJob.swift`, `TransferCoordinator.swift`; ADD tests to `TransferJobTests.swift` + `TransferCoordinatorTests.swift`.

- [ ] **Step 1: Add a failing test** to `TransferCoordinatorTests` (headers replayed on the request):

```swift
    @Test func appliesPersistedRequestHeaders() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        var t = track(part: "p.part", chunkSize: nil)
        t.requestHeaders = ["User-Agent": "yt", "Cookie": "a=b"]
        try await coord.start(job(kind: .progressive(t)))
        let req = await session.started[0].request
        #expect(req.value(forHTTPHeaderField: "User-Agent") == "yt")
        #expect(req.value(forHTTPHeaderField: "Cookie") == "a=b")
    }
```

- [ ] **Step 2: Run → fails** ("value of type 'TrackJob' has no member 'requestHeaders'").

- [ ] **Step 3: Add the field.** In `TransferJob.swift`, add to `TrackJob` a stored property + defaulted init param (default `[:]` keeps every existing call site and Codable round-trip valid):

```swift
    /// yt-dlp's per-format request headers (User-Agent, Referer, and — for authenticated
    /// sources — Cookie), replayed on every request including post-relaunch resumes so CDNs
    /// accept the transfer. Persisted with the job.
    public var requestHeaders: [String: String]
```
Add `requestHeaders: [String: String] = [:]` as the LAST init parameter, and `self.requestHeaders = requestHeaders` in the body.

- [ ] **Step 4: Apply them in the coordinator.** In `TransferCoordinator.beginTrack`, after each `URLRequest(url:)` is built (both the chunked and single-shot no-resume branches), apply the headers. Refactor to build the request once:

```swift
        func decorate(_ url: URL) -> URLRequest {
            var request = URLRequest(url: url)
            for (field, value) in track.requestHeaders { request.setValue(value, forHTTPHeaderField: field) }
            return request
        }
```
Use `var request = decorate(track.remoteURL)` in the chunked branch (then set `Range`), and `decorate(track.remoteURL)` in the single-shot no-resume branch.

- [ ] **Step 5: Run → passes** (`--filter TransferCoordinatorTests`). Run whole suite.

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift
git commit -m "feat(transfer): persist + replay per-track request headers"
```

---

### Task 2 (App): `BackgroundTransferService` — TransferSession over a background URLSession

**Files:** Create `app/Keraunos/Keraunos/Transfer/BackgroundTransferService.swift`.

**Interfaces:**
- Consumes: `TransferSession`, `TransferCoordinator` (Core).
- Produces: `final class BackgroundTransferService: NSObject, TransferSession, URLSessionDownloadDelegate`, with `func attach(coordinator: TransferCoordinator)`, `func createSession()`, and the completion-handler bridge `func setBackgroundCompletionHandler(_:)` / `urlSessionDidFinishEvents`.

- [ ] **Step 1: Write it.**

```swift
import Foundation
import KeraunosCore

/// The concrete `TransferSession`: the process-wide owner of the background `URLSession` and
/// its session-level download delegate. Exactly one may exist per background identifier.
/// Delegate callbacks arrive on `delegateQueue` (not main) — they stage the finished temp
/// file synchronously, then hop to the `TransferCoordinator` actor. `@unchecked Sendable`
/// because access to its mutable maps is confined to the serial `delegateQueue`.
final class BackgroundTransferService: NSObject, TransferSession, URLSessionDownloadDelegate, @unchecked Sendable {
    static let backgroundIdentifier = "io.github.lilikazine.Keraunos.transfers"

    private var session: URLSession!
    private var coordinator: TransferCoordinator?
    private let stagingDirectory: URL
    /// Set when iOS relaunches us to finish background events; invoked once the queue drains.
    private var backgroundCompletion: (@Sendable () -> Void)?

    init(stagingDirectory: URL) {
        self.stagingDirectory = stagingDirectory
        super.init()
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
    }

    func attach(coordinator: TransferCoordinator) { self.coordinator = coordinator }

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
        guard let task = tasks.first(where: { $0.taskIdentifier == identifier }) as? URLSessionDownloadTask else { return nil }
        return await withCheckedContinuation { cont in task.cancel(byProducingResumeData: { cont.resume(returning: $0) }) }
    }
    func liveTaskIdentifiers() async -> [Int] {
        await session.allTasks.map(\.taskIdentifier)
    }

    // MARK: Background completion handler (called by AppDelegate)

    func setBackgroundCompletionHandler(_ handler: @escaping @Sendable () -> Void) {
        backgroundCompletion = handler
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletion
        backgroundCompletion = nil
        DispatchQueue.main.async { handler?() }
    }

    // MARK: URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // SYNCHRONOUS stage-out — iOS deletes `location` the instant this returns.
        let staged = stagingDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.moveItem(at: location, to: staged)
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let total = Self.contentRangeTotal(downloadTask.response as? HTTPURLResponse)
        let id = downloadTask.taskIdentifier
        Task { [coordinator] in
            await coordinator?.taskDidFinishDownloading(taskIdentifier: id, to: staged,
                                                        statusCode: status, contentRangeTotal: total)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
                                didCompleteWithError error: Error?) {
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
```

- [ ] **Step 2: (build verified in Task 5).**

---

### Task 3 (App): `AppDelegate` — background completion handler

**Files:** Create `app/Keraunos/Keraunos/Transfer/AppDelegate.swift`.

- [ ] **Step 1: Write it.**

```swift
import UIKit

/// Hosts the one app-delegate hook a background `URLSession` requires: iOS relaunches the app
/// to finish transfer events and hands us a completion handler we must call once the session's
/// queue drains. We route it to the shared transfer service.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransferService.backgroundIdentifier else {
            completionHandler(); return
        }
        // The engine wires the delegate and recreates the session (launch ordering); the
        // handler fires from `urlSessionDidFinishEvents`.
        TransferEngine.shared.handleBackgroundEvents(completion: completionHandler)
    }
}
```

---

### Task 4 (App): `TransferEngine` — composition + launch sequence

**Files:** Create `app/Keraunos/Keraunos/Transfer/TransferEngine.swift`; MODIFY `KeraunosApp.swift`.

- [ ] **Step 1: Write the engine.**

```swift
import Foundation
import KeraunosCore

/// Composition root for the background transfer stack and owner of the launch sequence. A
/// process-wide singleton because the background `URLSession` must be unique per identifier.
@MainActor
final class TransferEngine {
    static let shared = TransferEngine()

    let store: TransferJobStore
    let service: BackgroundTransferService
    let coordinator: TransferCoordinator
    let finalizer: TransferFinalizer

    private var didStart = false

    private init() {
        // 1. Load the durable store synchronously (it is tiny) so the job map exists.
        let base = TransferJobStore.defaultDirectory
        store = try! TransferJobStore(directory: base)
        service = BackgroundTransferService(stagingDirectory: base.appendingPathComponent("staging", isDirectory: true))
        coordinator = TransferCoordinator(store: store, session: service)
        finalizer = TransferFinalizer(store: store, merger: AVFoundationMerger(),
                                      downloadStore: DownloadStore())
    }

    /// The launch sequence, in the mandated order. Idempotent.
    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        service.attach(coordinator: coordinator)   // 2. wire the delegate target
        service.createSession()                     // 3. create session — opens the floodgates
        Task {
            await coordinator.reassociateAndResume()   // rebind live tasks, resume vanished
            _ = await store.reconcileOrphanParts()      // sweep parts with no owning job
            await finalizer.finalizeReadyJobs()         // pick up any .readyToMerge from last run
        }
    }

    func handleBackgroundEvents(completion: @escaping @Sendable () -> Void) {
        startIfNeeded()
        service.setBackgroundCompletionHandler(completion)
    }
}
```

- [ ] **Step 2: Wire the app delegate + start.** In `KeraunosApp.swift`, add the adaptor and kick the launch sequence:

```swift
@main
struct KeraunosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear { TransferEngine.shared.startIfNeeded() }
        }
    }
}
```
(Keep the existing `ContentView()` body; only add the adaptor property and the `.onAppear` start.)

---

### Task 5: Build verification

- [ ] **Step 1: Add the new files to the Xcode target.** They live under `app/Keraunos/Keraunos/Transfer/`; ensure the group is part of the `Keraunos` target (the project uses folder references / file-system-synchronized groups — confirm the new folder is picked up, else add the files to the target in `project.pbxproj`).

- [ ] **Step 2: Clean build for the simulator.**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Run the Core suite** (`swift test --package-path app/KeraunosCore`) to confirm the header change didn't regress.

- [ ] **Step 4: Commit**

```bash
git add app/Keraunos/Keraunos/Transfer app/Keraunos/Keraunos/KeraunosApp.swift app/Keraunos/Keraunos.xcodeproj/project.pbxproj
git commit -m "feat(transfer): background URLSession service + app-delegate relaunch glue"
```

---

## Notes for later phases

- **Phase 4-glue:** wrap `finalizer.finalize` in `UIApplication.shared.beginBackgroundTask`, and after `.completed` call `PhotoLibrarySaver` when `autoSaveToPhotos` (guard `PhotosCompatibility.canSave`). S2 spike decides immediate-vs-deferred.
- **Phase 6:** switch `DownloadViewModel.start()` to enqueue a `TransferJob` via `coordinator.start(...)` (capturing `MediaTrack.httpHeaders` into `TrackJob.requestHeaders` at enqueue), render the queue from `store` + a `TransferProgress` stream, and reconnect after relaunch.
- **Authenticated background (deferred):** introduce a Keychain (`kSecAttrAccessibleAfterFirstUnlock`) credential store; capture cookies from `CookieStore` at enqueue into the Keychain under `credentialRef`; the request builder reads them at construction. Do NOT persist cookies in `transfers.json`.
