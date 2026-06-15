# Keraunos Milestone 1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Paste a public X (Twitter) video URL → the app resolves a progressive MP4 via embedded yt-dlp → downloads it with native URLSession → the `.mp4` appears in the app's Documents folder (visible in the Files app).

**Architecture:** Two modules. **`KeraunosCore`** — a local SwiftPM package (default `nonisolated` isolation) holding all non-UI logic: error types, the resolved-media model + decoder, the `MediaExtracting` protocol + `MockExtractor`, the `Downloader`, and `DownloadStore`. **`Keraunos`** — the app target (main-actor-by-default) holding the SwiftUI screen + view model, the embedded-CPython runtime, and the one concrete `PythonExtractor`. Embedded CPython runs yt-dlp for **extraction only** (returns a direct media URL + metadata as JSON); native `URLSession` performs the transfer. The whole app is built behind `MediaExtracting` so the UI/download/storage are implemented and tested before Python is embedded; a `MockExtractor` stands in until the real `PythonExtractor` lands.

**Tech Stack:** Swift 6 language mode (complete data-race safety), SwiftUI, Swift Testing, Xcode 26.5 (Swift 6.3 toolchain, file-system-synchronized groups), iOS 26.5 deployment target, a local SwiftPM package for the core, embedded CPython 3.13 via BeeWare Python-Apple-support, yt-dlp (pure-Python, vendored), certifi.

> **Why a module:** the app target is **main-actor-by-default** (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) — ideal for UI. The non-UI logic must run off the main actor, which in a single target would mean marking each type `nonisolated`. Instead it lives in `KeraunosCore`, whose default isolation is `nonisolated`, so those types need **no isolation annotations at all**. The cost is `public` API markers on the package's surface (intentional API design, not isolation friction). The one off-main component is `PythonExtractor` — an `actor` with a custom serial executor (Task 13), in the app target.

---

## Conventions (read once)

- **Repo root:** `/Users/leo/Developer/Keraunos`. Run all commands from there unless stated.
- **App project / scheme:** `app/Keraunos/Keraunos.xcodeproj`, scheme `Keraunos`.
- **Core package:** `app/KeraunosCore` (local SwiftPM package).
- **Adding files:** the app target uses **file-system-synchronized groups** — a `.swift` file under `app/Keraunos/Keraunos/` auto-joins the app target; under `app/Keraunos/KeraunosTests/` auto-joins the app test target. A SwiftPM package likewise compiles every file under `Sources/<target>/` and `Tests/<target>/`. **No `pbxproj`/manifest edits needed to add source files** (the one exception: adding the package dependency itself, Task 2).
- **Core test command** (fast — runs on macOS, no simulator):
  ```bash
  swift test --package-path app/KeraunosCore
  ```
  Single suite: `swift test --package-path app/KeraunosCore --filter KeraunosErrorTests`.
- **App test command** (define `DEST` once):
  ```bash
  DEST='platform=iOS Simulator,name=iPhone 17'
  xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests
  ```
  If `iPhone 17` is unavailable, pick one from `xcrun simctl list devices available | grep iPhone`.
- **Isolation rule:** `KeraunosCore` is `nonisolated`-default — write plain declarations, add `public` for API and `Sendable` where values cross actors. The app target is main-actor-default — UI gets `@MainActor` for free; the one off-main component, `PythonExtractor`, is an `actor` with a custom serial executor. Test suites touching the main-actor view model are `@MainActor` (`DownloadViewModelTests`); a suite mutating shared global state is `@Suite(.serialized)` (`DownloaderTests`).
- **Running blocking work off-actor (Swift 6.2):** a `nonisolated async` method *inherits the caller's isolation*, and a plain `actor` runs on the *cooperative pool* — neither is safe for a multi-second blocking call. Pick by the shape of the work:
  - **Blocking and/or must be serialized** (the Python interpreter call): an `actor` with a **custom serial executor** backed by a `DispatchSerialQueue` (`PythonExtractor`, Task 13). Its jobs run on a dedicated thread (safe to block) and actor isolation serializes access + protects state — no `nonisolated(unsafe)`, continuations, or `@unchecked Sendable`.
  - **Non-blocking, parallel-safe CPU work:** `@concurrent`.
  - **Neither** — `Downloader.download`: `await session.download(...)` suspends rather than blocking and `moveItem` is a fast rename, so running its glue on the caller (the main-actor view model) is fine.
- **Commits:** use the `structured-commit` skill. The `git commit` lines give the summary line; let the skill expand the body.
- **TDD:** every code task is test-first. Run the test, see it fail, implement, see it pass, commit.

---

## File Structure

```
app/KeraunosCore/                         # local SwiftPM package — nonisolated default
  Package.swift                           # Task 2
  Sources/KeraunosCore/
    KeraunosError.swift                   # Task 3
    ResolvedMedia.swift                   # Task 4 (ResolvedMedia + ExtractionResult + decoder)
    MediaExtracting.swift                 # Task 5 (protocol + MockExtractor)
    Downloader.swift                      # Task 6
    DownloadStore.swift                   # Task 7
  Tests/KeraunosCoreTests/
    KeraunosErrorTests.swift              # Task 3
    ExtractionDecodingTests.swift         # Task 4
    StubURLProtocol.swift                 # Task 6 (test helper)
    DownloaderTests.swift                 # Task 6
    DownloadStoreTests.swift              # Task 7

app/Keraunos/Keraunos/                    # app target — main-actor-by-default
  KeraunosApp.swift                       # @main (exists)
  ContentView.swift                       # replaced: composition root (exists)
  UI/
    DownloadViewModel.swift               # Task 8
    DownloadScreen.swift                  # Task 8
  PythonRuntime/                          # b14 layout (see docs/logs/2026-06-15-01)
    app/
      keraunos_extract.py                 # Task 9 (also dev-tested outside the app)
      cacert.pem                          # Task 10 (certifi bundle)
    app_packages/yt_dlp/...               # Task 10 (vendored pure-Python yt-dlp)
    Python.xcframework/...                # Task 10 (gitignored; stdlib lives inside)
    PythonBridge.h / PythonBridge.m       # Task 12 (C-API init + extract)
    PythonExtractor.swift                 # Task 13 (implements KeraunosCore.MediaExtracting)
  Keraunos-Bridging-Header.h              # Task 12

app/Keraunos/KeraunosTests/
  DownloadViewModelTests.swift            # Task 8

app/Keraunos/python-dev/                  # dev-only, NOT bundled
  test_extract.py                         # Task 9
  requirements.txt                        # Task 9
```

---

## Phase 0 — Baseline & module

### Task 1: Confirm the scaffold builds and tests green

**Files:** none (verification only)

- [ ] **Step 1: Build for the simulator**

```bash
DEST='platform=iOS Simulator,name=iPhone 17'
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST"
```
Expected: `** BUILD SUCCEEDED **`. Resolve simulator/toolchain issues before proceeding.

- [ ] **Step 2: Remove the placeholder template test** — replace the contents of `app/Keraunos/KeraunosTests/KeraunosTests.swift` with:

```swift
import Testing
@testable import Keraunos

// App-target suites live alongside this file (e.g. DownloadViewModelTests).
```

- [ ] **Step 3: Commit**

```bash
git commit -m "test: clear template test, confirm baseline build"
```

---

### Task 2: Create the `KeraunosCore` local package and link it

**Files:**
- Create: `app/KeraunosCore/Package.swift`
- Create: `app/KeraunosCore/Sources/KeraunosCore/KeraunosCore.swift` (temporary placeholder)
- Modify: `app/Keraunos/Keraunos.xcodeproj` (add local package dependency — Xcode UI)

- [ ] **Step 1: Write the package manifest**

`app/KeraunosCore/Package.swift`:
```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KeraunosCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "KeraunosCore", targets: ["KeraunosCore"]),
    ],
    targets: [
        .target(
            name: "KeraunosCore",
            swiftSettings: [.swiftLanguageMode(.v6)]   // Swift 6 mode; default isolation stays `nonisolated`
        ),
        .testTarget(
            name: "KeraunosCoreTests",
            dependencies: ["KeraunosCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
```
> Note: do NOT add `.defaultIsolation(MainActor.self)` — leaving it unset is what keeps the package `nonisolated`-by-default. If `.iOS(.v26)`/`.macOS(.v26)` aren't recognized by your tools, drop to the highest symbols available (e.g. `.v18`/`.v15`); they only set the package's minimum.

- [ ] **Step 2: Add a placeholder source so the package compiles**

`app/KeraunosCore/Sources/KeraunosCore/KeraunosCore.swift`:
```swift
// KeraunosCore — non-UI logic for Keraunos. Types are added in Tasks 3–7.
```

- [ ] **Step 3: Verify the package builds and its (empty) tests run**

```bash
swift build --package-path app/KeraunosCore
swift test --package-path app/KeraunosCore
```
Expected: build succeeds; test run reports 0 tests (no failures).

- [ ] **Step 4: Add the package to the app (Xcode UI)** — In Xcode: **File → Add Package Dependencies… → Add Local…**, select `app/KeraunosCore`, **Add Package**, and add the **KeraunosCore** library product to the **Keraunos** app target. Confirm under the target's **General → Frameworks, Libraries, and Embedded Content** that `KeraunosCore` is listed.

- [ ] **Step 5: Verify the app still builds with the dependency**

```bash
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST"
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore app/Keraunos/Keraunos.xcodeproj
git commit -m "build(core): add KeraunosCore local SwiftPM package and link it"
```

---

## Phase 1 — Core domain (`KeraunosCore`, `swift test`)

### Task 3: `KeraunosError`

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/KeraunosError.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/KeraunosErrorTests.swift`

- [ ] **Step 1: Write the failing test**

`app/KeraunosCore/Tests/KeraunosCoreTests/KeraunosErrorTests.swift`:
```swift
import Testing
import Foundation
import KeraunosCore

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
swift test --package-path app/KeraunosCore --filter KeraunosErrorTests
```
Expected: FAIL — `cannot find 'KeraunosError' in scope`.

- [ ] **Step 3: Implement**

`app/KeraunosCore/Sources/KeraunosCore/KeraunosError.swift`:
```swift
import Foundation

/// All failures surfaced to the UI. Python exceptions are mapped to these at the
/// extraction boundary so nothing above the boundary sees a Python object.
public enum KeraunosError: Error, Equatable {
    case unsupported
    case needsFfmpeg
    case requiresAuth
    case network
    case runtime(detail: String)
    case cancelled
}

public extension KeraunosError {
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

extension KeraunosError: LocalizedError {
    public var errorDescription: String? {
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

- [ ] **Step 4: Run it, expect pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(core): add KeraunosError with kind mapping and messages"
```

---

### Task 4: `ResolvedMedia` + extraction-result decoding

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/ResolvedMedia.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/ExtractionDecodingTests.swift`

The Python module returns `{"ok":true,"direct_url":"…","filename":"…","title":"…"}` on success, or `{"ok":false,"error_kind":"needs_ffmpeg","detail":"…"}` on failure.

- [ ] **Step 1: Write the failing test**

`app/KeraunosCore/Tests/KeraunosCoreTests/ExtractionDecodingTests.swift`:
```swift
import Testing
import Foundation
import KeraunosCore

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
swift test --package-path app/KeraunosCore --filter ExtractionDecodingTests
```
Expected: FAIL — `cannot find 'ResolvedMedia'` / `ExtractionDecoder`.

- [ ] **Step 3: Implement**

`app/KeraunosCore/Sources/KeraunosCore/ResolvedMedia.swift`:
```swift
import Foundation

/// A resolved, directly-downloadable media file (a single progressive stream).
public struct ResolvedMedia: Equatable, Sendable {
    public let directURL: URL
    public let suggestedFilename: String
    public let title: String

    public init(directURL: URL, suggestedFilename: String, title: String) {
        self.directURL = directURL
        self.suggestedFilename = suggestedFilename
        self.title = title
    }
}

/// Wire format returned by the Python extraction module.
private struct ExtractionResult: Decodable {
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
public enum ExtractionDecoder {
    public static func decode(_ data: Data) throws -> ResolvedMedia {
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

- [ ] **Step 4: Run it, expect pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(core): add ResolvedMedia and extraction-result decoder"
```

---

### Task 5: `MediaExtracting` protocol + `MockExtractor`

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/MediaExtracting.swift`

No dedicated test (a protocol + a test double); exercised by Tasks 6/8.

- [ ] **Step 1: Implement**

`app/KeraunosCore/Sources/KeraunosCore/MediaExtracting.swift`:
```swift
import Foundation

/// Resolves a page URL to a directly-downloadable media file. The real
/// implementation (PythonExtractor, in the app target) arrives in Phase 4;
/// until then the app and tests use MockExtractor.
public protocol MediaExtracting: Sendable {
    func resolve(_ url: URL) async throws -> ResolvedMedia
}

/// Deterministic test/preview double.
public struct MockExtractor: MediaExtracting {
    public var result: Result<ResolvedMedia, KeraunosError>

    public init(result: Result<ResolvedMedia, KeraunosError> = .success(
        ResolvedMedia(directURL: URL(string: "https://example.com/sample.mp4")!,
                      suggestedFilename: "sample.mp4",
                      title: "Sample"))) {
        self.result = result
    }

    public func resolve(_ url: URL) async throws -> ResolvedMedia {
        try result.get()
    }
}
```

- [ ] **Step 2: Build the package**

```bash
swift build --package-path app/KeraunosCore
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git commit -m "feat(core): add MediaExtracting protocol and MockExtractor"
```

---

## Phase 2 — Core download

### Task 6: `Downloader` (URLSession transfer)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/Downloader.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/DownloaderTests.swift`
- Test helper: `app/KeraunosCore/Tests/KeraunosCoreTests/StubURLProtocol.swift`

- [ ] **Step 1: Write the test helper**

`app/KeraunosCore/Tests/KeraunosCoreTests/StubURLProtocol.swift`:
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

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}
```

- [ ] **Step 2: Write the failing test**

`app/KeraunosCore/Tests/KeraunosCoreTests/DownloaderTests.swift`:
```swift
import Testing
import Foundation
import KeraunosCore

@Suite(.serialized)   // mutates the shared StubURLProtocol.handler; tests run in parallel by default
struct DownloaderTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func savesFileToDestinationWithSuggestedName() async throws {
        let payload = Data("fake mp4 bytes".utf8)
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        let dir = tempDir()
        let saved = try await Downloader(session: StubURLProtocol.session()).download(media, to: dir)

        #expect(saved.lastPathComponent == "clip.mp4")
        #expect(try Data(contentsOf: saved) == payload)
    }

    @Test func mapsHTTPErrorToNetwork() async throws {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        await #expect(throws: KeraunosError.network) {
            try await Downloader(session: StubURLProtocol.session()).download(media, to: tempDir())
        }
    }

    @Test func mapsCancellationToCancelled() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        let media = ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                  suggestedFilename: "clip.mp4", title: "t")
        await #expect(throws: KeraunosError.cancelled) {
            try await Downloader(session: StubURLProtocol.session()).download(media, to: tempDir())
        }
    }
}
```

- [ ] **Step 3: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter DownloaderTests
```
Expected: FAIL — `cannot find 'Downloader'`.

- [ ] **Step 4: Implement**

`app/KeraunosCore/Sources/KeraunosCore/Downloader.swift`:
```swift
import Foundation

public protocol FileDownloading: Sendable {
    func download(_ media: ResolvedMedia, to destinationDirectory: URL) async throws -> URL
}

/// Downloads a resolved media file with URLSession and moves it into place.
/// Milestone 1: simple await-to-completion. Background sessions come later.
public struct Downloader: FileDownloading {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ media: ResolvedMedia, to destinationDirectory: URL) async throws -> URL {
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

- [ ] **Step 5: Run it, expect pass** — same command as Step 3. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(core): add URLSession-based Downloader with error mapping"
```

---

### Task 7: `DownloadStore` (Documents listing)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/DownloadStore.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/DownloadStoreTests.swift`

- [ ] **Step 1: Write the failing test**

`app/KeraunosCore/Tests/KeraunosCoreTests/DownloadStoreTests.swift`:
```swift
import Testing
import Foundation
import KeraunosCore

struct DownloadStoreTests {
    @Test func listsOnlyMP4FilesSorted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("b.mp4"))
        try Data().write(to: dir.appendingPathComponent("a.mp4"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))

        let names = DownloadStore(directory: dir).savedFiles().map(\.lastPathComponent)
        #expect(names == ["a.mp4", "b.mp4"])
    }

    @Test func defaultDirectoryIsDocuments() {
        #expect(DownloadStore().directory.path.contains("/Documents"))
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter DownloadStoreTests
```
Expected: FAIL — `cannot find 'DownloadStore'`.

- [ ] **Step 3: Implement**

`app/KeraunosCore/Sources/KeraunosCore/DownloadStore.swift`:
```swift
import Foundation

/// Owns the download destination and lists finished downloads.
public struct DownloadStore {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory = directory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    public func savedFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents
            .filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
```

- [ ] **Step 4: Run it, expect pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Run the whole Core suite**

```bash
swift test --package-path app/KeraunosCore
```
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(core): add DownloadStore for Documents listing"
```

---

## Phase 3 — App UI (wired to the mock)

### Task 8: `DownloadViewModel` + `DownloadScreen`

**Files:**
- Create: `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`
- Create: `app/Keraunos/Keraunos/UI/DownloadScreen.swift`
- Modify: `app/Keraunos/Keraunos/ContentView.swift`
- Test: `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`

> App target is main-actor-by-default, so the view model and views need no isolation annotations. They `import KeraunosCore`.

- [ ] **Step 1: Write the failing test**

`app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`:
```swift
import Testing
import Foundation
import KeraunosCore
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
struct SpyDownloader: FileDownloading {
    enum Behavior: Sendable { case succeed(URL); case fail(KeraunosError) }
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
import KeraunosCore

@Observable
final class DownloadViewModel {   // main-actor by default (app target)
    var urlText: String = ""
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var lastSavedName: String?
    private(set) var savedFiles: [URL] = []

    private let extractor: any MediaExtracting
    private let downloader: any FileDownloading
    private let store: DownloadStore

    init(extractor: any MediaExtracting, downloader: any FileDownloading, store: DownloadStore) {
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

- [ ] **Step 4: Run it, expect pass** — same command as Step 2. Expected: PASS.

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

- [ ] **Step 6: Wire it in** — replace the contents of `app/Keraunos/Keraunos/ContentView.swift`:

```swift
import SwiftUI
import KeraunosCore

struct ContentView: View {
    var body: some View {
        // Milestone 1 uses the mock extractor until PythonExtractor is wired in (Task 13).
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

- [ ] **Step 7: Build + run the app test suite**

```bash
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests
```
Expected: TEST SUCCEEDED.

- [ ] **Step 8: Manual check** — run the app (Xcode ▶). With the mock extractor, the screen, working state, and error display should render; a real download will fail with a network error against the placeholder URL (expected at this stage).

- [ ] **Step 9: Commit**

```bash
git commit -m "feat(ui): add DownloadScreen + DownloadViewModel wired to mock extractor"
```

---

## Phase 4 — Embedded Python extraction

> Procedural Xcode steps that can't be code; each ends with a verification gate. Do not skip the gates.

> **⚠️ Updated for Python-Apple-support `3.13-b14` (2026-06-15).** The current release
> uses a single-xcframework layout (stdlib *inside* `Python.xcframework`), not the
> `python-stdlib/`+`site-packages/` layout this phase was first drafted against. The
> bundle is now `Python.xcframework` + `app/` (our `.py` + `cacert.pem`) +
> `app_packages/` (vendored yt-dlp), and the C bridge uses `PYTHONHOME=<res>/python`
> + `site.addsitedir` instead of manual `module_search_paths`. The Task 10/12/13
> bodies below have been revised to match; rationale and the exact deltas are in
> **`docs/logs/2026-06-15-01-python-apple-support-b14-integration.md`**. The
> committed `app/Keraunos/Keraunos/PythonRuntime/*` files are the source of truth.

### Task 9: `keraunos_extract.py` — TDD with system Python

**Files:**
- Create: `app/Keraunos/Keraunos/PythonRuntime/Resources/keraunos_extract.py`
- Create: `app/Keraunos/python-dev/test_extract.py`
- Create: `app/Keraunos/python-dev/requirements.txt`

> `python-dev/` sits outside the app target folder so it is never bundled.

- [ ] **Step 1: Set up the dev venv**

`app/Keraunos/python-dev/requirements.txt`:
```
yt-dlp
pytest
certifi
```
Then:
```bash
cd app/Keraunos/python-dev
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cd /Users/leo/Developer/Keraunos
```
Append to `.gitignore`:
```
# Python dev venv
app/Keraunos/python-dev/.venv/
__pycache__/
```
Commit:
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

RES = Path(__file__).resolve().parents[1] / "Keraunos" / "PythonRuntime" / "Resources"
sys.path.insert(0, str(RES))
import keraunos_extract  # noqa: E402


def _serve(directory, ready):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
    ready.append(httpd)
    httpd.serve_forever()


def test_resolves_direct_progressive_file(tmp_path):
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True).start()
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

# Single progressive file: served over http(s), BOTH audio and video in one
# stream. Excludes HLS and split audio/video that would need ffmpeg.
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
Expected: 2 passed. (If offline, the unsupported test may report `network` — still passes.)

- [ ] **Step 6: Commit**

```bash
git commit -m "feat(python): add yt-dlp extraction bridge with JSON contract"
```

---

### Task 10: Acquire the embedded Python runtime artifacts

**Files (downloaded, not hand-written):** into `app/Keraunos/Keraunos/PythonRuntime/Resources/`

> **b14 revision.** No `python-stdlib`/`site-packages` to copy — the stdlib stays
> inside `Python.xcframework` and is unpacked by the build phase (Task 11). We only
> vendor our own module + yt-dlp + the CA bundle into `app/` and `app_packages/`.

- [ ] **Step 1: Download Python-Apple-support (Python 3.13, iOS)**

```bash
gh release view 3.13-b14 --repo beeware/Python-Apple-support --json assets --jq '.assets[].name'
cd /tmp && rm -rf pas && mkdir pas
gh release download 3.13-b14 --repo beeware/Python-Apple-support --pattern 'Python-3.13-iOS-support.b14.tar.gz' --dir /tmp/pas
```
If `3.13-b14` is superseded, `gh release list --repo beeware/Python-Apple-support` and pick the newest `3.13-b*`.

- [ ] **Step 2: Extract and confirm the layout**

```bash
mkdir -p /tmp/pas/x && tar -xzf /tmp/pas/*.tar.gz -C /tmp/pas/x
ls /tmp/pas/x/Python.xcframework            # build/ ios-arm64 ios-arm64_x86_64-simulator lib ...
ls /tmp/pas/x/Python.xcframework/build      # utils.sh + dylib Info template — used by Task 11
```
Expected: a `Python.xcframework` containing `build/utils.sh`. There is **no** top-level `python-stdlib`.

- [ ] **Step 3: Vendor yt-dlp (pure-Python) into `app_packages/`**

```bash
PR=app/Keraunos/Keraunos/PythonRuntime
mkdir -p "$PR/app" "$PR/app_packages"
app/Keraunos/python-dev/.venv/bin/pip install --target "$PR/app_packages" "yt-dlp"
rm -rf "$PR/app_packages"/Crypto* "$PR/app_packages"/brotli* "$PR/app_packages"/curl_cffi* "$PR/app_packages"/bin "$PR/app_packages"/share 2>/dev/null || true
```

- [ ] **Step 4: Get the certifi CA bundle (into `app/`)**

```bash
app/Keraunos/python-dev/.venv/bin/python -c "import certifi,shutil;shutil.copy(certifi.where(),'$PR/app/cacert.pem')"
```

- [ ] **Step 5: Move the extraction module into `app/`** (Task 9 created it under `Resources/`)

```bash
git mv "$PR/Resources/keraunos_extract.py" "$PR/app/keraunos_extract.py" && rmdir "$PR/Resources" 2>/dev/null || true
# update python-dev/test_extract.py sys.path: ".../PythonRuntime/app", then re-run pytest (2 passed)
find "$PR/app" "$PR/app_packages" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
```

- [ ] **Step 6: Copy the xcframework into the app (gitignored)**

```bash
cp -R /tmp/pas/x/Python.xcframework "$PR/Python.xcframework"
```

- [ ] **Step 7: Document the non-committed framework** — rewrite `PythonRuntime/README.md` for the b14 layout (restore steps for `Python.xcframework`; note `app/`, `app_packages/yt_dlp`, `cacert.pem`, `keraunos_extract.py` ARE committed).

- [ ] **Step 8: Commit (resources only; xcframework is ignored)**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/app app/Keraunos/Keraunos/PythonRuntime/app_packages app/Keraunos/Keraunos/PythonRuntime/README.md app/Keraunos/python-dev/test_extract.py
git commit -m "chore(python): vendor yt-dlp + CA bundle for b14 embedding"
```

---

### Task 11: Embed the framework in Xcode (manual GUI)

**Files:** `app/Keraunos/Keraunos.xcodeproj` (changed via Xcode UI)

- [ ] **Step 1: Add the xcframework** — Keraunos target → **General → Frameworks, Libraries, and Embedded Content → + → Add Other… → Add Files…** → `app/Keraunos/Keraunos/PythonRuntime/Python.xcframework`. Set **Embed & Sign**.

- [ ] **Step 2: Add `app` and `app_packages` as folder references** — The file-system-synchronized group already includes `PythonRuntime/`, but `app/` and `app_packages/` must reach the bundle **root** as `app`/`app_packages` (the bridge expects `<resources>/app` and `<resources>/app_packages`). Add each to **Build Phases → Copy Bundle Resources** as a **folder reference** (blue folder), named exactly `app` and `app_packages`. (b14: there is no `python-stdlib` to bundle — the next step unpacks it.)

- [ ] **Step 3: Add the "process Python libraries" run-script phase** — Add a **New Run Script Phase** placed **after** "Embed Frameworks" with (paths relative to `$PROJECT_DIR` = `app/Keraunos`):

```sh
set -e
source "$PROJECT_DIR/Keraunos/PythonRuntime/Python.xcframework/build/utils.sh"
install_python "Keraunos/PythonRuntime/Python.xcframework" "Keraunos/PythonRuntime/app" "Keraunos/PythonRuntime/app_packages"
```
This copies the stdlib out of the xcframework into `<bundle>/python/lib/python3.13` and processes binary modules into the form iOS requires. Uncheck "Based on dependency analysis".

- [ ] **Step 4: Build settings** — **User Script Sandboxing = No**; **Enable Testability = Yes** (debug + release). Add the OpenSSL privacy manifest `app/Keraunos/Keraunos/PythonRuntime/Resources/openssl.xcprivacy` per the release's USAGE.

- [ ] **Step 5: Verification gate — build**

```bash
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST"
```
Expected: BUILD SUCCEEDED with the framework embedded. Signing errors about loose `.so`/`.dylib` mean the run-script (Step 3) is missing or out of order.

- [ ] **Step 6: Commit**

```bash
git add app/Keraunos/Keraunos.xcodeproj app/Keraunos/Keraunos/PythonRuntime/Resources/openssl.xcprivacy
git commit -m "build(python): embed Python.xcframework and process-libraries phase"
```

---

### Task 12: `PythonBridge` (C-API init + extract)

**Files:**
- Create: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h`
- Create: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m`
- Create: `app/Keraunos/Keraunos/Keraunos-Bridging-Header.h`
- Modify: build setting `SWIFT_OBJC_BRIDGING_HEADER`

- [ ] **Step 1: Header**

`app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h`:
```objc
#ifndef PythonBridge_h
#define PythonBridge_h

/// Initializes the embedded interpreter (b14 layout). `resourcePath` = the app
/// bundle's resource root; stdlib at <resourcePath>/python (PYTHONHOME), pip
/// packages at <resourcePath>/app_packages, our module at <resourcePath>/app.
/// `caCertPath` = cacert.pem. Returns 0 on success.
int keraunos_python_init(const char *resourcePath, const char *caCertPath);

/// Calls keraunos_extract.extract(url). Returns a malloc'd UTF-8 JSON string the
/// caller must free(). Returns NULL only on catastrophic bridge failure.
char *keraunos_python_extract(const char *url);

#endif
```

- [ ] **Step 2: Implementation**

`app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m`:
> **b14 init** (see the committed `PythonBridge.m` for the source of truth). Follows
> the release testbed: `PyPreConfig` (utf8) → `Py_PreInitialize` → home =
> `<resources>/python` → `PyConfig_Read` → `Py_InitializeFromConfig` → append
> `<resources>/app_packages` and `<resources>/app` to `sys.path`. Imports use
> `#import <Python/Python.h>` (framework header), not `<Python.h>`.

```objc
#import "PythonBridge.h"
#import <Python/Python.h>
#import <string.h>
#import <stdlib.h>

static int gInitialized = 0;

static int append_sys_path(const char *path) {
    PyObject *sys_path = PySys_GetObject("path");   // borrowed
    if (!sys_path) return -1;
    PyObject *entry = PyUnicode_FromString(path);
    if (!entry) return -1;
    int rc = PyList_Append(sys_path, entry);
    Py_DECREF(entry);
    return rc;
}

int keraunos_python_init(const char *resourcePath, const char *caCertPath) {
    if (gInitialized) return 0;
    setenv("SSL_CERT_FILE", caCertPath, 1);   // embedded ssl has no system trust store

    PyStatus status;
    PyPreConfig preconfig;
    PyConfig config;

    PyPreConfig_InitIsolatedConfig(&preconfig);
    preconfig.utf8_mode = 1;
    status = Py_PreInitialize(&preconfig);
    if (PyStatus_Exception(status)) return -1;

    PyConfig_InitIsolatedConfig(&config);
    config.write_bytecode = 0;

    char home[PATH_MAX];
    snprintf(home, sizeof(home), "%s/python", resourcePath);
    wchar_t *whome = Py_DecodeLocale(home, NULL);
    if (!whome) { PyConfig_Clear(&config); return -2; }
    status = PyConfig_SetString(&config, &config.home, whome);
    PyMem_RawFree(whome);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return -3; }

    status = PyConfig_Read(&config);
    if (PyStatus_Exception(status)) { PyConfig_Clear(&config); return -4; }

    status = Py_InitializeFromConfig(&config);
    PyConfig_Clear(&config);
    if (PyStatus_Exception(status)) return -5;

    char appPackages[PATH_MAX], app[PATH_MAX];
    snprintf(appPackages, sizeof(appPackages), "%s/app_packages", resourcePath);
    snprintf(app, sizeof(app), "%s/app", resourcePath);
    if (append_sys_path(appPackages) != 0 || append_sys_path(app) != 0) {
        if (PyErr_Occurred()) PyErr_Clear();
        return -6;
    }

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
Set **Objective-C Bridging Header** = `Keraunos/Keraunos-Bridging-Header.h`. If `#import <Python.h>` isn't found, add the framework headers to **Header Search Paths**.

- [ ] **Step 4: Verification gate — build**

```bash
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST"
```
Expected: BUILD SUCCEEDED. Failures are usually `Python.h` not found (Header Search Paths) or a wrong bridging-header path.

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m app/Keraunos/Keraunos/Keraunos-Bridging-Header.h app/Keraunos/Keraunos.xcodeproj
git commit -m "feat(python): add C-API bridge for interpreter init and extract"
```

---

### Task 13: `PythonExtractor` (implements `KeraunosCore.MediaExtracting`)

**Files:**
- Create: `app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`
- Modify: `app/Keraunos/Keraunos/ContentView.swift`

> `PythonExtractor` is an `actor` with a **custom serial executor** (a dedicated `DispatchSerialQueue`), so it runs the blocking Python C calls on its own thread — off both the main actor and the Swift cooperative pool — while actor isolation serializes access to the single interpreter. It conforms to `KeraunosCore.MediaExtracting`. (`DispatchSerialQueue`'s `SerialExecutor` conformance requires iOS 17+/macOS 14+; we target iOS 26.5.)

- [ ] **Step 1: Implement the extractor**

`app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`:
```swift
import Foundation
import KeraunosCore

/// Runs yt-dlp extraction inside the embedded interpreter. A custom serial
/// executor backed by a dedicated DispatchSerialQueue means this actor's work
/// runs on its own thread — NOT the Swift cooperative pool — so the blocking
/// Python C call is safe to make, and actor isolation serializes access to the
/// single (GIL-bound) interpreter and protects `initialized`. Actors are
/// Sendable, so no @unchecked / nonisolated(unsafe) / continuation needed.
actor PythonExtractor: MediaExtracting {
    private let queue = DispatchSerialQueue(label: "io.github.lilikazine.Keraunos.python")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var initialized = false   // ordinary actor-isolated state

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try ensureInitialized()
        guard let cString = keraunos_python_extract(url.absoluteString) else {
            throw KeraunosError.runtime(detail: "null extraction result")
        }
        defer { free(cString) }
        return try ExtractionDecoder.decode(Data(String(cString: cString).utf8))
    }

    private func ensureInitialized() throws {
        guard !initialized else { return }
        guard let resources = Bundle.main.resourceURL else {
            throw KeraunosError.runtime(detail: "no resource bundle")
        }
        // b14: stdlib at <resources>/python (PYTHONHOME), module at <resources>/app,
        // packages at <resources>/app_packages, CA bundle at <resources>/app.
        let caCert = resources.appendingPathComponent("app/cacert.pem")
        let status = keraunos_python_init(resources.path, caCert.path)
        guard status == 0 else { throw KeraunosError.runtime(detail: "python init failed (\(status))") }
        initialized = true
    }
}
```

> Note: the bridge derives `<resources>/python`, `/app`, `/app_packages` from the
> single `resourcePath`. These must match the folder references added in Task 11.

- [ ] **Step 2: Swap the mock for the real extractor** — in `app/Keraunos/Keraunos/ContentView.swift`:

```swift
import SwiftUI
import KeraunosCore

struct ContentView: View {
    var body: some View {
        DownloadScreen(model: DownloadViewModel(
            extractor: PythonExtractor(),
            downloader: Downloader(),
            store: DownloadStore()))
    }
}

#Preview {
    // Preview keeps the mock so the canvas needs no interpreter.
    DownloadScreen(model: DownloadViewModel(
        extractor: MockExtractor(),
        downloader: Downloader(),
        store: DownloadStore()))
}
```

- [ ] **Step 3: Build + run app tests** (still use the mock, must stay green)

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

### Task 14: Manual acceptance against real videos

**Files:** none (manual verification; capture results in a log)

- [ ] **Step 1: Interpreter smoke test** — Run the app. Resolve a small known-good HTTPS `.mp4`; confirm it downloads and appears in the list. Proves interpreter init + SSL (certifi) + urllib end-to-end.

- [ ] **Step 2: Real X progressive video** — Paste a public, non-sensitive X post with video. Expected: resolves, downloads, `.mp4` appears in the list and the Files app.

- [ ] **Step 3: HLS-only / unsupported case** — Paste an HLS-only or unsupported link. Expected: a clear `.needsFfmpeg` / `.unsupported` message, not a crash.

- [ ] **Step 4: Record results** — Create `docs/logs/2026-06-15-01-milestone-1-acceptance.md`: device/sim + iOS version, URLs tried, outcomes, built `.app` size (`du -sh`), any X guest-token flakiness. Commit:

```bash
git add docs/logs/2026-06-15-01-milestone-1-acceptance.md
git commit -m "docs(log): record Milestone 1 acceptance results"
```

- [ ] **Step 5: Milestone 1 done check** — Confirm the spec §7 items:
  1. App builds/launches with embedded Python, SSL verified (Step 1).
  2. Single screen with URL field, Download button, working indicator, file list (Task 8).
  3. Public progressive MP4 (incl. an X post) downloads to Documents, visible in Files (Step 2).
  4. Errors surface clearly, especially `.needsFfmpeg` / `.requiresAuth` (Step 3).
  5. Core tests (`swift test`) + Python dev tests + app tests all green.

---

## Self-Review notes (for the executor)

- **Module split:** `KeraunosCore` (nonisolated default, `public` API) holds `KeraunosError`, `ResolvedMedia`/`ExtractionDecoder`, `MediaExtracting`/`MockExtractor`, `Downloader`/`FileDownloading`, `DownloadStore` — none need isolation annotations. The app target (main-actor default) holds the UI + `PythonExtractor` (an `actor` with a custom serial executor) + Python embedding.
- **Spec coverage:** `PythonRuntime` (Tasks 10–13); `Extractor`/`PythonExtractor` (Tasks 5, 9, 13); `Downloader` (Task 6); `DownloadStore` (Task 7); UI (Task 8); data flow (Tasks 8+13); error mapping incl. `.needsFfmpeg`/`.requiresAuth` (Tasks 3, 9); testing — Core unit via `swift test` (Tasks 3–7), Python dev test against localhost (Task 9), app view-model test (Task 8), manual acceptance (Task 14); Milestone-1 done (Task 14 Step 5). The "extract in Python, download in Swift" split = `PythonExtractor` resolves only + `Downloader` transfers.
- **Verification gates (not placeholders):** exact `python-stdlib` path inside the support package (Task 10 Step 2 → Task 13); the `install_python` run-script and `openssl.xcprivacy` taken verbatim from the release `USAGE.md` (Task 11); yt-dlp's `requested_formats` / "requested format is not available" behavior for X HLS posts (Task 9 maps both to `.needsFfmpeg`; confirm in Task 14 Step 3).
- **Deferred (NOT Milestone 1):** ffmpeg/HLS merge, Share Sheet, format picker, queue/history, audio-only, cookies/auth.
```
