# Ranged/Chunked Downloads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Download YouTube (googlevideo) streams in HTTP Range chunks so they don't stall/time out, leaving every other site on the current single-shot path.

**Architecture:** Thread yt-dlp's `downloader_options.http_chunk_size` end-to-end (`_track` → wire JSON → `MediaTrack.chunkSize`). `Downloader` chunks a track only when `chunkSize > 0`; otherwise the existing single-shot code path is byte-for-byte unchanged.

**Tech Stack:** Swift 6 (KeraunosCore SPM package, Swift Testing, `URLSession`), embedded CPython/yt-dlp.

## Global Constraints

- **Swift Testing only** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- **Swift Concurrency over GCD**; propagate `Task` cancellation.
- **Chunk only when hinted:** a track is chunked only when its format carries `http_chunk_size` (YouTube). All other sites stay single-shot. Do not add always-chunk behavior.
- **No per-chunk resume, no background downloads** (YAGNI).
- **Downloader/integration tests run against localhost/`StubURLProtocol` only** — never real sites. On-device googlevideo confirmation is owner-run and out of scope for these tests.
- **Pure/Swift units written first (TDD).**
- Commit trailer exactly: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- KeraunosCore (`app/KeraunosCore`) tested with `swift test`. Python has **no pytest available** — run a named test function directly (see Task 2).
- YouTube's chunk size is `10 << 20` = `10485760` bytes (reference value for tests).

---

### Task 1: `MediaTrack.chunkSize` + decoder wire-through

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/MediaTrack.swift`
- Modify: `app/KeraunosCore/Sources/KeraunosCore/ResolvedMedia.swift` (`TrackPayload`, `ExtractionDecoder.track`)
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/ExtractionDecodingTests.swift`

**Interfaces:**
- Consumes: existing `MediaTrack`, `ExtractionDecoder`, `TrackPayload`.
- Produces: `MediaTrack` gains `public let chunkSize: Int?` with `init(..., chunkSize: Int? = nil)` (defaulted — additive). `ExtractionDecoder.track(_:)` populates it from the wire key `chunk_size`.

- [ ] **Step 1: Write the failing tests** (append to `ExtractionDecodingTests`)

```swift
    @Test func decodesChunkSizeFromWire() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"T","filename":"c.mp4",
         "media":{"url":"https://x.test/v.mp4","headers":{},"vcodec":"avc1","acodec":"mp4a","ext":"mp4","chunk_size":10485760}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        guard case let .progressive(track) = media.kind else { Issue.record("expected progressive"); return }
        #expect(track.chunkSize == 10485760)
    }

    @Test func chunkSizeNilWhenAbsent() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"T","filename":"c.mp4",
         "media":{"url":"https://x.test/v.mp4","headers":{},"vcodec":"avc1","acodec":"mp4a","ext":"mp4"}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        guard case let .progressive(track) = media.kind else { Issue.record("expected progressive"); return }
        #expect(track.chunkSize == nil)
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path app/KeraunosCore --filter ExtractionDecodingTests`
Expected: FAIL — `value of type 'MediaTrack' has no member 'chunkSize'`.

- [ ] **Step 3: Add `chunkSize` to `MediaTrack`**

Replace the body of `app/KeraunosCore/Sources/KeraunosCore/MediaTrack.swift` (keep the file/doc comment) with:

```swift
public struct MediaTrack: Equatable, Sendable {
    public let url: URL
    public let httpHeaders: [String: String]
    public let codec: String
    public let fileExtension: String
    /// Preferred HTTP Range chunk size in bytes, from yt-dlp's
    /// `downloader_options.http_chunk_size`. `nil` for hosts that download fine in one
    /// request; a positive value opts the track into ranged/chunked downloading
    /// (googlevideo throttles unranged full-file GETs).
    public let chunkSize: Int?

    public init(url: URL, httpHeaders: [String: String], codec: String,
                fileExtension: String, chunkSize: Int? = nil) {
        self.url = url
        self.httpHeaders = httpHeaders
        self.codec = codec
        self.fileExtension = fileExtension
        self.chunkSize = chunkSize
    }
}
```

- [ ] **Step 4: Decode `chunk_size` in `ResolvedMedia.swift`**

Change `TrackPayload` to add the field with an explicit `CodingKeys` (the JSON key is snake_case):

```swift
/// Wire format emitted by keraunos_extract.py.
private struct TrackPayload: Decodable {
    let url: String
    let headers: [String: String]?
    let vcodec: String?
    let acodec: String?
    let ext: String?
    let chunkSize: Int?
    enum CodingKeys: String, CodingKey {
        case url, headers, vcodec, acodec, ext
        case chunkSize = "chunk_size"
    }
}
```

And pass it through in `ExtractionDecoder.track(_:)`:

```swift
    private static func track(_ payload: TrackPayload?) -> MediaTrack? {
        guard let payload, let url = URL(string: payload.url) else { return nil }
        return MediaTrack(url: url,
                          httpHeaders: payload.headers ?? [:],
                          codec: payload.vcodec ?? payload.acodec ?? "",
                          fileExtension: payload.ext ?? url.pathExtension,
                          chunkSize: payload.chunkSize)
    }
```

- [ ] **Step 5: Run to verify pass**

Run: `swift test --package-path app/KeraunosCore --filter ExtractionDecodingTests`
Expected: PASS. Also run the full package once: `swift test --package-path app/KeraunosCore` → PASS (the defaulted `chunkSize` keeps all existing `MediaTrack(...)` call sites compiling).

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/MediaTrack.swift \
        app/KeraunosCore/Sources/KeraunosCore/ResolvedMedia.swift \
        app/KeraunosCore/Tests/KeraunosCoreTests/ExtractionDecodingTests.swift
git commit -m "$(cat <<'EOF'
feat(core): thread http_chunk_size into MediaTrack.chunkSize

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Python `_track` emits `chunk_size`

**Files:**
- Modify: `app/Keraunos/PythonResources/app/keraunos_extract.py` (`_track`)
- Test: `app/Keraunos/python-dev/test_extract.py`

**Interfaces:**
- Consumes: nothing new.
- Produces: `_track(fmt)` dict gains `"chunk_size"` = `fmt["downloader_options"]["http_chunk_size"]` (or `None`).

- [ ] **Step 1: Write the failing tests** (append to `app/Keraunos/python-dev/test_extract.py`)

```python
# --- _track surfaces the chunk-size hint (for ranged downloads) -------------------
def test_track_surfaces_http_chunk_size_from_downloader_options():
    t = keraunos_extract._track({
        "url": "https://r.googlevideo.com/x", "http_headers": {"User-Agent": "yt"},
        "vcodec": "avc1", "acodec": "none", "ext": "mp4",
        "downloader_options": {"http_chunk_size": 10485760},
    })
    assert t["chunk_size"] == 10485760


def test_track_chunk_size_none_without_downloader_options():
    t = keraunos_extract._track({"url": "https://x/a.mp4", "ext": "mp4"})
    assert t["chunk_size"] is None
```

- [ ] **Step 2: Run to verify failure**

Run (pytest is NOT installed — call the functions directly):
```bash
cd app/Keraunos/python-dev && python3.12 -c "import test_extract as t; t.test_track_surfaces_http_chunk_size_from_downloader_options()"
```
Expected: FAIL — `KeyError: 'chunk_size'` (the dict has no such key yet).

> If `python3.12` is unavailable, use any `python3` ≥ 3.9 on PATH; the test only needs `keraunos_extract` importable (it imports `yt_dlp` from the bundled `app_packages`, pure Python).

- [ ] **Step 3: Add `chunk_size` to `_track`**

In `keraunos_extract.py`, change `_track`:

```python
def _track(fmt):
    return {
        "url": fmt.get("url"),
        "headers": fmt.get("http_headers") or {},
        "vcodec": fmt.get("vcodec"),
        "acodec": fmt.get("acodec"),
        "ext": fmt.get("ext"),
        # yt-dlp tags googlevideo (YouTube) formats with a chunk size; the native
        # Downloader honors it with ranged requests to avoid googlevideo throttling
        # single-shot GETs. None for hosts that download fine unranged.
        "chunk_size": (fmt.get("downloader_options") or {}).get("http_chunk_size"),
    }
```

- [ ] **Step 4: Run to verify pass**

Run:
```bash
cd app/Keraunos/python-dev && python3.12 -c "import test_extract as t; t.test_track_surfaces_http_chunk_size_from_downloader_options(); t.test_track_chunk_size_none_without_downloader_options(); print('PASS')"
```
Expected: `PASS`.

Also sanity-check the module still parses:
```bash
python3.12 -c "import ast; ast.parse(open('/Users/leo/Developer/Keraunos/app/Keraunos/PythonResources/app/keraunos_extract.py').read()); print('OK')"
```

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/PythonResources/app/keraunos_extract.py \
        app/Keraunos/python-dev/test_extract.py
git commit -m "$(cat <<'EOF'
feat(extract): surface downloader_options.http_chunk_size in _track

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Chunked `Downloader` path

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/Downloader.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/DownloaderTests.swift`

**Interfaces:**
- Consumes: `MediaTrack.chunkSize` (Task 1); existing `Downloader(session:)`, `KeraunosError.downloadNetwork`/`.cancelled`, `StubURLProtocol`.
- Produces: no new public API — `Downloader.download(_:to:onProgress:)` internally routes `chunkSize > 0` tracks through ranged/chunked transfer.

- [ ] **Step 1: Write the failing tests** (add inside `struct DownloaderTests` in `DownloaderTests.swift`)

First add these test helpers at the top of the `DownloaderTests` struct (after the existing `track(_:)` helper):

```swift
    /// Chunked track helper (opts into ranged download).
    private func chunkedTrack(_ s: String = "https://x.test/v.mp4", chunk: Int) -> MediaTrack {
        MediaTrack(url: URL(string: s)!, httpHeaders: [:], codec: "avc1",
                   fileExtension: "mp4", chunkSize: chunk)
    }

    /// Serves `body` honoring the Range header with 206 + Content-Range (or a single
    /// 200 with the whole body when `ignoreRange`), counting requests. Thread-safe;
    /// the Downloader issues chunk requests serially so contention is nil in practice.
    final class ChunkServer: @unchecked Sendable {
        let body: Data
        let ignoreRange: Bool
        private let lock = NSLock()
        private var _count = 0
        init(body: Data, ignoreRange: Bool = false) { self.body = body; self.ignoreRange = ignoreRange }
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func respond(_ req: URLRequest) -> (HTTPURLResponse, Data) {
            lock.lock(); _count += 1; lock.unlock()
            if ignoreRange {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            let raw = (req.value(forHTTPHeaderField: "Range") ?? "bytes=0-").dropFirst("bytes=".count)
            let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts.first ?? "") ?? 0
            let end = min(Int(parts.count > 1 ? parts[1] : "") ?? (body.count - 1), body.count - 1)
            let slice = body.subdata(in: start..<(end + 1))
            let resp = HTTPURLResponse(url: req.url!, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes \(start)-\(end)/\(body.count)"])!
            return (resp, slice)
        }
    }

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock(); private var _v = 0.0
        var value: Double { lock.lock(); defer { lock.unlock() }; return _v }
        func set(_ v: Double) { lock.lock(); _v = v; lock.unlock() }
    }
```

Then the tests:

```swift
    @Test func chunkedDownloadAssemblesFullFileAcrossRangedRequests() async throws {
        let body = Data((0..<25).map { UInt8($0) })   // 25 bytes, chunk 10 → 3 requests
        let server = ChunkServer(body: body)
        StubURLProtocol.handler = { server.respond($0) }
        let dest = tempFile("clip.mp4")
        try await Downloader(session: StubURLProtocol.session()).download(chunkedTrack(chunk: 10), to: dest)
        #expect(try Data(contentsOf: dest) == body)
        #expect(server.requestCount == 3)
    }

    @Test func chunkedDownloadSendsRangeAndTrackHeaders() async throws {
        StubURLProtocol.lastRequest = nil
        let server = ChunkServer(body: Data((0..<5).map { UInt8($0) }))   // one chunk
        StubURLProtocol.handler = { server.respond($0) }
        let t = MediaTrack(url: URL(string: "https://x.test/v.mp4")!,
                           httpHeaders: ["Referer": "https://x.test/"],
                           codec: "avc1", fileExtension: "mp4", chunkSize: 10)
        try await Downloader(session: StubURLProtocol.session()).download(t, to: tempFile("clip.mp4"))
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=") == true)
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer") == "https://x.test/")
    }

    @Test func chunkedDownloadFallsBackToWholeBodyOn200() async throws {
        let body = Data("the whole file".utf8)
        let server = ChunkServer(body: body, ignoreRange: true)   // server ignores Range → 200
        StubURLProtocol.handler = { server.respond($0) }
        let dest = tempFile("clip.mp4")
        try await Downloader(session: StubURLProtocol.session()).download(chunkedTrack(chunk: 4), to: dest)
        #expect(try Data(contentsOf: dest) == body)
        #expect(server.requestCount == 1)   // no further ranged requests after the 200
    }

    @Test func chunkedDownloadReportsProgressToCompletion() async throws {
        let server = ChunkServer(body: Data((0..<25).map { UInt8($0) }))
        StubURLProtocol.handler = { server.respond($0) }
        let progress = ProgressBox()
        try await Downloader(session: StubURLProtocol.session())
            .download(chunkedTrack(chunk: 10), to: tempFile("clip.mp4"), onProgress: { progress.set($0) })
        #expect(progress.value == 1.0)
    }

    @Test func chunkedDownloadMapsHTTPErrorToDownloadNetwork() async throws {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await #expect(throws: KeraunosError.downloadNetwork) {
            try await Downloader(session: StubURLProtocol.session()).download(chunkedTrack(chunk: 10), to: tempFile("clip.mp4"))
        }
    }

    @Test func chunkedDownloadMapsCancellation() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await #expect(throws: KeraunosError.cancelled) {
            try await Downloader(session: StubURLProtocol.session()).download(chunkedTrack(chunk: 10), to: tempFile("clip.mp4"))
        }
    }
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path app/KeraunosCore --filter DownloaderTests`
Expected: FAIL — the chunked tests fail (no chunked path yet; a `chunkSize` track currently goes single-shot and the `ChunkServer` 206 slices don't reconstruct the file / request counts are wrong).

- [ ] **Step 3: Implement the chunked path in `Downloader.swift`**

Add the branch at the top of the `do` in `download(_:to:onProgress:)` (before the existing single-shot code):

```swift
    public func download(_ track: MediaTrack, to destination: URL,
                         onProgress: @escaping @Sendable (Double) -> Void) async throws {
        do {
            if let chunk = track.chunkSize, chunk > 0 {
                try await downloadChunked(track, chunkSize: chunk, to: destination, onProgress: onProgress)
                return
            }
            var request = URLRequest(url: track.url)
            for (field, value) in track.httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
            let (tempURL, response) = try await session.download(
                for: request, delegate: DownloadProgressDelegate(onProgress: onProgress))
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw KeraunosError.downloadNetwork
            }
            let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { throw KeraunosError.downloadNetwork }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch let error as KeraunosError {
            throw error
        } catch let urlError as URLError where urlError.code == .cancelled {
            throw KeraunosError.cancelled
        } catch is CancellationError {
            throw KeraunosError.cancelled
        } catch {
            throw KeraunosError.downloadNetwork
        }
    }

    /// Downloads a track in sequential HTTP Range chunks (for hosts like googlevideo that
    /// throttle unranged full-file GETs), assembling into a temp file then moving into place.
    /// A `200` response means the server ignored `Range` — that body IS the whole file.
    private func downloadChunked(_ track: MediaTrack, chunkSize: Int, to destination: URL,
                                 onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw KeraunosError.downloadNetwork
        }
        let handle = try FileHandle(forWritingTo: tempURL)
        var closed = false
        defer { if !closed { try? handle.close() } }

        var offset = 0
        var total: Int64?
        while true {
            try Task.checkCancellation()
            var request = URLRequest(url: track.url)
            for (field, value) in track.httpHeaders { request.setValue(value, forHTTPHeaderField: field) }
            request.setValue("bytes=\(offset)-\(offset + chunkSize - 1)", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw KeraunosError.downloadNetwork }
            if http.statusCode == 200 {          // server ignored Range → whole file
                try handle.write(contentsOf: data)
                offset += data.count
                onProgress(1.0)
                break
            } else if http.statusCode == 206 {
                if total == nil { total = Self.totalBytes(fromContentRange: http) }
                try handle.write(contentsOf: data)
                offset += data.count
                if let t = total, t > 0 { onProgress(min(1.0, Double(offset) / Double(t))) }
                if data.isEmpty { break }
                if let t = total, Int64(offset) >= t { break }
            } else {
                throw KeraunosError.downloadNetwork
            }
        }

        try handle.close(); closed = true
        let size = (try? tempURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else {
            try? FileManager.default.removeItem(at: tempURL)
            throw KeraunosError.downloadNetwork
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Parses the total size out of a `Content-Range: bytes a-b/total` header. Returns nil
    /// for an unknown total (`.../*`), in which case progress isn't reported but assembly
    /// still terminates on a short/empty chunk.
    private static func totalBytes(fromContentRange http: HTTPURLResponse) -> Int64? {
        guard let value = http.value(forHTTPHeaderField: "Content-Range"),
              let slash = value.lastIndex(of: "/") else { return nil }
        return Int64(value[value.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --package-path app/KeraunosCore --filter DownloaderTests`
Expected: PASS — all chunked tests plus the pre-existing single-shot tests (which use `chunkSize == nil` tracks and are unchanged).

Then the full package: `swift test --package-path app/KeraunosCore` → PASS.

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/Downloader.swift \
        app/KeraunosCore/Tests/KeraunosCoreTests/DownloaderTests.swift
git commit -m "$(cat <<'EOF'
feat(core): ranged/chunked download path for hinted tracks

Why: googlevideo (YouTube) throttles single-shot unranged GETs, stalling
downloads to a -1001 timeout; yt-dlp avoids this by fetching in Range chunks.

What changed:
- Downloader chunks a track (sequential Range requests → temp file → move) when
  MediaTrack.chunkSize > 0; otherwise the single-shot path is unchanged.
- 200 response = server ignored Range = whole file (graceful fallback); per-chunk
  progress; Task cancellation checked each iteration; >0-byte dud guard kept.
- 6 StubURLProtocol tests: multi-chunk assembly, Range+headers sent, 200 fallback,
  progress to 1.0, HTTP-error and cancellation mapping.

What was discovered:
- YouTube sets downloader_options.http_chunk_size = 10 MiB on its formats; honoring
  it is what distinguishes yt-dlp's working downloads from our single-shot stalls.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Notes for the implementer

- **The single-shot path must stay byte-for-byte unchanged.** It serves the 5 sites that already work; only the new `if let chunk = track.chunkSize, chunk > 0` branch is added ahead of it. Do not "refactor while here."
- **`session.data(for:)` is used for chunks** (each chunk ≤ ~10 MB in memory), distinct from the single-shot `session.download(for:delegate:)`. That's intentional — the chunked path computes progress directly from byte offsets, so it doesn't need the delegate.
- **On-device verification is owner-run** and out of scope: the localhost tests fully cover the chunking mechanism, but only a device run confirms it defeats real googlevideo throttling. Do not attempt to download real YouTube URLs in tests.
- Per CLAUDE.md: after Swift/bridge changes, a clean build may be needed on-device — but that's for the owner's device run, not these package tests.
```
