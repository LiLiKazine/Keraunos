# Background Transfer — Phase 5: Media-URL refresh — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Detect resolved-URL expiry (a live `403`/`410`, or the parsed `expire=` deadline passing an injectable clock), route the job to `.needsRefresh` instead of `.failed`, and — given a fresh URL from a foreground re-extraction — resume safely (`Content-Length` matches the persisted `totalBytes` ⇒ continue from `bytesWritten`; mismatch ⇒ restart that track from zero). Pure, simulator-free `KeraunosCore` with no real clock.

**Architecture:** A pure `MediaURLExpiry.expiry(of:)` parses the googlevideo `expire=` param. `TransferCoordinator` gains an injectable `now` clock: `beginTrack` proactively refuses to start an already-expired track (→ `.needsRefresh`), and the completion handler maps `403`/`410` to `.needsRefresh` rather than `.failed(.network)`. A new `refresh(...)` entry point applies the resume-vs-restart decision and re-begins the track. The foreground re-extraction itself (Python) is app glue; Core exposes the decision + state transitions it drives.

**Tech Stack:** Swift 6, Swift Testing, `Foundation` (`URLComponents`).

**Spec:** `docs/superpowers/specs/2026-07-21-background-transfer-design.md` ("Media-URL refresh (expiry recovery)"; phasing step 5).

## Global Constraints

- Swift 6 language mode; package default isolation `nonisolated`; Swift Testing only; all logic in `KeraunosCore`.
- **Injectable clock** — no `Date()` in tested logic; the coordinator takes `now: @Sendable () -> Date`.
- **One recovery path covers URL and credential expiry** — both surface as `403` → `.needsRefresh`.
- **Resume-safety:** equal `Content-Length` ⇒ resume from `bytesWritten` (same itag ⇒ byte-identical); unequal ⇒ restart that track from zero (truncate its part to 0).
- Run tests: `swift test --package-path app/KeraunosCore`.

## What this phase deliberately does NOT do

- **No Python re-extraction, no format re-selection** — app glue (Phase 3/5-glue). Core's `refresh(...)` is handed the already-obtained fresh URL/expiry/length; a re-extraction that can't re-select the format is where the app sets `.failed(.refreshFailed)`.

---

## File Structure

- `app/KeraunosCore/Sources/KeraunosCore/MediaURLExpiry.swift` — pure `expire=` parser.
- `app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift` — MODIFY: injectable clock, proactive expiry check, `403`/`410` → `.needsRefresh`, `refresh(...)`.
- `app/KeraunosCore/Tests/KeraunosCoreTests/MediaURLExpiryTests.swift`
- `app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift` — ADD refresh tests.

---

### Task 1: `expire=` parser

**Files:** Create `MediaURLExpiry.swift` + `MediaURLExpiryTests.swift`.

**Interfaces:** Produces `enum MediaURLExpiry { static func expiry(of url: URL) -> Date? }`.

- [ ] **Step 1: Failing test** — `MediaURLExpiryTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct MediaURLExpiryTests {
    @Test func parsesExpireUnixTimestamp() {
        let url = URL(string: "https://r1.googlevideo.com/videoplayback?expire=1750000000&id=abc")!
        #expect(MediaURLExpiry.expiry(of: url) == Date(timeIntervalSince1970: 1_750_000_000))
    }
    @Test func nilWhenNoExpireParam() {
        #expect(MediaURLExpiry.expiry(of: URL(string: "https://cdn.example/v.mp4")!) == nil)
    }
    @Test func nilWhenExpireNotANumber() {
        #expect(MediaURLExpiry.expiry(of: URL(string: "https://x/y?expire=soon")!) == nil)
    }
}
```

- [ ] **Step 2: Run → fails** (`--filter MediaURLExpiryTests`).
- [ ] **Step 3: Implement** — `MediaURLExpiry.swift`:

```swift
import Foundation

/// Parses the googlevideo `expire=<unix-ts>` deadline embedded in a resolved media URL.
/// Used to pre-empt a download against an about-to-die URL (→ `.needsRefresh`) before the
/// host returns a `403`.
public enum MediaURLExpiry {
    /// The absolute expiry deadline, or nil if the URL carries no numeric `expire=` param.
    public static func expiry(of url: URL) -> Date? {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = comps.queryItems?.first(where: { $0.name == "expire" })?.value,
              let ts = TimeInterval(value) else { return nil }
        return Date(timeIntervalSince1970: ts)
    }
}
```

- [ ] **Step 4: Run → passes. Commit.**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/MediaURLExpiry.swift app/KeraunosCore/Tests/KeraunosCoreTests/MediaURLExpiryTests.swift
git commit -m "feat(transfer): googlevideo expire= parser"
```

---

### Task 2: `.needsRefresh` transitions + injectable clock + `refresh(...)`

**Files:** MODIFY `TransferCoordinator.swift`; ADD tests to `TransferCoordinatorTests.swift`.

**Interfaces:**
- Change: `init(store:session:now:)` gains `now: @Sendable () -> Date = { Date() }` (defaulted — existing 2-arg callers unaffected).
- Add: `func refresh(jobID: UUID, freshURL: URL, freshExpiresAt: Date?, freshContentLength: Int64?) async throws` — applies resume-vs-restart to the current incomplete track and re-begins it (`.downloading`).
- Behavior changes: `beginTrack` transitions to `.needsRefresh` (and starts no task) when the current track's `urlExpiresAt <= now()`; the completion handler maps `403`/`410` to `.needsRefresh`.

- [ ] **Step 1: Add the failing tests** to `TransferCoordinatorTests`:

```swift
    // MARK: media-URL refresh

    @Test func status403RoutesToNeedsRefresh() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data()),
                                             statusCode: 403, contentRangeTotal: nil)
        #expect(await store.job(id: j.id)!.state == .needsRefresh)
    }

    @Test func expiredURLDoesNotStartAndNeedsRefresh() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let now = Date(timeIntervalSince1970: 2000)
        let coord = TransferCoordinator(store: store, session: session, now: { now })
        var t = track(part: "c.part", chunkSize: 100)
        t.urlExpiresAt = Date(timeIntervalSince1970: 1000)      // already past `now`
        try await coord.start(job(kind: .progressive(t)))
        #expect(await session.started.isEmpty)                 // never issued a doomed request
        #expect(await store.all().first!.state == .needsRefresh)
    }

    @Test func refreshWithMatchingLengthResumesFromOffset() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: 250)
        // pretend the next request 403'd → needsRefresh
        let id2 = await session.started[1].id
        await coord.taskDidFinishDownloading(taskIdentifier: id2, to: stage(Data()),
                                             statusCode: 403, contentRangeTotal: nil)
        #expect(await store.job(id: j.id)!.state == .needsRefresh)

        let fresh = URL(string: "https://r2.googlevideo.com/vp?expire=9999999999")!
        try await coord.refresh(jobID: j.id, freshURL: fresh,
                                freshExpiresAt: Date(timeIntervalSince1970: 9_999_999_999),
                                freshContentLength: 250)          // matches persisted total
        let after = await store.job(id: j.id)!
        #expect(after.state == .downloading)
        #expect(after.tracks[0].bytesWritten == 100)             // resumed, not reset
        #expect(after.tracks[0].remoteURL == fresh)
        #expect(await session.lastRange() == "bytes=100-199")
    }

    @Test func refreshWithDifferentLengthRestartsTrack() async throws {
        let dir = tempDir()
        let store = try TransferJobStore(directory: dir)
        let session = ScriptedTransferSession()
        let coord = TransferCoordinator(store: store, session: session)
        let j = job(kind: .progressive(track(part: "c.part", chunkSize: 100)))
        try await coord.start(j)
        let id = await session.started[0].id
        await coord.taskDidFinishDownloading(taskIdentifier: id, to: stage(Data(repeating: 1, count: 100)),
                                             statusCode: 206, contentRangeTotal: 250)
        let id2 = await session.started[1].id
        await coord.taskDidFinishDownloading(taskIdentifier: id2, to: stage(Data()),
                                             statusCode: 410, contentRangeTotal: nil)

        let fresh = URL(string: "https://r3.googlevideo.com/vp")!
        try await coord.refresh(jobID: j.id, freshURL: fresh, freshExpiresAt: nil,
                                freshContentLength: 999)          // DIFFERENT length → restart
        let after = await store.job(id: j.id)!
        #expect(after.state == .downloading)
        #expect(after.tracks[0].bytesWritten == 0)               // restarted
        #expect(await session.lastRange() == "bytes=0-99")
        #expect(FileManager.default.fileSize(store.partFileURL(for: "c.part")) == 0)  // part reset
    }
```

Add a small helper if not present (fresh-stat file size is already defined at the bottom of the file).

- [ ] **Step 2: Run → fails** (403 test fails: currently 403 throws → `.failed(.network)`; `refresh`/`now:` don't exist).

- [ ] **Step 3: Modify the coordinator.**

3a. Add the clock and store it:

```swift
    private let now: @Sendable () -> Date
```
```swift
    public init(store: TransferJobStore, session: any TransferSession,
                now: @Sendable @escaping () -> Date = { Date() }) {
        self.store = store
        self.session = session
        self.now = now
    }
```

3b. In `taskDidFinishDownloading`, replace the final `else` branch
```swift
            } else {
                throw KeraunosError.downloadNetwork              // Phase 5 splits 403/410 → needsRefresh
            }
```
with an expiry-aware branch (do NOT throw for 403/410):
```swift
            } else if statusCode == 403 || statusCode == 410 {
                try await store.update(id: owner.jobID) { $0.state = .needsRefresh }
            } else {
                throw KeraunosError.downloadNetwork
            }
```

3c. In `beginTrack`, before building any request, add the proactive expiry guard:
```swift
        let track = job.tracks[trackIndex]
        if let expiry = track.urlExpiresAt, expiry <= now() {
            try await store.update(id: jobID) { $0.state = .needsRefresh }
            return
        }
```

3d. Add `refresh(...)` (e.g. after `reassociateAndResume`):
```swift
    /// Applies a foreground re-extraction result to the current incomplete track and resumes.
    /// Equal `Content-Length` ⇒ keep `bytesWritten` (same itag ⇒ byte-identical); a different
    /// length ⇒ restart that track from zero. Then re-begins the track (`.downloading`).
    public func refresh(jobID: UUID, freshURL: URL, freshExpiresAt: Date?,
                        freshContentLength: Int64?) async throws {
        guard let job = await store.job(id: jobID),
              let index = Self.firstIncompleteTrackIndex(job) else { return }
        let track = job.tracks[index]
        let canResume = freshContentLength != nil && freshContentLength == track.totalBytes
        if !canResume {
            try PartFile(url: store.partFileURL(for: track.partFileName)).truncate(to: 0)
        }
        try await store.update(id: jobID) {
            Self.mutateTrack(&$0, at: index) {
                $0.remoteURL = freshURL
                $0.urlExpiresAt = freshExpiresAt
                if !canResume { $0.bytesWritten = 0; $0.totalBytes = freshContentLength }
            }
            $0.state = .downloading
        }
        try await beginTrack(jobID: jobID, trackIndex: index)
    }
```

Note: `TrackJob.remoteURL` is a `let` — change it to `var` in `TransferJob.swift` (it now changes on refresh). Update the doc-comment on the property accordingly.

- [ ] **Step 4: Make `remoteURL` mutable.** In `TransferJob.swift`, change `public let remoteURL: URL` → `public var remoteURL: URL` (a refresh replaces it with a fresh resolved URL).

- [ ] **Step 5: Run → passes.** Then run the whole suite.

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/TransferCoordinator.swift app/KeraunosCore/Sources/KeraunosCore/TransferJob.swift app/KeraunosCore/Tests/KeraunosCoreTests/TransferCoordinatorTests.swift
git commit -m "feat(transfer): needsRefresh transitions + resume-safe URL refresh"
```

---

## Notes for later phases

- **App glue (Phase 3/5):** on foreground activation, find `.needsRefresh` jobs, re-run `PythonExtractor` for `sourcePageURL`, re-select the persisted `formatSelection`, obtain a fresh URL + `Content-Length`, and call `coord.refresh(...)`. If re-selection fails → `store.update { $0.state = .failed(.refreshFailed) }`. Expired auth cookies surface as the same `403` → one path covers URL + credential expiry.
