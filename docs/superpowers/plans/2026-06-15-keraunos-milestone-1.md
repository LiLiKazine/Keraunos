# Keraunos Milestone 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paste a public X (Twitter) video URL → the app resolves a progressive MP4 via embedded yt-dlp → downloads it with native URLSession → the `.mp4` appears in the app's Documents folder (visible in the Files app).

**Architecture:** Embedded CPython (BeeWare Python-Apple-support) runs yt-dlp for **extraction only** — it returns a direct media URL + metadata as JSON. Native Swift `URLSession` performs the file transfer. The whole app is built behind a `MediaExtracting` protocol so the UI, downloader, and storage are fully implemented and tested before the Python runtime is embedded; a `MockExtractor` stands in until the real `PythonExtractor` lands.

**Tech Stack:** Swift 6 language mode (`SWIFT_VERSION = 6.0`, complete data-race safety enforced) with approachable concurrency + main-actor-by-default isolation / SwiftUI / Swift Testing, Xcode 26.5 (Swift 6.3.2 toolchain, file-system-synchronized groups), iOS 26.5 deployment target, embedded CPython 3.13 via Python-Apple-support, yt-dlp (pure-Python, vendored), certifi.

> **Concurrency enforcement note:** the project builds in Swift 6 language mode, so data-race violations are compile **errors**, not warnings. Two consequences for the tasks below: (1) `StubURLProtocol`'s shared `static var handler` (Task 5) is a genuine race — keep it `nonisolated(unsafe)` *and* mark the suite `@Suite(.serialized)`, or inject the handler per-session; (2) `PythonExtractor` (Task 12) must not block a cooperative-pool thread on the synchronous Python C call — offload it via `@concurrent` or a dedicated serial `DispatchQueue` bridged with `withCheckedThrowingContinuation`.

---

## Conventions (read once)

- **Repo root:** `/Users/leo/Developer/Keraunos`. Run all commands from there unless stated.
- **Project / scheme:** `app/Keraunos/Keraunos.xcodeproj`, scheme `Keraunos`.
- **Adding Swift files:** the app target uses **file-system-synchronized groups**. Creating a `.swift` file anywhere under `app/Keraunos/Keraunos/` auto-adds it to the app target; under `app/Keraunos/KeraunosTests/` auto-adds it to the test target. **No `pbxproj` edits needed for source/test files.**
- **Swift build/test command** (define `DEST` once):
  ```bash
  DEST='platform=iOS Simulator,name=iPhone 17'
  xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests
  ```
  If `iPhone 17` is unavailable, pick one from `xcrun simctl list devices available | grep iPhone`.
- **Commits:** use the `structured-commit` skill. The `git commit` lines below give the summary line; let the skill expand the body.
- **TDD:** every code task is test-first. Run the test, see it fail, implement, see it pass, commit.
- **Swift 6 isolation (minimal-annotation rule):** the app target is **main-actor-by-default** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`). The idiom is to *let code stay on the main actor* and only opt out where it genuinely runs off it. So:
  - **No annotation** (main-actor by default) for UI and main-only types: `DownloadViewModel`, the views, and the **download path** `Downloader` / `FileDownloading` / `DownloadStore`. `await session.download(...)` *suspends* the main-actor task rather than blocking the main thread, so there is no reason to leave the main actor.
  - **`nonisolated`** only for the **extraction path**, which executes on `PythonExtractor`'s background queue and crosses back to the main actor: `MediaExtracting`, `MockExtractor`, `ResolvedMedia`, `KeraunosError`, `ExtractionResult`, `ExtractionDecoder`, `PythonExtractor`. Add `Sendable` where values cross actors (`ResolvedMedia`, the `MediaExtracting` existential).
  - **Tests** are `nonisolated` by default, so suites that construct/use main-actor types are `@MainActor` (`DownloadViewModelTests`, `DownloaderTests`, and the `SpyDownloader` double). `DownloaderTests` is additionally `@Suite(.serialized)` because it mutates the shared `StubURLProtocol.handler`.

---

## File Structure

```
app/Keraunos/Keraunos/
  KeraunosApp.swift                 # @main (exists)
  ContentView.swift                 # replaced: the one screen (exists)
  Model/
    KeraunosError.swift             # Task 2
    ResolvedMedia.swift             # Task 3 (ResolvedMedia + ExtractionResult DTO + decoder)
    MediaExtracting.swift           # Task 4 (protocol + MockExtractor)
  Download/
    Downloader.swift                # Task 5 (URLSession transfer)
    DownloadStore.swift             # Task 6 (Documents listing)
  UI/
    DownloadViewModel.swift         # Task 7
    DownloadScreen.swift            # Task 7 (replaces ContentView body)
  PythonRuntime/
    Resources/
      keraunos_extract.py           # Task 8 (also dev-tested outside the app)
      cacert.pem                    # Task 10 (certifi bundle)
      python-stdlib/...             # Task 10 (from Python-Apple-support)
      site-packages/yt_dlp/...      # Task 10 (vendored yt-dlp)
    PythonBridge.h / PythonBridge.m # Task 11 (C-API init + extract)
    PythonExtractor.swift           # Task 12 (implements MediaExtracting)
  Keraunos-Bridging-Header.h        # Task 11

app/Keraunos/KeraunosTests/
  KeraunosErrorTests.swift          # Task 2
  ExtractionDecodingTests.swift     # Task 3
  DownloaderTests.swift             # Task 5
  StubURLProtocol.swift             # Task 5 (test helper)
  DownloadStoreTests.swift          # Task 6
  DownloadViewModelTests.swift      # Task 7

app/Keraunos/python-dev/            # dev-only, NOT bundled (outside app target folder)
  test_extract.py                   # Task 8
  requirements.txt                  # Task 8
```

---

## Phase 0 — Baseline

### Task 1: Confirm the scaffold builds and tests green

**Files:** none (verification only)

- [ ] **Step 1: Build for the simulator**

```bash
DEST='platform=iOS Simulator,name=iPhone 17'
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST"
```
Expected: `** BUILD SUCCEEDED **`. If it fails, resolve simulator/toolchain issues before proceeding.

- [ ] **Step 2: Run the template unit tests**

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests
```
Expected: `** TEST SUCCEEDED **` (the template `example` test passes).

- [ ] **Step 3: Remove the placeholder template test**

Delete the body of `app/Keraunos/KeraunosTests/KeraunosTests.swift` and replace its contents with:

```swift
import Testing
@testable import Keraunos

// Suite files live alongside this one. This file intentionally left as a marker.
```

- [ ] **Step 4: Commit**

```bash
git commit -m "test: clear template test, confirm baseline green"
```

---

## Phase 1 — Swift domain core (no Python)

### Task 2: `KeraunosError`

**Files:**
- Create: `app/Keraunos/Keraunos/Model/KeraunosError.swift`
- Test: `app/Keraunos/KeraunosTests/KeraunosErrorTests.swift`

- [ ] **Step 1: Write the failing test**

`app/Keraunos/KeraunosTests/KeraunosErrorTests.swift`:
```swift
import Testing
@testable import Keraunos

struct KeraunosErrorTests {
    @Test func mapsKnownErrorKinds() {
        #expect(KeraunosError(errorKind: "unsupported") == .unsupported)
        #expect(KeraunosError(errorKind: "needs_ffmpeg") == .needsFfmpeg)
        #expect(KeraunosError(errorKind: "requires_auth") == .requiresAuth)
        #expect(KeraunosError(errorKind: "network") == .network)
    }

    @Test func mapsUnknownKindToRuntimeWithDetail() {
        #expect(KeraunosError(errorKind: "weird", detail: "boom") == .runtime(detail: "boom"))
    }

    @Test func everyCaseHasAUserMessage() {
        let cases: [KeraunosError] = [.unsupported, .needsFfmpeg, .requiresAuth, .network, .runtime(detail: "x"), .cancelled]
        for error in cases {
            #expect(error.errorDescription?.isEmpty == false)
        }
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/KeraunosErrorTests
```
Expected: FAIL — `cannot find 'KeraunosError' in scope`.

- [ ] **Step 3: Implement**

`app/Keraunos/Keraunos/Model/KeraunosError.swift`:
```swift
import Foundation

/// All failures surfaced to the UI. Python exceptions are mapped to these at the
/// extraction boundary so nothing above the boundary sees a Python object.
nonisolated enum KeraunosError: Error, Equatable {
    case unsupported
    case needsFfmpeg
    case requiresAuth
    case network
    case runtime(detail: String)
    case cancelled
}

nonisolated extension KeraunosError {
    /// Maps an `error_kind` string emitted by the Python extraction module.
    init(errorKind: String, detail: String = "") {
        switch errorKind {
        case "unsupported":   self = .unsupported
        case "needs_ffmpeg":  self = .needsFfmpeg
        case "requires_auth": self = .requiresAuth
        case "network":       self = .network
        default:              self = .runtime(detail: detail.isEmpty ? errorKind : detail)
        }
    }
}

nonisolated extension KeraunosError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupported:        return "This link isn't supported."
        case .needsFfmpeg:        return "This video needs format-merging support, coming in a later version."
        case .requiresAuth:       return "This video requires sign-in (cookies), which isn't supported yet."
        case .network:            return "Download failed — check your connection."
        case .runtime(let detail): return "Something went wrong: \(detail)"
        case .cancelled:          return "Download cancelled."
        }
    }
}
```

- [ ] **Step 4: Run it, expect pass**

Same command as Step 2. Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(model): add KeraunosError with kind mapping and messages"
```

---

### Task 3: `ResolvedMedia` + extraction-result decoding

**Files:**
- Create: `app/Keraunos/Keraunos/Model/ResolvedMedia.swift`
- Test: `app/Keraunos/KeraunosTests/ExtractionDecodingTests.swift`

The Python module returns JSON shaped like:
`{"ok": true, "direct_url": "...", "filename": "...", "title": "..."}` on success, or
`{"ok": false, "error_kind": "needs_ffmpeg", "detail": "..."}` on failure.

- [ ] **Step 1: Write the failing test**

`app/Keraunos/KeraunosTests/ExtractionDecodingTests.swift`:
```swift
import Testing
import Foundation
@testable import Keraunos

struct ExtractionDecodingTests {
    @Test func decodesSuccess() throws {
        let json = #"{"ok":true,"direct_url":"https://x.test/v.mp4","filename":"clip.mp4","title":"My Clip"}"#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        #expect(media == ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                       suggestedFilename: "clip.mp4",
                                       title: "My Clip"))
    }

    @Test func mapsErrorPayloadToKeraunosError() {
        let json = #"{"ok":false,"error_kind":"needs_ffmpeg","detail":"hls only"}"#
        #expect(throws: KeraunosError.needsFfmpeg) {
            try ExtractionDecoder.decode(Data(json.utf8))
        }
    }

    @Test func fallsBackToURLLastComponentWhenFilenameMissing() throws {
        let json = #"{"ok":true,"direct_url":"https://x.test/abc/video.mp4","title":""}"#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        #expect(media.suggestedFilename == "video.mp4")
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/ExtractionDecodingTests
```
Expected: FAIL — `cannot find 'ResolvedMedia'` / `ExtractionDecoder`.

- [ ] **Step 3: Implement**

`app/Keraunos/Keraunos/Model/ResolvedMedia.swift`:
```swift
import Foundation

/// A resolved, directly-downloadable media file (a single progressive stream).
nonisolated struct ResolvedMedia: Equatable, Sendable {
    let directURL: URL
    let suggestedFilename: String
    let title: String
}

/// Wire format returned by the Python extraction module.
private nonisolated struct ExtractionResult: Decodable {
    let ok: Bool
    let directURL: String?
    let filename: String?
    let title: String?
    let errorKind: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case ok, filename, title, detail
        case directURL = "direct_url"
        case errorKind = "error_kind"
    }
}

/// Decodes the Python module's JSON into `ResolvedMedia`, throwing a mapped
/// `KeraunosError` for failure payloads or malformed data.
nonisolated enum ExtractionDecoder {
    static func decode(_ data: Data) throws -> ResolvedMedia {
        let result: ExtractionResult
        do {
            result = try JSONDecoder().decode(ExtractionResult.self, from: data)
        } catch {
            throw KeraunosError.runtime(detail: "malformed extraction result")
        }
        guard result.ok, let urlString = result.directURL, let url = URL(string: urlString) else {
            throw KeraunosError(errorKind: result.errorKind ?? "runtime", detail: result.detail ?? "")
        }
        let filename = result.filename.flatMap { $0.isEmpty ? nil : $0 } ?? url.lastPathComponent
        return ResolvedMedia(directURL: url, suggestedFilename: filename, title: result.title ?? "")
    }
}
```

- [ ] **Step 4: Run it, expect pass**

Same command as Step 2. Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(model): add ResolvedMedia and extraction-result decoder"
```

---

### Task 4: `MediaExtracting` protocol + `MockExtractor`

**Files:**
- Create: `app/Keraunos/Keraunos/Model/MediaExtracting.swift`

No dedicated test (it's a protocol + a test double); it's exercised by Task 7's view-model tests.

- [ ] **Step 1: Implement**

`app/Keraunos/Keraunos/Model/MediaExtracting.swift`:
```swift
import Foundation

/// Resolves a page URL to a directly-downloadable media file.
/// The real implementation (PythonExtractor) arrives in Phase 4; until then the
/// app and tests use MockExtractor.
nonisolated protocol MediaExtracting: Sendable {
    func resolve(_ url: URL) async throws -> ResolvedMedia
}

/// Deterministic test/preview double.
nonisolated struct MockExtractor: MediaExtracting {
    var result: Result<ResolvedMedia, KeraunosError>

    init(result: Result<ResolvedMedia, KeraunosError> = .success(
        ResolvedMedia(directURL: URL(string: "https://example.com/sample.mp4")!,
                      suggestedFilename: "sample.mp4",
                      title: "Sample"))) {
        self.result = result
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try result.get()
    }
}
```

- [ ] **Step 2: Build (no test yet)**

```bash
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST"
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(model): add MediaExtracting protocol and MockExtractor"
```

---

## Phase 2 — Native download

### Task 5: `Downloader` (URLSession transfer)

**Files:**
- Create: `app/Keraunos/Keraunos/Download/Downloader.swift`
- Test: `app/Keraunos/KeraunosTests/DownloaderTests.swift`
- Test helper: `app/Keraunos/KeraunosTests/StubURLProtocol.swift`

- [ ] **Step 1: Write the test helper**

`app/Keraunos/KeraunosTests/StubURLProtocol.swift`:
```swift
import Foundation

/// Intercepts requests in tests. Set `handler` to control the response.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = StubURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    /// Builds a URLSession routed through this protocol.
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

- [ ] **Step 2: Write the failing test**

`app/Keraunos/KeraunosTests/DownloaderTests.swift`:
```swift
import Testing
import Foundation
@testable import Keraunos

@Suite(.serialized)
@MainActor
struct DownloaderTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savesFileToDestinationWithSuggestedName() async throws {
        let payload = Data("fake mp4 bytes".utf8)
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, payload)
        }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        let dir = tempDir()
        let downloader = Downloader(session: StubURLProtocol.session())

        let saved = try await downloader.download(media, to: dir)

        #expect(saved.lastPathComponent == "clip.mp4")
        #expect(try Data(contentsOf: saved) == payload)
    }

    @Test func mapsHTTPErrorToNetwork() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        let downloader = Downloader(session: StubURLProtocol.session())

        await #expect(throws: KeraunosError.network) {
            try await downloader.download(media, to: tempDir())
        }
    }

    @Test func mapsCancellationToCancelled() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        let downloader = Downloader(session: StubURLProtocol.session())

        await #expect(throws: KeraunosError.cancelled) {
            try await downloader.download(media, to: tempDir())
        }
    }
}
```

- [ ] **Step 3: Run it, expect failure**

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/DownloaderTests
```
Expected: FAIL — `cannot find 'Downloader'`.

- [ ] **Step 4: Implement**

`app/Keraunos/Keraunos/Download/Downloader.swift`:
```swift
import Foundation

protocol FileDownloading {
    func download(_ media: ResolvedMedia, to destinationDirectory: URL) async throws -> URL
}

/// Downloads a resolved media file with URLSession and moves it into place.
/// Milestone 1: simple await-to-completion. Background sessions come later.
struct Downloader: FileDownloading {
    private let session: URLSession
    init(session: URLSession = .shared) { self.session = session }

    func download(_ media: ResolvedMedia, to destinationDirectory: URL) async throws -> URL {
        do {
            let (tempURL, response) = try await session.download(from: media.directURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw KeraunosError.network
            }
            let destination = destinationDirectory.appendingPathComponent(media.suggestedFilename)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
            return destination
        } catch let error as KeraunosError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw KeraunosError.cancelled
        } catch is CancellationError {
            throw KeraunosError.cancelled
        } catch {
            throw KeraunosError.network
        }
    }
}
```

- [ ] **Step 5: Run it, expect pass**

Same command as Step 3. Expected: TEST SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(download): add URLSession-based Downloader with error mapping"
```

---

### Task 6: `DownloadStore` (Documents listing)

**Files:**
- Create: `app/Keraunos/Keraunos/Download/DownloadStore.swift`
- Test: `app/Keraunos/KeraunosTests/DownloadStoreTests.swift`

- [ ] **Step 1: Write the failing test**

`app/Keraunos/KeraunosTests/DownloadStoreTests.swift`:
```swift
import Testing
import Foundation
@testable import Keraunos

struct DownloadStoreTests {
    @Test func listsOnlyMP4FilesSorted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("b.mp4"))
        try Data().write(to: dir.appendingPathComponent("a.mp4"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))

        let store = DownloadStore(directory: dir)
        let names = store.savedFiles().map(\.lastPathComponent)

        #expect(names == ["a.mp4", "b.mp4"])
    }

    @Test func defaultDirectoryIsDocuments() {
        let store = DownloadStore()
        #expect(store.directory.path.contains("/Documents"))
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/DownloadStoreTests
```
Expected: FAIL — `cannot find 'DownloadStore'`.

- [ ] **Step 3: Implement**

`app/Keraunos/Keraunos/Download/DownloadStore.swift`:
```swift
import Foundation

/// Owns the download destination and lists finished downloads.
struct DownloadStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func savedFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
```

- [ ] **Step 4: Run it, expect pass**

Same command as Step 2. Expected: TEST SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(download): add DownloadStore for Documents listing"
```

---

## Phase 3 — UI (wired to the mock)

### Task 7: `DownloadViewModel` + `DownloadScreen`

**Files:**
- Create: `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`
- Create: `app/Keraunos/Keraunos/UI/DownloadScreen.swift`
- Modify: `app/Keraunos/Keraunos/ContentView.swift`
- Test: `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`

- [ ] **Step 1: Write the failing test**

`app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`:
```swift
import Testing
import Foundation
@testable import Keraunos

@MainActor
struct DownloadViewModelTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func successfulDownloadAddsFileAndClearsError() async {
        let dir = tempDir()
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        let vm = DownloadViewModel(
            extractor: MockExtractor(result: .success(media)),
            downloader: SpyDownloader(behavior: .succeed(dir.appendingPathComponent("clip.mp4"))),
            store: DownloadStore(directory: dir))
        vm.urlText = "https://x.test/post/1"

        await vm.startDownload()

        #expect(vm.errorMessage == nil)
        #expect(vm.lastSavedName == "clip.mp4")
        #expect(vm.isWorking == false)
    }

    @Test func extractionErrorShowsMessage() async {
        let vm = DownloadViewModel(
            extractor: MockExtractor(result: .failure(.needsFfmpeg)),
            downloader: SpyDownloader(behavior: .succeed(URL(fileURLWithPath: "/x"))),
            store: DownloadStore(directory: tempDir()))
        vm.urlText = "https://x.test/post/1"

        await vm.startDownload()

        #expect(vm.errorMessage == KeraunosError.needsFfmpeg.errorDescription)
        #expect(vm.isWorking == false)
    }

    @Test func rejectsInvalidURL() async {
        let vm = DownloadViewModel(
            extractor: MockExtractor(),
            downloader: SpyDownloader(behavior: .succeed(URL(fileURLWithPath: "/x"))),
            store: DownloadStore(directory: tempDir()))
        vm.urlText = "not a url"

        await vm.startDownload()

        #expect(vm.errorMessage != nil)
    }
}

/// Minimal downloader double for view-model tests.
@MainActor
struct SpyDownloader: FileDownloading {
    enum Behavior { case succeed(URL); case fail(KeraunosError) }
    let behavior: Behavior
    func download(_ media: ResolvedMedia, to destinationDirectory: URL) async throws -> URL {
        switch behavior {
        case .succeed(let url): return url
        case .fail(let error): throw error
        }
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/DownloadViewModelTests
```
Expected: FAIL — `cannot find 'DownloadViewModel'`.

- [ ] **Step 3: Implement the view model**

`app/Keraunos/Keraunos/UI/DownloadViewModel.swift`:
```swift
import Foundation
import Observation

@MainActor
@Observable
final class DownloadViewModel {
    var urlText: String = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var lastSavedName: String?
    private(set) var savedFiles: [URL] = []

    private let extractor: MediaExtracting
    private let downloader: FileDownloading
    private let store: DownloadStore

    init(extractor: MediaExtracting, downloader: FileDownloading, store: DownloadStore) {
        self.extractor = extractor
        self.downloader = downloader
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
        defer { isWorking = false }
        do {
            let media = try await extractor.resolve(url)
            let saved = try await downloader.download(media, to: store.directory)
            lastSavedName = saved.lastPathComponent
            savedFiles = store.savedFiles()
        } catch let error as KeraunosError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = KeraunosError.runtime(detail: error.localizedDescription).errorDescription
        }
    }
}
```

- [ ] **Step 4: Run it, expect pass**

Same command as Step 2. Expected: TEST SUCCEEDED.

- [ ] **Step 5: Implement the screen**

`app/Keraunos/Keraunos/UI/DownloadScreen.swift`:
```swift
import SwiftUI

struct DownloadScreen: View {
    @State private var model: DownloadViewModel

    init(model: DownloadViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Video link") {
                    TextField("https://x.com/…", text: $model.urlText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button {
                        Task { await model.startDownload() }
                    } label: {
                        if model.isWorking { ProgressView() } else { Text("Download") }
                    }
                    .disabled(model.isWorking || model.urlText.isEmpty)
                }

                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section("Downloads") {
                    if model.savedFiles.isEmpty {
                        Text("No downloads yet.").foregroundStyle(.secondary)
                    } else {
                        ForEach(model.savedFiles, id: \.self) { file in
                            Text(file.lastPathComponent)
                        }
                    }
                }
            }
            .navigationTitle("Keraunos")
        }
    }
}
```

- [ ] **Step 6: Wire it into the app** — replace the contents of `app/Keraunos/Keraunos/ContentView.swift`:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        // Milestone 1 uses the mock extractor until PythonExtractor is wired in (Task 12).
        DownloadScreen(model: DownloadViewModel(
            extractor: MockExtractor(),
            downloader: Downloader(),
            store: DownloadStore()))
    }
}

#Preview {
    ContentView()
}
```

- [ ] **Step 7: Build + run the full unit suite**

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests
```
Expected: TEST SUCCEEDED (all suites).

- [ ] **Step 8: Manual check** — run the app in the simulator (Xcode ▶). With the mock extractor, tapping **Download** should "download" `https://example.com/sample.mp4`. It will fail with a network error against the real URL — that's expected; the goal is to confirm the screen, the working state, and error display render correctly.

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(ui): add DownloadScreen + DownloadViewModel wired to mock extractor"
```

---

## Phase 4 — Embedded Python extraction

> This phase has procedural Xcode steps that can't be expressed as code. Each ends with an explicit verification gate. Do not skip the gates.

### Task 8: `keraunos_extract.py` — TDD with system Python

**Files:**
- Create: `app/Keraunos/Keraunos/PythonRuntime/Resources/keraunos_extract.py`
- Create: `app/Keraunos/python-dev/test_extract.py`
- Create: `app/Keraunos/python-dev/requirements.txt`

> `python-dev/` sits **outside** the app target folder so it is never bundled.

- [ ] **Step 1: Set up the dev venv**

`app/Keraunos/python-dev/requirements.txt`:
```
yt-dlp
pytest
```
Then:
```bash
cd app/Keraunos/python-dev
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cd /Users/leo/Developer/Keraunos
```
(`.venv/` is already covered by `.gitignore`'s `.swiftpm`/build rules? No — add it.) Append to `.gitignore`:
```
# Python dev venv
app/Keraunos/python-dev/.venv/
__pycache__/
```
Commit that ignore change now:
```bash
git commit -m "chore: ignore python dev venv"
```

- [ ] **Step 2: Write the failing test**

`app/Keraunos/python-dev/test_extract.py`:
```python
import json
import sys
import threading
import http.server
import functools
from pathlib import Path

# Import the bundled module from the app resources folder.
RES = Path(__file__).resolve().parents[1] / "Keraunos" / "PythonRuntime" / "Resources"
sys.path.insert(0, str(RES))
import keraunos_extract  # noqa: E402


def _serve(directory, ready):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
    ready.append(httpd)
    httpd.serve_forever()


def test_resolves_direct_progressive_file(tmp_path):
    # A raw .mp4 served over HTTP is handled by yt-dlp's generic extractor and
    # returned as a single progressive http format (top-level `url`).
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    t = threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True)
    t.start()
    while not ready:
        pass
    port = ready[0].server_address[1]

    out = json.loads(keraunos_extract.extract(f"http://127.0.0.1:{port}/sample.mp4"))
    ready[0].shutdown()

    assert out["ok"] is True
    assert out["direct_url"].endswith("/sample.mp4")


def test_unsupported_url_returns_error_kind():
    out = json.loads(keraunos_extract.extract("https://invalid.invalid/nothing-here"))
    assert out["ok"] is False
    assert out["error_kind"] in {"unsupported", "network"}
```

- [ ] **Step 3: Run it, expect failure**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: FAIL — `ModuleNotFoundError: keraunos_extract`.

- [ ] **Step 4: Implement the module**

`app/Keraunos/Keraunos/PythonRuntime/Resources/keraunos_extract.py`:
```python
"""Keraunos extraction bridge.

Resolves a page URL to a single progressive (already-muxed) media file using
yt-dlp, WITHOUT downloading and WITHOUT ffmpeg. Always returns a JSON string;
never raises, so the Swift C bridge has a single, total contract.
"""
import json

import yt_dlp
from yt_dlp.utils import DownloadError, ExtractorError, UnsupportedError

# Single progressive file: served over http(s), with BOTH audio and video in
# one stream. Excludes HLS and split audio/video that would need ffmpeg.
_FORMAT = "best[protocol^=http][acodec!=none][vcodec!=none]/best[ext=mp4]"

_AUTH_HINTS = ("log in", "sign in", "logged in", "cookies", "nsfw", "age", "sensitive")


def _err(kind, detail=""):
    return json.dumps({"ok": False, "error_kind": kind, "detail": detail})


def extract(url):
    opts = {"quiet": True, "no_warnings": True, "skip_download": True, "format": _FORMAT}
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
            if info.get("_type") == "playlist":
                entries = info.get("entries") or []
                if not entries:
                    return _err("unsupported", "no media in playlist")
                info = entries[0]
            # Separate video+audio streams that need merging show up here.
            if info.get("requested_formats"):
                return _err("needs_ffmpeg", "requires merging separate streams")
            direct = info.get("url")
            if not direct:
                return _err("needs_ffmpeg", "no single progressive url available")
            return json.dumps({
                "ok": True,
                "direct_url": direct,
                "filename": ydl.prepare_filename(info),
                "title": info.get("title") or "",
            })
    except UnsupportedError as e:
        return _err("unsupported", str(e))
    except (DownloadError, ExtractorError) as e:
        msg = str(e).lower()
        if "requested format is not available" in msg:
            return _err("needs_ffmpeg", str(e))
        if any(hint in msg for hint in _AUTH_HINTS):
            return _err("requires_auth", str(e))
        if "unable to download" in msg or "timed out" in msg or "connection" in msg:
            return _err("network", str(e))
        return _err("unsupported", str(e))
    except Exception as e:  # never raise into the bridge
        return _err("runtime", str(e))
```

- [ ] **Step 5: Run it, expect pass**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: 2 passed. (The unsupported test needs network; if offline it may report `network` — still passing per the assertion.)

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(python): add yt-dlp extraction bridge with JSON contract"
```

---

### Task 9: Acquire the embedded Python runtime artifacts

**Files (downloaded, not hand-written):** into `app/Keraunos/Keraunos/PythonRuntime/Resources/`

- [ ] **Step 1: Download Python-Apple-support (Python 3.13, iOS)**

```bash
cd /tmp
gh release download --repo beeware/Python-Apple-support --pattern '*3.13*iOS*.tar.gz' --dir /tmp/pas
ls /tmp/pas
```
If `gh release download` can't pattern-match, list releases with `gh release list --repo beeware/Python-Apple-support` and download the latest `Python-3.13-iOS-support.b*.tar.gz` asset.

- [ ] **Step 2: Extract and inspect the layout**

```bash
mkdir -p /tmp/pas/x && tar -xzf /tmp/pas/*.tar.gz -C /tmp/pas/x
find /tmp/pas/x -maxdepth 2 -type d | sort
```
Expected: a `Python.xcframework` plus a `python-stdlib` directory. **Record the exact stdlib path** — it's referenced in Task 11's interpreter config.

- [ ] **Step 3: Vendor yt-dlp (pure-Python) into site-packages**

```bash
cd app/Keraunos/python-dev
.venv/bin/pip install --target /tmp/pas/site-packages "yt-dlp"
# Drop the C-extension optionals we don't need (keep the tree pure-Python):
rm -rf /tmp/pas/site-packages/Crypto* /tmp/pas/site-packages/brotli* /tmp/pas/site-packages/curl_cffi* 2>/dev/null || true
cd /Users/leo/Developer/Keraunos
```

- [ ] **Step 4: Get the certifi CA bundle**

```bash
.venv_path=app/Keraunos/python-dev/.venv
app/Keraunos/python-dev/.venv/bin/python -c "import certifi,shutil;shutil.copy(certifi.where(),'app/Keraunos/Keraunos/PythonRuntime/Resources/cacert.pem')"
```
(If `certifi` isn't installed in the venv, `pip install certifi` first.)

- [ ] **Step 5: Place stdlib + site-packages into the app resources**

```bash
mkdir -p app/Keraunos/Keraunos/PythonRuntime/Resources/python-stdlib
cp -R /tmp/pas/x/**/python-stdlib/ app/Keraunos/Keraunos/PythonRuntime/Resources/python-stdlib/ 2>/dev/null || \
  cp -R "$(find /tmp/pas/x -type d -name python-stdlib | head -1)/" app/Keraunos/Keraunos/PythonRuntime/Resources/python-stdlib/
mkdir -p app/Keraunos/Keraunos/PythonRuntime/Resources/site-packages
cp -R /tmp/pas/site-packages/ app/Keraunos/Keraunos/PythonRuntime/Resources/site-packages/
# Trim test suites and caches to cut bundle size.
find app/Keraunos/Keraunos/PythonRuntime/Resources -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
```

- [ ] **Step 6: Copy the xcframework into the project**

```bash
cp -R "$(find /tmp/pas/x -type d -name Python.xcframework | head -1)" app/Keraunos/Keraunos/PythonRuntime/
```

- [ ] **Step 7: Decide what to commit** — `python-stdlib/` and `site-packages/` are large but are the app's source of truth, so **commit them** (this is a build-from-source app). `Python.xcframework/` is already gitignored (Task: `.gitignore`), so document how to fetch it. Append to `app/Keraunos/Keraunos/PythonRuntime/README.md`:

```markdown
# PythonRuntime resources

`Python.xcframework/` is NOT committed (large prebuilt binary). To restore it:

1. Download the latest Python 3.13 iOS support package:
   `gh release download --repo beeware/Python-Apple-support --pattern '*3.13*iOS*.tar.gz'`
2. Extract and copy `Python.xcframework` into this folder.

`python-stdlib/`, `site-packages/yt_dlp`, and `cacert.pem` ARE committed.
```

- [ ] **Step 8: Commit (resources only)**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/Resources app/Keraunos/Keraunos/PythonRuntime/README.md
git commit -m "chore(python): vendor stdlib, yt-dlp, and CA bundle for embedding"
```

---

### Task 10: Embed the framework in Xcode (manual GUI)

**Files:** `app/Keraunos/Keraunos.xcodeproj` (changed via Xcode UI)

> These are Xcode GUI actions. Follow exactly; verify at the end.

- [ ] **Step 1: Add the xcframework** — In Xcode, select the **Keraunos** target → **General** → **Frameworks, Libraries, and Embedded Content** → **+** → **Add Other… → Add Files…** → select `app/Keraunos/Keraunos/PythonRuntime/Python.xcframework`. Set it to **Embed & Sign**.

- [ ] **Step 2: Confirm resources are in the bundle** — Because the target uses synchronized groups, `python-stdlib/`, `site-packages/`, `keraunos_extract.py`, and `cacert.pem` under the target folder are added automatically. Verify under **Build Phases → Copy Bundle Resources** that the `PythonRuntime/Resources` items are listed. If folders appear as groups rather than folder references, delete and re-add `Resources` as a **folder reference** (blue folder) so the directory tree is preserved verbatim.

- [ ] **Step 3: Add the "process Python libraries" run-script phase** — Python-Apple-support's release ships an `Add a Run Script` snippet in its `USAGE.md`. In **Build Phases → +
 → New Run Script Phase**, paste the `install_python` script from that release's `USAGE.md`, placed **after** "Embed Frameworks". This converts binary stdlib modules into the framework form iOS requires.

- [ ] **Step 4: Build settings** — Set **User Script Sandboxing = No**; **Enable Testability = Yes** (debug and release). Add the OpenSSL **privacy manifest**: create `app/Keraunos/Keraunos/PythonRuntime/Resources/openssl.xcprivacy` per Python-Apple-support's USAGE (it provides the contents) so the bundled OpenSSL declares its API usage.

- [ ] **Step 5: Verification gate — build only**

```bash
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST"
```
Expected: BUILD SUCCEEDED with the framework embedded. If signing errors mention loose `.so`/`.dylib`, the run-script phase (Step 3) is missing or out of order.

- [ ] **Step 6: Commit**

```bash
git add app/Keraunos/Keraunos.xcodeproj app/Keraunos/Keraunos/PythonRuntime/Resources/openssl.xcprivacy
git commit -m "build(python): embed Python.xcframework and process-libraries phase"
```

---

### Task 11: `PythonBridge` (C-API init + extract)

**Files:**
- Create: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h`
- Create: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m`
- Create: `app/Keraunos/Keraunos/Keraunos-Bridging-Header.h`
- Modify: build setting `SWIFT_OBJC_BRIDGING_HEADER`

> No automated test — embedded Python only runs in the simulator/device. The gate is an in-app smoke check (Step 6) plus Task 13's acceptance.

- [ ] **Step 1: Header**

`app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h`:
```objc
#ifndef PythonBridge_h
#define PythonBridge_h

/// Initializes the embedded interpreter. `home` = absolute path to python-stdlib's
/// parent; `modulePaths` = newline-separated absolute paths added to sys.path;
/// `caCertPath` = absolute path to cacert.pem. Returns 0 on success.
int keraunos_python_init(const char *home, const char *modulePaths, const char *caCertPath);

/// Calls keraunos_extract.extract(url). Returns a malloc'd UTF-8 JSON string the
/// caller must free(). Returns NULL only on a catastrophic bridge failure.
char *keraunos_python_extract(const char *url);

#endif
```

- [ ] **Step 2: Implementation**

`app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m`:
```objc
#import "PythonBridge.h"
#import <Python.h>
#import <string.h>
#import <stdlib.h>

static int gInitialized = 0;

int keraunos_python_init(const char *home, const char *modulePaths, const char *caCertPath) {
    if (gInitialized) return 0;

    // urllib/ssl in the embedded interpreter have no system trust store; point
    // OpenSSL at the bundled CA bundle before the interpreter starts.
    setenv("SSL_CERT_FILE", caCertPath, 1);

    PyConfig config;
    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;

    wchar_t *whome = Py_DecodeLocale(home, NULL);
    PyConfig_SetString(&config, &config.home, whome);

    // Build sys.path from the newline-separated module paths.
    config.module_search_paths_set = 1;
    char *paths = strdup(modulePaths);
    char *line = strtok(paths, "\n");
    while (line) {
        wchar_t *wline = Py_DecodeLocale(line, NULL);
        PyWideStringList_Append(&config.module_search_paths, wline);
        PyMem_RawFree(wline);
        line = strtok(NULL, "\n");
    }
    free(paths);

    PyStatus status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    PyMem_RawFree(whome);
    if (PyStatus_Exception(status)) return -1;

    gInitialized = 1;
    return 0;
}

char *keraunos_python_extract(const char *url) {
    PyGILState_STATE gil = PyGILState_Ensure();
    char *out = NULL;

    PyObject *module = PyImport_ImportModule("keraunos_extract");
    if (module) {
        PyObject *func = PyObject_GetAttrString(module, "extract");
        if (func && PyCallable_Check(func)) {
            PyObject *result = PyObject_CallFunction(func, "s", url);
            if (result) {
                const char *utf8 = PyUnicode_AsUTF8(result);
                if (utf8) out = strdup(utf8);
                Py_DECREF(result);
            }
        }
        Py_XDECREF(func);
        Py_DECREF(module);
    }
    if (!out && PyErr_Occurred()) PyErr_Clear();
    PyGILState_Release(gil);

    if (!out) out = strdup("{\"ok\":false,\"error_kind\":\"runtime\",\"detail\":\"python bridge failure\"}");
    return out;
}
```

- [ ] **Step 3: Bridging header**

`app/Keraunos/Keraunos/Keraunos-Bridging-Header.h`:
```objc
#import "PythonRuntime/PythonBridge.h"
```
In Xcode, set the target build setting **Objective-C Bridging Header** to `Keraunos/Keraunos-Bridging-Header.h`. Add the `Python.xcframework` headers to **Header Search Paths** if `#import <Python.h>` is not found (the framework exposes them; usually automatic when embedded).

- [ ] **Step 4: Verification gate — build**

```bash
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST"
```
Expected: BUILD SUCCEEDED. Failures here are almost always `Python.h` not found (fix Header Search Paths) or bridging-header path wrong.

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m app/Keraunos/Keraunos/Keraunos-Bridging-Header.h app/Keraunos/Keraunos.xcodeproj
git commit -m "feat(python): add C-API bridge for interpreter init and extract"
```

---

### Task 12: `PythonExtractor` (implements `MediaExtracting`)

**Files:**
- Create: `app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`
- Modify: `app/Keraunos/Keraunos/ContentView.swift`

- [ ] **Step 1: Implement the extractor**

`app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`:
```swift
import Foundation

/// Runs yt-dlp extraction inside the embedded interpreter. The synchronous Python
/// C calls are serialized onto a dedicated serial queue (the GIL is process-wide)
/// and bridged to async, so they never block a Swift cooperative-pool thread.
/// `@unchecked Sendable` is justified: all mutable state is confined to `queue`.
nonisolated final class PythonExtractor: MediaExtracting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.lilikazine.Keraunos.python")
    // Confined to `queue` — only read/written inside the queue.async block below.
    nonisolated(unsafe) private var initialized = false

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ResolvedMedia, Error>) in
            queue.async { [self] in
                do {
                    try ensureInitialized()
                    continuation.resume(returning: try runExtract(url))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// MUST run on `queue`.
    private func ensureInitialized() throws {
        guard !initialized else { return }
        guard let resources = Bundle.main.resourceURL else {
            throw KeraunosError.runtime(detail: "no resource bundle")
        }
        let stdlib = resources.appendingPathComponent("python-stdlib")
        let sitePackages = resources.appendingPathComponent("site-packages")
        let appModules = resources // keraunos_extract.py sits at the resources root
        let caCert = resources.appendingPathComponent("cacert.pem")

        let modulePaths = [stdlib.path, sitePackages.path, appModules.path].joined(separator: "\n")
        let status = keraunos_python_init(resources.path, modulePaths, caCert.path)
        guard status == 0 else { throw KeraunosError.runtime(detail: "python init failed (\(status))") }
        initialized = true
    }

    /// MUST run on `queue`.
    private func runExtract(_ url: URL) throws -> ResolvedMedia {
        guard let cString = keraunos_python_extract(url.absoluteString) else {
            throw KeraunosError.runtime(detail: "null extraction result")
        }
        defer { free(cString) }
        let json = Data(String(cString: cString).utf8)
        return try ExtractionDecoder.decode(json)
    }
}
```

> Note: the `python-stdlib` path here must match what Task 9 Step 2 recorded. If the support package nests the stdlib differently, adjust `stdlib`/`home` accordingly.

- [ ] **Step 2: Swap the mock for the real extractor** — in `app/Keraunos/Keraunos/ContentView.swift`, change the extractor:

```swift
import SwiftUI

struct ContentView: View {
    var body: some View {
        DownloadScreen(model: DownloadViewModel(
            extractor: PythonExtractor(),
            downloader: Downloader(),
            store: DownloadStore()))
    }
}

#Preview {
    // Preview keeps the mock so canvas rendering needs no interpreter.
    DownloadScreen(model: DownloadViewModel(
        extractor: MockExtractor(),
        downloader: Downloader(),
        store: DownloadStore()))
}
```

- [ ] **Step 3: Build + run unit tests** (they still use the mock, must stay green)

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests
```
Expected: TEST SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift app/Keraunos/Keraunos/ContentView.swift
git commit -m "feat(python): add PythonExtractor and wire it into the app"
```

---

## Phase 5 — End-to-end acceptance

### Task 13: Manual acceptance against real videos

**Files:** none (manual verification; capture results in a log)

- [ ] **Step 1: Interpreter smoke test** — Run the app in the simulator. Add a temporary debug button (or use the URL field) to resolve a direct test MP4 over HTTPS, e.g. a small known-good `.mp4` URL. Confirm it downloads and appears in the Downloads list. This proves interpreter init + SSL (certifi) + urllib all work end-to-end.

- [ ] **Step 2: Real X progressive video** — Paste a public, non-sensitive X post URL that contains a video. Expected: it resolves, downloads, and the `.mp4` appears in the list and in the Files app under the app's folder.

- [ ] **Step 3: HLS-only / unsupported case** — Paste an X post whose video is HLS-only (or a clearly unsupported link). Expected: a clear `.needsFfmpeg` ("format-merging support, coming later") or `.unsupported` message — not a crash or a cryptic error.

- [ ] **Step 4: Record results** — Create `docs/logs/2026-06-15-01-milestone-1-acceptance.md` noting: device/sim + iOS version, the URLs tried, outcomes, bundle size of the built `.app` (`du -sh` the product), and any X guest-token flakiness observed. Commit:

```bash
git add docs/logs/2026-06-15-01-milestone-1-acceptance.md
git commit -m "docs(log): record Milestone 1 acceptance results"
```

- [ ] **Step 5: Milestone 1 done check** — Confirm all five definition-of-done items from the spec §7 hold:
  1. App builds/launches with embedded Python, SSL verified (Step 1).
  2. Single screen with URL field, Download button, working indicator, file list (Phase 3).
  3. Public progressive MP4 (incl. an X post) downloads to Documents, visible in Files (Step 2).
  4. Errors surface clearly, especially `.needsFfmpeg` / `.requiresAuth` (Step 3).
  5. Unit tests + Python dev tests green (Tasks 2–8).

---

## Self-Review notes (for the executor)

- **Spec coverage:** components `PythonRuntime` (Tasks 9–12), `Extractor`/`PythonExtractor` (Tasks 4, 8, 12), `Downloader` (Task 5), `DownloadStore` (Task 6), UI (Task 7); data flow (Tasks 7+12); error mapping incl. `.needsFfmpeg`/`.requiresAuth` (Tasks 2, 8); testing strategy — pure-Swift unit (Tasks 2,3,5,6,7), Python dev test against localhost (Task 8), manual acceptance (Task 13); Milestone-1 done (Task 13 Step 5). The "extract in Python, download in Swift" split is realized by `PythonExtractor` resolving only + `Downloader` transferring.
- **Known soft spots to verify during execution (not placeholders — verification gates):** the exact `python-stdlib` path inside the support package (Task 9 Step 2 → used in Task 12); the precise `install_python` run-script and `openssl.xcprivacy` contents (taken verbatim from the release's `USAGE.md`, Task 10); yt-dlp's exact `requested_formats`/"requested format is not available" behavior for X HLS posts (Task 8 maps both to `.needsFfmpeg`; confirm in Task 13 Step 3).
- **Deferred (NOT in Milestone 1):** ffmpeg/HLS merge, Share Sheet, format picker, queue/history, audio-only, cookies/auth.
```
