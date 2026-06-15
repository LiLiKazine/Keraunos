# Keraunos Milestone 2 — Native DASH Merge Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve a URL to either a progressive file or a separate video+audio (DASH) pair; download both tracks (sending yt-dlp's per-format HTTP headers) and mux them natively into one playable MP4 — no ffmpeg.

**Architecture:** Evolve `ResolvedMedia` into a typed `.progressive`/`.adaptive` model over a `MediaTrack` value type. A `MediaAssembler` in `KeraunosCore` orchestrates download(s) + merge, depending only on the `FileDownloading` and `MediaMerging` protocols (so an ffmpeg backend is a later drop-in). Muxing is `AVFoundation` passthrough (`AVMutableComposition` + `AVAssetExportSession`). The app's view model calls the assembler; `keraunos_extract.py` emits a richer JSON contract with per-format headers and codecs.

**Tech Stack:** Swift 6 language mode, SwiftUI, Swift Testing, `AVFoundation`, the existing `KeraunosCore` SwiftPM package, embedded CPython 3.13 + yt-dlp (from Milestone 1).

**Design source of truth:** `docs/superpowers/specs/2026-06-15-keraunos-dash-merge-design.md`.

---

## Conventions (read once)

- **Repo root:** `/Users/leo/Developer/Keraunos`. Run all commands from there.
- **App project / scheme:** `app/Keraunos/Keraunos.xcodeproj`, scheme `Keraunos`.
- **Core package:** `app/KeraunosCore`.
- **Core test command** (fast — macOS, no simulator):
  ```bash
  swift test --package-path app/KeraunosCore
  ```
  Single suite: `swift test --package-path app/KeraunosCore --filter MediaAssemblerTests`.
- **App test command** (define `DEST` once; iPhone 17 Pro Max launches reliably here):
  ```bash
  DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
  xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests
  ```
  If unavailable, pick one from `xcrun simctl list devices available | grep iPhone`.
- **Python dev tests:**
  ```bash
  cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
  ```
- **Build sequencing note:** Tasks 1–6 change `KeraunosCore` and are each verified with `swift test`. Reshaping `ResolvedMedia` (Task 2) intentionally breaks the **app target** (it references the old `ResolvedMedia`); the app target is not rebuilt until Task 8. This is expected — do **not** try to build the app between Tasks 2 and 8; verify Core tasks with `swift test` only.
- **Isolation rule (unchanged from M1):** `KeraunosCore` is `nonisolated`-default. A `nonisolated async` method inherits the caller's isolation, so `MediaAssembler.assemble`, `Downloader.download`, and `AVFoundationMerger.merge` run on the (main-actor) view model's executor; their `await`s suspend rather than block, and `AVAssetExportSession` does its heavy work on its own threads. No GCD, no extra actors needed for this milestone.
- **Commits:** use the `structured-commit` skill. The `git commit` lines below give the summary; let the skill expand the body. End messages with the `Co-Authored-By` trailer.
- **TDD:** every code task is test-first. Run the test, see it fail, implement, see it pass, commit.

---

## File Structure

```
app/KeraunosCore/Sources/KeraunosCore/
  KeraunosError.swift          # Task 1 (add .mergeFailed)
  MediaTrack.swift             # Task 2 (NEW — MediaTrack value type)
  ResolvedMedia.swift          # Task 2 (rewritten — enum Kind + decoder)
  MediaExtracting.swift        # Task 2 (MockExtractor updated to new model)
  Downloader.swift             # Task 2 (signature → MediaTrack); Task 3 (send headers)
  MediaMerging.swift           # Task 4 (NEW — protocol + MockMerger)
  AVFoundationMerger.swift     # Task 5 (NEW — native passthrough mux)
  MediaAssembler.swift         # Task 6 (NEW — orchestrator)
  DownloadStore.swift          # unchanged

app/KeraunosCore/Tests/KeraunosCoreTests/
  KeraunosErrorTests.swift     # Task 1 (extend)
  ExtractionDecodingTests.swift# Task 2 (rewritten)
  StubURLProtocol.swift        # Task 3 (record request headers)
  DownloaderTests.swift        # Task 2 (new signature) + Task 3 (header assert)
  AVFoundationMergerTests.swift# Task 5 (NEW)
  MediaAssemblerTests.swift    # Task 6 (NEW)
  DownloadStoreTests.swift     # unchanged

app/Keraunos/PythonResources/app/
  keraunos_extract.py          # Task 7 (new selector + JSON contract)
app/Keraunos/python-dev/
  test_extract.py              # Task 7 (extend)

app/Keraunos/Keraunos/
  UI/DownloadViewModel.swift   # Task 8 (use MediaAssembler + phase)
  UI/DownloadScreen.swift      # Task 8 (phase label)
  ContentView.swift            # Task 8 (wire assembler + merger)
app/Keraunos/KeraunosTests/
  DownloadViewModelTests.swift # Task 8 (rewritten for new model + assembler)
```

---

## Task 1: Add `KeraunosError.mergeFailed`

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/KeraunosError.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/KeraunosErrorTests.swift`

- [ ] **Step 1: Extend the failing test** — add to `KeraunosErrorTests` (the `everyCaseHasAUserMessage` array and a new assertion):

```swift
    @Test func mergeFailedHasAMessage() {
        #expect(KeraunosError.mergeFailed.errorDescription?.isEmpty == false)
        #expect(KeraunosError.mergeFailed.errorDescription == "Couldn't combine the video and audio tracks.")
    }
```

- [ ] **Step 2: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter KeraunosErrorTests
```
Expected: FAIL — `type 'KeraunosError' has no member 'mergeFailed'`.

- [ ] **Step 3: Implement** — in `KeraunosError.swift`, add the case to the enum (after `.cancelled`):

```swift
    case mergeFailed
```
and add to the `errorDescription` switch (before the closing brace of the switch):

```swift
        case .mergeFailed:        return "Couldn't combine the video and audio tracks."
```

- [ ] **Step 4: Run it, expect pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git commit -m "feat(core): add KeraunosError.mergeFailed"
```

---

## Task 2: `MediaTrack` + typed `ResolvedMedia` + decoder (and migrate consumers)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/MediaTrack.swift`
- Rewrite: `app/KeraunosCore/Sources/KeraunosCore/ResolvedMedia.swift`
- Modify: `app/KeraunosCore/Sources/KeraunosCore/MediaExtracting.swift` (MockExtractor)
- Modify: `app/KeraunosCore/Sources/KeraunosCore/Downloader.swift` (signature → `MediaTrack`, full destination URL)
- Rewrite: `app/KeraunosCore/Tests/KeraunosCoreTests/ExtractionDecodingTests.swift`
- Modify: `app/KeraunosCore/Tests/KeraunosCoreTests/DownloaderTests.swift` (new signature)

> This is the model migration. `ResolvedMedia` changes shape, which forces `ExtractionDecoder`, `MockExtractor`, `Downloader`, and two test files to change together so the package keeps compiling. Header-sending is added in Task 3; here `Downloader` just adopts the new `MediaTrack` signature.

- [ ] **Step 1: Write the new decoder tests** — replace the entire contents of `ExtractionDecodingTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct ExtractionDecodingTests {
    @Test func decodesProgressive() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"My Clip","filename":"clip.mp4",
         "media":{"url":"https://x.test/v.mp4","headers":{"User-Agent":"yt"},"vcodec":"avc1","acodec":"mp4a","ext":"mp4"}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        #expect(media.title == "My Clip")
        #expect(media.suggestedFilename == "clip.mp4")
        guard case let .progressive(track) = media.kind else { Issue.record("expected progressive"); return }
        #expect(track.url == URL(string: "https://x.test/v.mp4"))
        #expect(track.httpHeaders["User-Agent"] == "yt")
        #expect(track.fileExtension == "mp4")
    }

    @Test func decodesAdaptive() throws {
        let json = #"""
        {"ok":true,"kind":"adaptive","title":"T","filename":"clip.mp4",
         "video":{"url":"https://x.test/v.m4v","headers":{"User-Agent":"yt"},"vcodec":"hvc1","ext":"mp4"},
         "audio":{"url":"https://x.test/a.m4a","headers":{"Referer":"r"},"acodec":"mp4a","ext":"m4a"}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        guard case let .adaptive(video, audio) = media.kind else { Issue.record("expected adaptive"); return }
        #expect(video.url == URL(string: "https://x.test/v.m4v"))
        #expect(video.codec == "hvc1")
        #expect(audio.url == URL(string: "https://x.test/a.m4a"))
        #expect(audio.httpHeaders["Referer"] == "r")
        #expect(audio.fileExtension == "m4a")
    }

    @Test func mapsErrorPayloadToKeraunosError() {
        let json = #"{"ok":false,"error_kind":"needs_ffmpeg","detail":"hls only"}"#
        #expect(throws: KeraunosError.needsFfmpeg) {
            try ExtractionDecoder.decode(Data(json.utf8))
        }
    }

    @Test func fallsBackToURLLastComponentWhenFilenameMissing() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"",
         "media":{"url":"https://x.test/abc/video.mp4","headers":{},"vcodec":"avc1","acodec":"mp4a","ext":"mp4"}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        #expect(media.suggestedFilename == "video.mp4")
    }

    @Test func throwsRuntimeOnMalformed() {
        #expect(throws: KeraunosError.self) {
            try ExtractionDecoder.decode(Data("not json".utf8))
        }
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter ExtractionDecodingTests
```
Expected: FAIL — `value of type 'ResolvedMedia' has no member 'kind'` / `cannot find 'MediaTrack'`.

- [ ] **Step 3: Create `MediaTrack.swift`**

```swift
import Foundation

/// One directly-downloadable media stream (progressive file, or a video-only /
/// audio-only track of an adaptive source). `httpHeaders` are yt-dlp's per-format
/// request headers, replayed by the downloader so CDNs accept the request.
public struct MediaTrack: Equatable, Sendable {
    public let url: URL
    public let httpHeaders: [String: String]
    public let codec: String
    public let fileExtension: String

    public init(url: URL, httpHeaders: [String: String], codec: String, fileExtension: String) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.codec = codec
        self.fileExtension = fileExtension
    }
}
```

- [ ] **Step 4: Rewrite `ResolvedMedia.swift`** (model + wire types + decoder):

```swift
import Foundation

/// A resolved download: either one already-muxed file, or a video+audio pair to mux.
public struct ResolvedMedia: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case progressive(MediaTrack)
        case adaptive(video: MediaTrack, audio: MediaTrack)
    }
    public let kind: Kind
    public let title: String
    public let suggestedFilename: String

    public init(kind: Kind, title: String, suggestedFilename: String) {
        self.kind = kind
        self.title = title
        self.suggestedFilename = suggestedFilename
    }
}

/// Wire format emitted by keraunos_extract.py.
private struct TrackPayload: Decodable {
    let url: String
    let headers: [String: String]?
    let vcodec: String?
    let acodec: String?
    let ext: String?
}

private struct ExtractionResult: Decodable {
    let ok: Bool
    let kind: String?
    let title: String?
    let filename: String?
    let media: TrackPayload?
    let video: TrackPayload?
    let audio: TrackPayload?
    let errorKind: String?
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case ok, kind, title, filename, media, video, audio, detail
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
        guard result.ok else {
            throw KeraunosError(errorKind: result.errorKind ?? "runtime", detail: result.detail ?? "")
        }
        let title = result.title ?? ""
        switch result.kind {
        case "progressive":
            guard let track = Self.track(result.media) else {
                throw KeraunosError.runtime(detail: "missing progressive media")
            }
            return ResolvedMedia(kind: .progressive(track),
                                 title: title,
                                 suggestedFilename: Self.filename(result.filename, fallbackURL: track.url))
        case "adaptive":
            guard let video = Self.track(result.video), let audio = Self.track(result.audio) else {
                throw KeraunosError.runtime(detail: "missing adaptive tracks")
            }
            return ResolvedMedia(kind: .adaptive(video: video, audio: audio),
                                 title: title,
                                 suggestedFilename: Self.filename(result.filename, fallbackURL: video.url))
        default:
            throw KeraunosError.runtime(detail: "unknown extraction kind")
        }
    }

    private static func track(_ payload: TrackPayload?) -> MediaTrack? {
        guard let payload, let url = URL(string: payload.url) else { return nil }
        return MediaTrack(url: url,
                          httpHeaders: payload.headers ?? [:],
                          codec: payload.vcodec ?? payload.acodec ?? "",
                          fileExtension: payload.ext ?? url.pathExtension)
    }

    private static func filename(_ name: String?, fallbackURL: URL) -> String {
        if let name, !name.isEmpty { return name }
        return fallbackURL.lastPathComponent
    }
}
```

- [ ] **Step 5: Update `MockExtractor`** in `MediaExtracting.swift` — replace its `init` default and body so it builds a progressive `ResolvedMedia`:

```swift
    public init(result: Result<ResolvedMedia, KeraunosError> = .success(
        ResolvedMedia(
            kind: .progressive(MediaTrack(url: URL(string: "https://example.com/sample.mp4")!,
                                          httpHeaders: [:], codec: "avc1", fileExtension: "mp4")),
            title: "Sample",
            suggestedFilename: "sample.mp4"))) {
        self.result = result
    }
```
(Leave the `result` property and `resolve(_:)` method unchanged.)

- [ ] **Step 6: Update `Downloader.swift`** — change `FileDownloading` and `Downloader` to take a `MediaTrack` and a full destination file URL (no header logic yet):

```swift
import Foundation

public protocol FileDownloading: Sendable {
    /// Downloads one track to `destination` (a full file URL), replacing any existing file.
    func download(_ track: MediaTrack, to destination: URL) async throws
}

/// Downloads a single track with URLSession and moves it into place.
public struct Downloader: FileDownloading {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func download(_ track: MediaTrack, to destination: URL) async throws {
        do {
            let (tempURL, response) = try await session.download(from: track.url)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw KeraunosError.network
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
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

- [ ] **Step 7: Update `DownloaderTests.swift`** to the new signature — replace its three test bodies' media/calls:

```swift
import Testing
import Foundation
import KeraunosCore

@Suite(.serialized)
struct DownloaderTests {
    private func tempFile(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    private func track(_ s: String = "https://x.test/v.mp4") -> MediaTrack {
        MediaTrack(url: URL(string: s)!, httpHeaders: [:], codec: "avc1", fileExtension: "mp4")
    }

    @Test func savesFileToDestination() async throws {
        let payload = Data("fake mp4 bytes".utf8)
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let dest = tempFile("clip.mp4")
        try await Downloader(session: StubURLProtocol.session()).download(track(), to: dest)
        #expect(try Data(contentsOf: dest) == payload)
    }

    @Test func mapsHTTPErrorToNetwork() async throws {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await #expect(throws: KeraunosError.network) {
            try await Downloader(session: StubURLProtocol.session()).download(track(), to: tempFile("clip.mp4"))
        }
    }

    @Test func mapsCancellationToCancelled() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await #expect(throws: KeraunosError.cancelled) {
            try await Downloader(session: StubURLProtocol.session()).download(track(), to: tempFile("clip.mp4"))
        }
    }
}
```

- [ ] **Step 8: Run the whole Core suite, expect pass**

```bash
swift test --package-path app/KeraunosCore
```
Expected: all suites pass (decoder, downloader, error, store).

- [ ] **Step 9: Commit**

```bash
git add app/KeraunosCore
git commit -m "feat(core): typed ResolvedMedia (.progressive/.adaptive) over MediaTrack"
```

---

## Task 3: `Downloader` sends per-track HTTP headers

**Files:**
- Modify: `app/KeraunosCore/Tests/KeraunosCoreTests/StubURLProtocol.swift` (record request)
- Modify: `app/KeraunosCore/Sources/KeraunosCore/Downloader.swift`
- Modify: `app/KeraunosCore/Tests/KeraunosCoreTests/DownloaderTests.swift`

- [ ] **Step 1: Record the request in `StubURLProtocol`** — add a recorded-request store. Replace the `handler` static and `startLoading()` header capture by adding this property and one line:

Add property (next to `handler`):
```swift
    nonisolated(unsafe) static var lastRequest: URLRequest?
```
At the top of `startLoading()` (first line of the method body):
```swift
        StubURLProtocol.lastRequest = request
```

- [ ] **Step 2: Write the failing header test** — add to `DownloaderTests`:

```swift
    @Test func sendsTrackHTTPHeaders() async throws {
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("x".utf8))
        }
        let t = MediaTrack(url: URL(string: "https://x.test/v.mp4")!,
                           httpHeaders: ["X-Keraunos-Test": "yes", "Referer": "https://x.test/"],
                           codec: "avc1", fileExtension: "mp4")
        try await Downloader(session: StubURLProtocol.session()).download(t, to: tempFile("clip.mp4"))
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Keraunos-Test") == "yes")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer") == "https://x.test/")
    }
```

- [ ] **Step 3: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter DownloaderTests
```
Expected: FAIL — header is `nil` (Downloader doesn't set headers yet).

- [ ] **Step 4: Implement** — in `Downloader.download`, build a request with the headers instead of downloading from the bare URL. Replace the first line of the `do` block:

```swift
            var request = URLRequest(url: track.url)
            for (field, value) in track.httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
            let (tempURL, response) = try await session.download(for: request)
```

- [ ] **Step 5: Run it, expect pass** — same command as Step 3. Expected: PASS (and the other Downloader tests still pass).

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore
git commit -m "feat(core): Downloader replays per-track HTTP headers"
```

---

## Task 4: `MediaMerging` protocol + `MockMerger`

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/MediaMerging.swift`

No dedicated test (a protocol + a test double); exercised by Task 6.

- [ ] **Step 1: Implement**

```swift
import Foundation

/// Muxes a video-only and an audio-only file into one container at `output`.
/// The native implementation (AVFoundationMerger) ships now; an ffmpeg-backed
/// implementation can replace it later with no change to callers.
public protocol MediaMerging: Sendable {
    func merge(video videoURL: URL, audio audioURL: URL, into output: URL) async throws
}

/// Deterministic test double: records its inputs and writes a marker file, or
/// fails on demand.
public final class MockMerger: MediaMerging, @unchecked Sendable {
    public private(set) var received: (video: URL, audio: URL, output: URL)?
    public var shouldFail = false
    public init() {}

    public func merge(video videoURL: URL, audio audioURL: URL, into output: URL) async throws {
        received = (videoURL, audioURL, output)
        if shouldFail { throw KeraunosError.mergeFailed }
        try Data("merged".utf8).write(to: output)
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
git add app/KeraunosCore
git commit -m "feat(core): add MediaMerging protocol and MockMerger"
```

---

## Task 5: `AVFoundationMerger` (native passthrough mux)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/AVFoundationMerger.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/AVFoundationMergerTests.swift`

> Automated coverage is the **error path** (non-media inputs → `.mergeFailed`), which needs no media fixtures. The happy-path mux is verified in Task 9 manual acceptance with a real DASH download (per the design's fixture-flakiness note).

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import KeraunosCore

struct AVFoundationMergerTests {
    private func tempFile(_ name: String, bytes: Data) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? bytes.write(to: url)
        return url
    }

    @Test func throwsMergeFailedOnNonMediaInputs() async {
        let video = tempFile("v.mp4", bytes: Data("not a video".utf8))
        let audio = tempFile("a.m4a", bytes: Data("not audio".utf8))
        let out = tempFile("out.mp4", bytes: Data()).deletingLastPathComponent().appendingPathComponent("out.mp4")
        await #expect(throws: KeraunosError.mergeFailed) {
            try await AVFoundationMerger().merge(video: video, audio: audio, into: out)
        }
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter AVFoundationMergerTests
```
Expected: FAIL — `cannot find 'AVFoundationMerger' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation
import AVFoundation

/// Muxes a video-only and an audio-only file into one MP4 using AVFoundation
/// passthrough (container remux, no transcoding). Fails cleanly with
/// `.mergeFailed` when a track is missing or the codec can't be carried.
public struct AVFoundationMerger: MediaMerging {
    public init() {}

    public func merge(video videoURL: URL, audio audioURL: URL, into output: URL) async throws {
        let composition = AVMutableComposition()
        do {
            let videoAsset = AVURLAsset(url: videoURL)
            let audioAsset = AVURLAsset(url: audioURL)
            guard let srcVideo = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let srcAudio = try await audioAsset.loadTracks(withMediaType: .audio).first,
                  let dstVideo = composition.addMutableTrack(withMediaType: .video,
                        preferredTrackID: kCMPersistentTrackID_Invalid),
                  let dstAudio = composition.addMutableTrack(withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw KeraunosError.mergeFailed
            }
            let videoDuration = try await videoAsset.load(.duration)
            let audioDuration = try await audioAsset.load(.duration)
            try dstVideo.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: srcVideo, at: .zero)
            try dstAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: srcAudio, at: .zero)
            dstVideo.preferredTransform = try await srcVideo.load(.preferredTransform)
        } catch let error as KeraunosError {
            throw error
        } catch {
            throw KeraunosError.mergeFailed
        }

        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw KeraunosError.mergeFailed
        }
        try? FileManager.default.removeItem(at: output)
        do {
            try await export.export(to: output, as: .mp4)
        } catch {
            throw KeraunosError.mergeFailed
        }
    }
}
```

- [ ] **Step 4: Run it, expect pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore
git commit -m "feat(core): add AVFoundationMerger (native passthrough mux)"
```

---

## Task 6: `MediaAssembler` (orchestrator)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/MediaAssembler.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/MediaAssemblerTests.swift`

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import KeraunosCore

@Suite(.serialized)
struct MediaAssemblerTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func track(_ s: String, _ ext: String) -> MediaTrack {
        MediaTrack(url: URL(string: s)!, httpHeaders: [:], codec: "c", fileExtension: ext)
    }
    private func bytesHandler() {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
             Data(req.url!.lastPathComponent.utf8))
        }
    }

    @Test func progressiveDownloadsOneFileAndSkipsMerge() async throws {
        bytesHandler()
        let store = DownloadStore(directory: tempDir())
        let merger = MockMerger()
        let media = ResolvedMedia(kind: .progressive(track("https://x.test/v.mp4", "mp4")),
                                  title: "t", suggestedFilename: "clip.mp4")
        let saved = try await MediaAssembler(downloader: Downloader(session: StubURLProtocol.session()),
                                             merger: merger).assemble(media, into: store)
        #expect(saved.lastPathComponent == "clip.mp4")
        #expect(FileManager.default.fileExists(atPath: saved.path))
        #expect(merger.received == nil)               // progressive never merges
    }

    @Test func adaptiveDownloadsBothThenMerges() async throws {
        bytesHandler()
        let store = DownloadStore(directory: tempDir())
        let merger = MockMerger()
        let media = ResolvedMedia(kind: .adaptive(video: track("https://x.test/v.m4v", "mp4"),
                                                  audio: track("https://x.test/a.m4a", "m4a")),
                                  title: "t", suggestedFilename: "clip.webm")
        let saved = try await MediaAssembler(downloader: Downloader(session: StubURLProtocol.session()),
                                             merger: merger).assemble(media, into: store)
        #expect(saved.lastPathComponent == "clip.mp4")          // forced to .mp4
        #expect(merger.received?.output == saved)
        #expect(FileManager.default.fileExists(atPath: saved.path))
        // temp video/audio inputs were cleaned up
        #expect(!FileManager.default.fileExists(atPath: merger.received!.video.path))
        #expect(!FileManager.default.fileExists(atPath: merger.received!.audio.path))
    }

    @Test func cleansUpTempWhenMergeFails() async throws {
        bytesHandler()
        let store = DownloadStore(directory: tempDir())
        let merger = MockMerger(); merger.shouldFail = true
        let media = ResolvedMedia(kind: .adaptive(video: track("https://x.test/v.m4v", "mp4"),
                                                  audio: track("https://x.test/a.m4a", "m4a")),
                                  title: "t", suggestedFilename: "clip.mp4")
        await #expect(throws: KeraunosError.mergeFailed) {
            try await MediaAssembler(downloader: Downloader(session: StubURLProtocol.session()),
                                     merger: merger).assemble(media, into: store)
        }
        #expect(!FileManager.default.fileExists(atPath: merger.received!.video.path))
        #expect(!FileManager.default.fileExists(atPath: merger.received!.audio.path))
        #expect(store.savedFiles().isEmpty)             // no half-file in Documents
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter MediaAssemblerTests
```
Expected: FAIL — `cannot find 'MediaAssembler' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

/// Turns a `ResolvedMedia` into a finished file in the store's directory:
/// progressive = download one file; adaptive = download both tracks to a temp
/// dir, mux into one MP4, and clean up the temp inputs.
public struct MediaAssembler {
    public enum Phase: Sendable { case downloading, downloadingVideo, downloadingAudio, merging }

    private let downloader: any FileDownloading
    private let merger: any MediaMerging

    public init(downloader: any FileDownloading, merger: any MediaMerging) {
        self.downloader = downloader
        self.merger = merger
    }

    public func assemble(_ media: ResolvedMedia,
                         into store: DownloadStore,
                         onPhase: (Phase) -> Void = { _ in }) async throws -> URL {
        switch media.kind {
        case .progressive(let track):
            onPhase(.downloading)
            let destination = store.directory.appendingPathComponent(media.suggestedFilename)
            try await downloader.download(track, to: destination)
            return destination

        case .adaptive(let video, let audio):
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            let videoURL = scratch.appendingPathComponent("video.\(video.fileExtension)")
            let audioURL = scratch.appendingPathComponent("audio.\(audio.fileExtension)")
            onPhase(.downloadingVideo)
            try await downloader.download(video, to: videoURL)
            onPhase(.downloadingAudio)
            try await downloader.download(audio, to: audioURL)

            onPhase(.merging)
            let base = (media.suggestedFilename as NSString).deletingPathExtension
            let destination = store.directory.appendingPathComponent("\(base).mp4")
            try? FileManager.default.removeItem(at: destination)
            try await merger.merge(video: videoURL, audio: audioURL, into: destination)
            return destination
        }
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
git add app/KeraunosCore
git commit -m "feat(core): add MediaAssembler orchestrating download + merge"
```

---

## Task 7: `keraunos_extract.py` — new contract + DASH selection

**Files:**
- Modify: `app/Keraunos/PythonResources/app/keraunos_extract.py`
- Modify: `app/Keraunos/python-dev/test_extract.py`

The module must emit the Task-2 contract: `progressive` (one `media` track) or `adaptive` (`video`+`audio` tracks), each with `headers`, codecs, `ext`. Selection prefers a progressive muxed file; else best HEVC-then-H.264 video + AAC audio; else `needs_ffmpeg`.

- [ ] **Step 1: Write failing tests** — replace the contents of `app/Keraunos/python-dev/test_extract.py`:

```python
import json
import sys
import threading
import http.server
import functools
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "PythonResources" / "app"
sys.path.insert(0, str(APP))
import keraunos_extract  # noqa: E402


def _serve(directory, ready):
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(directory))
    httpd = http.server.HTTPServer(("127.0.0.1", 0), handler)
    ready.append(httpd)
    httpd.serve_forever()


def test_progressive_payload_shape():
    info = {
        "title": "Clip", "ext": "mp4", "url": "https://x.test/v.mp4",
        "vcodec": "avc1.4d401e", "acodec": "mp4a.40.2",
        "http_headers": {"User-Agent": "yt"},
    }
    out = json.loads(keraunos_extract._payload_for_info(info, lambda i: "Clip.mp4"))
    assert out["ok"] is True
    assert out["kind"] == "progressive"
    assert out["media"]["url"] == "https://x.test/v.mp4"
    assert out["media"]["headers"]["User-Agent"] == "yt"
    assert out["media"]["ext"] == "mp4"


def test_adaptive_payload_shape():
    info = {
        "title": "Clip", "ext": "mp4",
        "requested_formats": [
            {"url": "https://x.test/v.m4v", "vcodec": "hvc1", "acodec": "none",
             "ext": "mp4", "http_headers": {"User-Agent": "yt"}},
            {"url": "https://x.test/a.m4a", "vcodec": "none", "acodec": "mp4a.40.2",
             "ext": "m4a", "http_headers": {"Referer": "r"}},
        ],
    }
    out = json.loads(keraunos_extract._payload_for_info(info, lambda i: "Clip.mp4"))
    assert out["kind"] == "adaptive"
    assert out["video"]["url"] == "https://x.test/v.m4v"
    assert out["video"]["vcodec"] == "hvc1"
    assert out["audio"]["url"] == "https://x.test/a.m4a"
    assert out["audio"]["headers"]["Referer"] == "r"


def test_resolves_local_progressive_file(tmp_path):
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True).start()
    while not ready:
        pass
    port = ready[0].server_address[1]
    out = json.loads(keraunos_extract.extract(f"http://127.0.0.1:{port}/sample.mp4"))
    ready[0].shutdown()
    assert out["ok"] is True
    assert out["kind"] == "progressive"
    assert out["media"]["url"].endswith("/sample.mp4")
```

- [ ] **Step 2: Run it, expect failure**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: FAIL — `module 'keraunos_extract' has no attribute '_payload_for_info'` / wrong shape.

- [ ] **Step 3: Implement** — replace the contents of `app/Keraunos/PythonResources/app/keraunos_extract.py`:

```python
"""Keraunos extraction bridge.

Resolves a page URL to either a single progressive (already-muxed) file or a
separate video+audio pair for native merging, using yt-dlp WITHOUT downloading
and WITHOUT ffmpeg. Restricts adaptive selection to AVFoundation-muxable codecs
(HEVC/H.264 video + AAC audio). Always returns a JSON string; never raises.
"""
import json

import yt_dlp
from yt_dlp.utils import DownloadError, ExtractorError, UnsupportedError

# Prefer a progressive muxed http file; else best HEVC then H.264 video-only +
# best AAC audio-only. All branches are AVFoundation-muxable (no VP9/AV1/Opus).
_FORMAT = (
    "best[protocol^=http][vcodec~='^(avc1|hvc1|hev1)'][acodec^=mp4a]/"
    "bestvideo[protocol^=http][vcodec~='^(hvc1|hev1)']+bestaudio[acodec^=mp4a]/"
    "bestvideo[protocol^=http][vcodec^=avc1]+bestaudio[acodec^=mp4a]"
)

_AUTH_HINTS = ("log in", "sign in", "logged in", "cookies", "nsfw",
               "age-restricted", "age restricted", "confirm your age", "sensitive")


def _err(kind, detail=""):
    return json.dumps({"ok": False, "error_kind": kind, "detail": detail})


def _track(fmt):
    return {
        "url": fmt.get("url"),
        "headers": fmt.get("http_headers") or {},
        "vcodec": fmt.get("vcodec"),
        "acodec": fmt.get("acodec"),
        "ext": fmt.get("ext"),
    }


def _payload_for_info(info, prepare_filename):
    """Builds the success JSON for a resolved info dict. Pure (no network)."""
    filename = prepare_filename(info)
    title = info.get("title") or ""
    requested = info.get("requested_formats")
    if requested and len(requested) == 2:
        video = next((f for f in requested if (f.get("vcodec") or "none") != "none"), None)
        audio = next((f for f in requested if (f.get("acodec") or "none") != "none"), None)
        if video and audio:
            return json.dumps({
                "ok": True, "kind": "adaptive", "title": title, "filename": filename,
                "video": _track(video), "audio": _track(audio),
            })
    if info.get("url"):
        return json.dumps({
            "ok": True, "kind": "progressive", "title": title, "filename": filename,
            "media": _track(info),
        })
    return _err("needs_ffmpeg", "no AVFoundation-muxable formats available")


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
            return _payload_for_info(info, ydl.prepare_filename)
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

- [ ] **Step 4: Run it, expect pass**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: 3 passed. (If offline, the localhost test still passes — it serves locally.)

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/PythonResources/app/keraunos_extract.py app/Keraunos/python-dev/test_extract.py
git commit -m "feat(python): emit progressive/adaptive contract with headers + codecs"
```

---

## Task 8: App — view model + screen wired to `MediaAssembler`

**Files:**
- Rewrite: `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`
- Modify: `app/Keraunos/Keraunos/UI/DownloadScreen.swift`
- Modify: `app/Keraunos/Keraunos/ContentView.swift`
- Rewrite: `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`

> `PythonExtractor` needs no change — it already decodes via `ExtractionDecoder`, which now returns the new model. The view model switches from calling `Downloader` directly to calling `MediaAssembler`, and exposes a `statusText` phase label.

- [ ] **Step 1: Write the failing tests** — replace the contents of `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`:

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
    private func progressive(_ name: String) -> ResolvedMedia {
        ResolvedMedia(kind: .progressive(MediaTrack(url: URL(string: "https://x.test/v.mp4")!,
                      httpHeaders: [:], codec: "avc1", fileExtension: "mp4")),
                      title: "t", suggestedFilename: name)
    }
    private func vm(extractor: any MediaExtracting, merger: MediaMerging, dir: URL) -> DownloadViewModel {
        DownloadViewModel(extractor: extractor,
                          assembler: MediaAssembler(downloader: SpyDownloader(), merger: merger),
                          store: DownloadStore(directory: dir))
    }

    @Test func successfulProgressiveDownloadAddsFile() async {
        let dir = tempDir()
        let model = vm(extractor: MockExtractor(result: .success(progressive("clip.mp4"))),
                       merger: MockMerger(), dir: dir)
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == nil)
        #expect(model.lastSavedName == "clip.mp4")
        #expect(model.isWorking == false)
    }

    @Test func mergeFailureShowsMessage() async {
        let merger = MockMerger(); merger.shouldFail = true
        let media = ResolvedMedia(kind: .adaptive(
            video: MediaTrack(url: URL(string: "https://x.test/v.m4v")!, httpHeaders: [:], codec: "hvc1", fileExtension: "mp4"),
            audio: MediaTrack(url: URL(string: "https://x.test/a.m4a")!, httpHeaders: [:], codec: "mp4a", fileExtension: "m4a")),
            title: "t", suggestedFilename: "clip.mp4")
        let model = vm(extractor: MockExtractor(result: .success(media)), merger: merger, dir: tempDir())
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == KeraunosError.mergeFailed.errorDescription)
        #expect(model.isWorking == false)
    }

    @Test func extractionErrorShowsMessage() async {
        let model = vm(extractor: MockExtractor(result: .failure(.needsFfmpeg)), merger: MockMerger(), dir: tempDir())
        model.urlText = "https://x.test/post/1"
        await model.startDownload()
        #expect(model.errorMessage == KeraunosError.needsFfmpeg.errorDescription)
    }

    @Test func rejectsInvalidURL() async {
        let model = vm(extractor: MockExtractor(), merger: MockMerger(), dir: tempDir())
        model.urlText = "not a url"
        await model.startDownload()
        #expect(model.errorMessage != nil)
    }
}

/// Writes a marker to the destination so progressive assembly produces a file.
struct SpyDownloader: FileDownloading {
    func download(_ track: MediaTrack, to destination: URL) async throws {
        try Data("x".utf8).write(to: destination)
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/DownloadViewModelTests 2>&1 | grep -iE "cannot find|error:|\*\* TEST"
```
Expected: FAIL — `DownloadViewModel` initializer no longer matches (`assembler:` arg).

- [ ] **Step 3: Rewrite the view model** — replace the contents of `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`:

```swift
import Foundation
import Observation
import KeraunosCore

@Observable
final class DownloadViewModel {   // main-actor by default (app target)
    var urlText: String = ""
    private(set) var isWorking = false
    private(set) var statusText: String?
    private(set) var errorMessage: String?
    private(set) var lastSavedName: String?
    private(set) var savedFiles: [URL] = []

    private let extractor: any MediaExtracting
    private let assembler: MediaAssembler
    private let store: DownloadStore

    init(extractor: any MediaExtracting, assembler: MediaAssembler, store: DownloadStore) {
        self.extractor = extractor
        self.assembler = assembler
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
        statusText = "Resolving…"
        defer { isWorking = false; statusText = nil }
        do {
            let media = try await extractor.resolve(url)
            let saved = try await assembler.assemble(media, into: store) { phase in
                self.statusText = Self.label(for: phase)
            }
            lastSavedName = saved.lastPathComponent
            savedFiles = store.savedFiles()
        } catch let error as KeraunosError {
            errorMessage = error.errorDescription
        } catch {
            errorMessage = KeraunosError.runtime(detail: error.localizedDescription).errorDescription
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
```

- [ ] **Step 4: Run it, expect pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 5: Show the phase label in the screen** — in `app/Keraunos/Keraunos/UI/DownloadScreen.swift`, replace the Button's label block so a working state shows the status text:

```swift
                    Button {
                        Task { await model.startDownload() }
                    } label: {
                        if model.isWorking {
                            HStack { ProgressView(); Text(model.statusText ?? "Working…") }
                        } else {
                            Text("Download")
                        }
                    }
                    .disabled(model.isWorking || model.urlText.isEmpty)
```

- [ ] **Step 6: Wire the assembler in `ContentView.swift`** — replace the contents:

```swift
import SwiftUI
import KeraunosCore

struct ContentView: View {
    var body: some View {
        DownloadScreen(model: DownloadViewModel(
            extractor: PythonExtractor(),
            assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
            store: DownloadStore()))
    }
}

#Preview {
    // Preview keeps the mock so the canvas needs no interpreter.
    DownloadScreen(model: DownloadViewModel(
        extractor: MockExtractor(),
        assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
        store: DownloadStore()))
}
```

- [ ] **Step 7: Build + run the whole app suite**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests 2>&1 | grep -iE "error:|\*\* TEST"
```
Expected: TEST SUCCEEDED.

- [ ] **Step 8: Commit**

```bash
git add app/Keraunos/Keraunos app/Keraunos/KeraunosTests
git commit -m "feat(ui): drive downloads through MediaAssembler with phase labels"
```

---

## Task 9: Manual acceptance

**Files:** none (manual; capture results in a log)

- [ ] **Step 1: Progressive still works** — run the app (Xcode ▶, iPhone 17 Pro Max). Paste a public X video post; confirm it downloads and the `.mp4` appears in the list (Milestone 1 behavior preserved).

- [ ] **Step 2: DASH merge** — paste a URL whose best muxable result is separate video+audio (e.g. a YouTube video that yt-dlp resolves to itag 137+140, or another DASH source). Expected: status cycles "Downloading video… → Downloading audio… → Combining…", then one `.mp4` appears. Open it in the Files app (On My iPhone → Keraunos) and confirm **it plays with both video and audio**.

- [ ] **Step 3: Verify the merged file on disk** — confirm it's a real combined asset:

```bash
APP=$(ls -d ~/Library/Developer/CoreSimulator/Devices/*/data/Containers/Data/Application/*/Documents 2>/dev/null | xargs -I{} sh -c 'ls "{}"/*.mp4 2>/dev/null' | tail -1)
ffprobe -v error -show_entries stream=codec_type -of csv=p=0 "$APP"   # expect both: video AND audio
```
Expected: lists a `video` and an `audio` stream.

- [ ] **Step 4: Non-muxable / HLS case** — paste an HLS-only or VP9/AV1-only link. Expected: a clear `.needsFfmpeg` message, not a crash.

- [ ] **Step 5: Record results** — create `docs/logs/<today>-NN-milestone-2-acceptance.md` (next free `NN` for the day): device/iOS, URLs tried, outcomes, whether the merged file plays with audio, built `.app` size (`du -sh`). Commit:

```bash
git add docs/logs/
git commit -m "docs(log): record Milestone 2 acceptance results"
```

- [ ] **Step 6: Done-check** — confirm the spec's done criteria:
  1. A DASH source downloads as a single playable MP4 with audio.
  2. Progressive sources still work.
  3. Per-format HTTP headers are sent on downloads.
  4. Non-muxable / HLS / auth fail with the correct `KeraunosError`.
  5. No temp-file leakage.
  6. `KeraunosCore` `swift test` + Python `pytest` + app `xcodebuild test` all green.

---

## Self-Review notes (for the executor)

- **Spec coverage:** model (Task 2) · headers (Task 3) · `MediaMerging`/`MockMerger` (Task 4) · `AVFoundationMerger` passthrough (Task 5) · `MediaAssembler` progressive/adaptive/cleanup (Task 6) · Python progressive/adaptive/needs_ffmpeg contract + HEVC→H.264→AAC selector (Task 7) · UI + phase + wiring (Task 8) · `.mergeFailed` (Task 1) · testing tiers (Tasks 2–8) · manual acceptance + done-check (Task 9).
- **Type consistency:** `MediaTrack(url:httpHeaders:codec:fileExtension:)`, `ResolvedMedia(kind:title:suggestedFilename:)` with `Kind.progressive`/`.adaptive(video:audio:)`, `FileDownloading.download(_:to:)` (track, full destination URL), `MediaMerging.merge(video:audio:into:)`, `MediaAssembler(downloader:merger:).assemble(_:into:onPhase:)` with `Phase` — used identically across Core, Python contract, and app.
- **Migration ordering:** Task 2 reshapes the model and updates every package-level consumer in one task so `swift test` stays green; the app target is intentionally red between Tasks 2 and 8 and is verified only via `swift test` until Task 8 rebuilds it.
- **Deferred (NOT Milestone 2):** HLS, ffmpeg backend, VP9/AV1/Opus, format/quality picker, queue/history, audio-only, cookies/auth, percent-progress, parallel track downloads. The ffmpeg backend later = a second `MediaMerging` implementation; assembler/model/UI unchanged.
```
