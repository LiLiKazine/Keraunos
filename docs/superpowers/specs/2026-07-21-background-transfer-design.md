# Background Transfer — Design

**Date:** 2026-07-21
**Status:** Approved design; ready for implementation planning.
**Roadmap anchor:** `docs/superpowers/plans/2026-06-22-keraunos-coverage-roadmap.md` Phase 4, step 5
("`Downloader` delegate rewrite — one change, three wins"). README "Planned: Background
transfer & resume for large (4K) files."

## Goal

Replace the in-memory, foreground-only transfer with a durable, multi-job **background
transfer engine**, so downloads — especially large 4K YouTube files — continue while the
app is suspended, survive iOS terminating and relaunching the app, resume after
interruption, and surface in a downloads-list UI with per-item progress.

This is the delegate rewrite the roadmap calls for: replace `URLSession.shared` +
`session.download(for:delegate:)` (async-convenience, cannot background, cannot resume)
with the `URLSession` **delegate** API on a **background `URLSessionConfiguration`**.

### In scope

- Background `URLSessionConfiguration` + session-level `URLSessionDownloadDelegate`; app
  relaunch handling via `handleEventsForBackgroundURLSession`.
- A durable **job queue** supporting multiple concurrent/queued downloads, persisted
  across launches.
- Sequential ranged **download-task** driver for the chunked (googlevideo) path;
  single-shot download task for progressive.
- **Resume:** chunked via part-file offset; progressive via `URLSession` resume data.
- Adaptive (DASH) orchestration with **merge-on-completion, foreground fallback**.
- A **downloads-list UI** with per-job progress, reconnecting after relaunch.

### Non-goals (YAGNI)

- Parallel chunk fetching — rejected; it fights the googlevideo throttling the chunked
  path exists to avoid.
- Re-encoding/transcoding merge — stays passthrough remux (`AVFoundationMerger`).
- Background *uploads*, iCloud, or cross-device state.

## Key platform constraints that shape this design

- **Background sessions support only `downloadTask`/`uploadTask` — not `dataTask`.** The
  current chunked path (`session.data(for:)`, `Downloader.swift:76`) cannot run in a
  background session and must be re-architected onto download tasks.
- **googlevideo throttles unranged full-file GETs** (per `CLAUDE.md`). 4K YouTube is
  usually adaptive (separate video+audio), *both* tracks from googlevideo, *both*
  carrying the `downloader_options.http_chunk_size` hint. So the primary target combines
  adaptive **and** chunked — the chunked path must background, it cannot be left in the
  foreground.
- **A whole-file ranged GET likely looks like the unranged GET that gets throttled** —
  yt-dlp splits deliberately. So we honor the hinted chunk size and issue **sequential**
  ranged requests (one in flight at a time).
- **Background app launches have a tight CPU/time budget** — a multi-GB 4K passthrough
  mux may not finish, so merge must have a foreground fallback.

## Architecture & the core/app boundary

Preserve the codebase rule: a **simulator-free, protocol-seamed `KeraunosCore`**, with
only the genuinely lifecycle-bound glue in the app target.

### `KeraunosCore` (pure, `swift test`-able)

- `TransferJob` / `TransferJobStore` — durable job + queue model (Codable), persisted to
  a JSON file in Application Support.
- Chunk math, resume-offset computation, part-file append/concatenation logic.
- `TransferSession` **protocol seam** — the abstraction the engine drives (create a
  download task for a URL + optional Range, cancel-producing-resume-data, enumerate live
  tasks). Mockable in tests.
- `TransferCoordinator` — the engine actor: single-shot + sequential-chunked drivers,
  resume, and the adaptive orchestration state machine.
- `TransferProgress` — an actor-owned, per-job progress store.

### App target (thin glue)

- A concrete type wrapping `URLSession(configuration: .background(withIdentifier:))`,
  conforming to `TransferSession`, plus the session-level `URLSessionDownloadDelegate`.
- App-delegate `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
  completion-handler storage + session recreation with the same identifier.
- The `UIApplication.beginBackgroundTask` assertion wrapping the merge attempt.
- The SwiftUI downloads-list.

**Consequence:** the current `Downloader` struct and `MediaAssembler`'s sequential
`await` flow are **rewritten** into this event-driven, job-orchestrated engine. The bulk
of the logic stays unit-testable without a simulator. `MediaMerging`/`AVFoundationMerger`,
`DownloadStore`, and `PhotoSaving` are reused unchanged behind their existing protocols.

## Job model & persistence

```
TransferJob (Codable, Sendable)
  id: UUID
  sourcePageURL: URL                 // original page, for display/retry
  createdAt: Date
  state: .queued | .downloading | .readyToMerge | .merging
       | .completed | .failed(reason) | .cancelled
  kind: .progressive(TrackJob) | .adaptive(video: TrackJob, audio: TrackJob)
  suggestedFilename: String
  finalDestination: URL?             // set when moved into DownloadStore
  autoSaveToPhotos: Bool

TrackJob
  remoteURL: URL
  chunkSize: Int?                    // nil = single-shot; >0 = sequential ranged
  partFileURL: URL                   // accumulating bytes, Application Support/parts/
  bytesWritten: Int64                // == resume offset for the chunked path
  totalBytes: Int64?
  resumeData: Data?                  // single-shot path only
  taskIdentifier: Int?               // live URLSession task, for reassociation
```

- **Store:** `TransferJobStore`, an `actor` owning the job array, persisted **atomically**
  to `Application Support/transfers.json` on every state transition.
- **Rehydration & reassociation on launch:** the store loads persisted jobs; the
  app-target driver calls `session.getAllTasks()` and reassociates live
  `taskIdentifier`s with jobs. Any job whose task has vanished (killed mid-flight) is
  resumed from `bytesWritten` (chunked) or `resumeData` (single-shot).
- **Part files** live in a stable, non-purgeable directory (Application Support, **not**
  `temporaryDirectory`) so they survive relaunch — a change from today's `temporaryDirectory`
  scratch dir.

## The transfer engine

`TransferCoordinator` (Core actor) drives jobs against the `TransferSession` seam.

- **Progressive / single-shot:** one download task, no Range. On finish, move the temp
  file into the part file / destination. On failure, capture `resumeData`; resume creates
  a task from resume data.
- **Chunked (sequential ranged):** issue a `downloadTask` with
  `Range: bytes=bytesWritten-(bytesWritten+chunkSize-1)`. Delegate `didFinishDownloadingTo`
  → append the temp file to `partFileURL`, advance `bytesWritten`, persist, kick the next
  chunk. Port today's `downloadChunked` handling directly:
  - **HTTP 200** = server ignored Range; body is the whole file. Valid only when
    `bytesWritten == 0` (else throw, to avoid corruption); write it, done.
  - **HTTP 206** = partial; parse total from `Content-Range`, append, advance, report.
  - Terminate on a short/empty chunk or `bytesWritten >= totalBytes`.
  - Any other status → `.downloadNetwork`.
  - **Resume is implicit**: `bytesWritten` *is* the offset — no `URLSession` resume data
    needed for this path.
- The `didFinishDownloadingTo` file move/append is synchronous inside the delegate (the
  handed temp file is deleted after the callback returns); control then hops to the
  coordinator actor to advance job state. Byte-progress callbacks feed `TransferProgress`.

## Adaptive orchestration & merge

The adaptive state machine downloads **video then audio** (sequential; each track may be
chunked), each contributing to the job's overall progress. When both `TrackJob`s reach
their byte total → `state = .readyToMerge`. Then (merge-on-completion, foreground
fallback):

1. The app-target driver takes a `UIApplication.beginBackgroundTask` assertion and calls
   `MediaMerging.merge(video:audio:into: store.uniqueDestination(for:))`.
2. Completes → `.completed`; run auto-save-to-Photos (existing `PhotoLibrarySaver`),
   delete part files.
3. Assertion expires first → remain `.readyToMerge`; on next foreground,
   `TransferCoordinator` finds ready jobs and merges then.

`MediaAssembler` is absorbed into this state machine.

## Progress & the downloads-list UI

- **Progress store:** `actor TransferProgress` holds `[JobID: ProgressSnapshot]`
  (fraction, bytes, state, phase). Delegate byte callbacks and coordinator state changes
  write to it. The UI reads via an `@Observable @MainActor` `DownloadsViewModel` that
  mirrors snapshots (fed by an `AsyncStream` from the store). Because progress is
  reconstructed from the persisted store + live `getAllTasks()` reassociation, the UI
  **reconnects after relaunch** — no reliance on a surviving closure.
- **UI shape:** `HomeScreen` keeps the paste/extract entry point and format picker.
  Starting a download now **enqueues a job** (no longer cancels the prior one) and pushes
  to a **Downloads list** — one row per job: filename, per-item progress bar, state label,
  per-row actions (pause/cancel, retry-failed, delete). Completed rows link to the saved
  file / Photos. The current single inline progress view is replaced by this list.
- `DownloadViewModel`'s single-shot `currentTask` model is retired in favor of the queue.

## Error handling

- Keep the existing `KeraunosError` mapping (`.cancelled`, `.downloadNetwork`). Add a
  durable per-job `.failed(reason)` state so failures survive relaunch and are retryable
  from the list.
- Network drop mid-chunk → task fails → job stays `.downloading` with intact
  `bytesWritten`; auto-resume on next launch / reachability, retry from offset.
- Corruption guards from today (200-not-at-offset-0, zero-byte, HTTP non-2xx) port over.
- Merge failure → `.failed`; part files retained for retry until the user deletes.

## Testing

- **Core (simulator-free, `swift test`):**
  - `TransferJobStore` persistence / rehydration round-trips.
  - Chunk-offset & resume math.
  - Adaptive state-machine transitions (queued → downloading → readyToMerge → completed).
  - The sequential chunk engine driven against a **mock `TransferSession`** simulating
    206 / 200 / short-chunk / failure / relaunch-with-missing-task.
  - This is the bulk of the logic and stays fast.
- **App integration (simulator, localhost):** a real background `URLSession` against a
  localhost server serving Range requests (per the existing "never real sites" rule).
  Reassociation tested by simulating task loss.

## Implementation phasing

One spec; implementation lands in dependency order, each step independently testable:

1. **Job model + `TransferJobStore` + persistence** (pure Core, TDD).
2. **`TransferSession` seam + `TransferCoordinator`**: single-shot, then sequential
   chunked, then resume — against the mock session.
3. **App-target background `URLSession` driver + session delegate + app-delegate relaunch
   glue.**
4. **Adaptive orchestration + merge-with-fallback.**
5. **Downloads-list UI + progress reconnection.**
