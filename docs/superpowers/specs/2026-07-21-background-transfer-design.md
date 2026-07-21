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
- **Media-URL refresh:** detect resolved-URL expiry (403/410, or the `expire=` deadline
  parsed from the URL) and recover via **foreground re-extraction + resume-from-offset**.
- **Authenticated downloads:** persist a credential *reference*; real cookies/headers live
  in the Keychain and are fetched at request-construction time.
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
- **A background session only makes progress across task boundaries by *waking the
  app*, and those wakes are rationed.** A single download task streams all its bytes with
  the app suspended, but the seam *between* tasks needs an app wake to append + enqueue
  the next chunk. iOS batches, delays, and backs off those wakes. So many small chunks =
  many rationed wakes = potentially glacial background throughput. Chunk *count*, not
  chunk *size*, is the cost driver here — the direct tension with throttle-safety is why
  the background chunk size needs a **de-risk spike** (see phasing).
- **Resolved media URLs expire.** googlevideo URLs embed an `expire=<unix-ts>` param and
  die in a few hours; re-extraction needs Python/yt-dlp, which **cannot run in the
  background**. So a long-deferred background download can wake to a dead URL, and
  recovery must be a *foreground* re-extraction. This is designed for explicitly (see
  "Media-URL refresh").
- **Background app launches have a tight CPU/time budget** — a multi-GB 4K passthrough
  mux may not finish, so merge must have a foreground fallback.
- **Background transfers run while the device is locked** — any Keychain items they read
  (auth cookies/headers) must be stored `AfterFirstUnlock`, or reads fail on a locked
  device and the transfer dies.

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
  **This is a process-wide singleton** — iOS permits exactly one live `URLSession` per
  background identifier, so a single owner constructs it and nothing (a second scene, a
  SwiftUI preview, a test) may instantiate a second with the same id.
- App-delegate `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
  completion-handler storage + session recreation with the same identifier.
- **Foreground re-extraction driver** for `.needsRefresh` jobs (calls `PythonExtractor`;
  Python is foreground-only).
- The `UIApplication.beginBackgroundTask` assertion wrapping the merge attempt.
- **Keychain access** for auth material, using `kSecAttrAccessibleAfterFirstUnlock`.
- The SwiftUI downloads-list.

### Launch ordering (critical)

iOS begins draining queued background events **only after** the session is recreated with
its identifier — so recreation must come *last*, after everything that could receive an
event is ready. The required order at launch, completed **before returning from the
app-delegate hook**:

1. **Load `transfers.json` synchronously** (it is tiny) so the job map exists.
2. **Wire the session-level delegate.**
3. **Then create the background session** — this is what opens the event floodgates.

Because a `didFinishDownloadingTo` for a not-yet-routed job could still arrive first, the
delegate additionally **stages the temp file synchronously** before any async hop (see
"The transfer engine"). Together these guarantee no completion event loses its bytes.

**Consequence:** the current `Downloader` struct and `MediaAssembler`'s sequential
`await` flow are **rewritten** into this event-driven, job-orchestrated engine. The bulk
of the logic stays unit-testable without a simulator. `MediaMerging`/`AVFoundationMerger`,
`DownloadStore`, and `PhotoSaving` are reused unchanged behind their existing protocols.

## Job model & persistence

```
TransferJob (Codable, Sendable)
  id: UUID
  sourcePageURL: URL                 // original page — for display, retry, RE-EXTRACTION
  formatSelection: FormatSelection   // format_id / itag + criteria to deterministically
                                     // re-pick the SAME format on refresh
  credentialRef: String?             // Keychain key; nil for anonymous downloads
  createdAt: Date
  state: .queued | .downloading | .needsRefresh | .readyToMerge | .merging
       | .completed | .failed(reason) | .cancelled
  kind: .progressive(TrackJob) | .adaptive(video: TrackJob, audio: TrackJob)
  suggestedFilename: String
  finalDestination: URL?             // set when moved into DownloadStore
  autoSaveToPhotos: Bool

TrackJob
  remoteURL: URL
  urlExpiresAt: Date?                // parsed from googlevideo `expire=`; nil if unknown
  chunkSize: Int?                    // nil = single-shot; >0 = sequential ranged
  partFileURL: URL                   // accumulating bytes, Application Support/parts/
  bytesWritten: Int64                // authoritative resume offset (chunked); see below
  totalBytes: Int64?                 // from first chunk's Content-Range / Content-Length
  resumeData: Data?                  // single-shot path only
  taskIdentifier: Int?               // live URLSession task, for reassociation
```

- **Store:** `TransferJobStore`, an `actor` owning the job array, persisted **atomically**
  to `Application Support/transfers.json`. Persist on **state transitions** and on **chunk
  completion** (advancing `bytesWritten`) — **not** on every byte-progress callback.
- **Crash-consistency rule (chunked):** `bytesWritten` is authoritative. The write order
  is **append chunk → `fsync` the part-file handle → persist `bytesWritten`**. Because the
  fsync precedes the persist, the part file is always **≥** the recorded offset, never
  shorter. On resume: **`truncate(partFile, to: bytesWritten)`** to discard any un-recorded
  tail, then request `Range: bytes=bytesWritten-…`. This kills the double-append
  corruption path at the cost of at most one re-downloaded chunk.
- **Rehydration & reassociation on launch:** the store loads persisted jobs; the
  app-target driver calls `session.getAllTasks()` and reassociates live
  `taskIdentifier`s with jobs. Any job whose task has vanished (killed mid-flight) is
  resumed from `bytesWritten` (chunked) or `resumeData` (single-shot).
- **Part files** live in a stable, non-purgeable directory (Application Support, **not**
  `temporaryDirectory`) so they survive relaunch — a change from today's `temporaryDirectory`
  scratch dir. **Orphan GC:** on launch, reconcile the parts directory against persisted
  jobs and delete any part file with no owning job (covers a crash between cancel and
  cleanup, since Application Support is never auto-purged).
- **Auth material is NOT stored here.** `credentialRef` is a Keychain key; cookies/headers
  are read from the Keychain (`AfterFirstUnlock`) at request-construction time.
- **Disk-space guard:** a 4K adaptive job holds the video part + audio part + the merged
  output transiently (~2.5× the final size). Check available space before enqueue and
  before merge; surface `.failed(insufficientSpace)` rather than dying mid-write on ENOSPC.

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
- **Synchronous stage-out.** `didFinishDownloadingTo` hands a temp file that iOS deletes
  the instant the delegate returns. The delegate therefore **moves it to a unique staging
  path synchronously, before any `await`/actor hop** — decoupling "save the bytes now"
  (mandatory, synchronous) from "figure out which job/track owns them" (async, on the
  coordinator actor). If routing finds no owner, the staged file is GC'd. This is what
  makes an event for a not-yet-routed job safe (see "Launch ordering").
- **Whole-file progress in chunked mode.** Each chunk task's `totalBytesExpectedToWrite`
  is the *chunk* size (or -1), not the file. Overall fraction is computed as
  `(bytesWritten + task.countOfBytesReceived) / totalBytes`, where `totalBytes` comes from
  the first chunk's `Content-Range`; before that is known, report indeterminate progress.

### Scheduling

- Background config: **`isDiscretionary = false`** and **`sessionSendsLaunchEvents =
  true`** so iOS runs transfers promptly rather than deferring for hours — this is the
  primary defense that most downloads finish inside a resolved URL's lifetime and never
  need refresh.
- **Background chunk size is a tuned parameter, not the yt-dlp hint.** The hinted size is
  a foreground floor; in the background we use the largest Range the host tolerates
  without re-triggering the throttle, to minimize wake count (see the de-risk spike in
  phasing). Worst case, chunked transfers are best-effort while suspended and chain fast
  once foregrounded.

### Media-URL refresh (expiry recovery)

- **Detect** expiry two ways: the parsed `urlExpiresAt` deadline approaching, or a live
  `403`/`410` from the host. Either transitions the affected track/job to
  **`.needsRefresh`** (recoverable) rather than `.failed`.
- **Recover in the foreground:** on next app activation, the re-extraction driver runs
  `PythonExtractor` for `sourcePageURL`, re-selects the **same** `formatSelection`, and
  obtains a fresh `remoteURL` (+ new `urlExpiresAt`).
- **Resume safely:** compare the refreshed source's `Content-Length` against the persisted
  `totalBytes`. **Equal → resume** from `bytesWritten` (same itag ⇒ byte-identical file).
  **Unequal → restart** that track from zero (rare; still better than a hard failure).
- Expired **auth cookies** surface as the same `403` → `.needsRefresh` → foreground
  re-auth/re-extract. One recovery path covers both URL and credential expiry.

## Adaptive orchestration & merge

The adaptive state machine downloads **video then audio** (sequential; each track may be
chunked), each contributing to the job's overall progress. Video and audio are two
*different* URLs, so running their chains concurrently is safe against the same-file
throttle we rejected — but we **keep them sequential for v1** to cap in-flight requests
per host and simplify progress accounting; concurrent tracks are a deferred optimization,
not a correctness need.

When both `TrackJob`s reach their byte total, the coordinator **verifies integrity**
(`part-file length == totalBytes` for each track) before advancing to
`state = .readyToMerge` — a truncated/short part must fail loudly here, not produce an
opaque merge error. Then (merge-on-completion, foreground fallback):

1. The app-target driver takes a `UIApplication.beginBackgroundTask` assertion and calls
   `MediaMerging.merge(video:audio:into: store.uniqueDestination(for:))`.
2. Completes → `.completed`; run auto-save-to-Photos (existing `PhotoLibrarySaver`),
   delete part files.
3. Assertion expires first → remain `.readyToMerge`; on next foreground,
   `TransferCoordinator` finds ready jobs and merges then.

**Reality of the "try immediately" branch.** A passthrough remux still *writes the whole
output file* (an 8 GB 4K video → an 8 GB write), and `beginBackgroundTask` buys only
~30 s, so for the headline 4K case the immediate attempt will **usually lose the race and
fall back** to foreground. The branch therefore mainly benefits small files. We keep it
because it is cheap to attempt and completes small jobs without a reopen — **but** it is
guarded: if a device spike confirms `AVAssetExportSession` or `PHPhotoLibrary.performChanges`
cannot run reliably during a URLSession background-launch window, the immediate branch is
dropped and merge/Photos always defer to foreground (behavior-equivalent to option "Always
defer," minus the wasted attempt). This is validated in the merge de-risk step, not
assumed.

`MediaAssembler` is absorbed into this state machine.

## Progress plumbing

- **Progress store:** `actor TransferProgress` holds `[JobID: ProgressSnapshot]`
  (fraction, bytes, state, phase). Delegate byte callbacks and coordinator state changes
  write to it. The UI reads via an `@Observable @MainActor` `DownloadsViewModel` that
  mirrors snapshots (fed by an `AsyncStream` from the store). Because progress is
  reconstructed from the persisted store + live `getAllTasks()` reassociation, the UI
  **reconnects after relaunch** — no reliance on a surviving closure.
- `DownloadViewModel`'s single-shot `currentTask` model is retired in favor of the queue.

## UI / UX

Designed in the **"Refined Native"** design system (Keraunos Claude Design project,
`117a4f30-…`); reuses its existing progress-card, list-row, `notice` (err/warn), empty-state,
and tab-bar components — no new visual language, a new arrangement plus state variants.

### Information architecture (a deliberate refactor)

The queue's arrival is the moment to remove a pre-existing overlap: Home's "Recent"
section was a slice of Library.

- **Download tab = the live queue.** The paste/extract hero stays pinned at top; beneath
  it, the transfer queue. The tab (and the iPad sidebar item) carries an **active-count
  badge**. This keeps "start a download" and "watch it download" on one surface.
- **Library tab = every completed video** — now the sole archive (the "Recent" section is
  **removed**).
- **Completed jobs auto-move to Library** with no manual step; at most a brief,
  self-dismissing "Saved to Library" toast. They do **not** linger in the queue.
- Only states needing a user decision persist in the queue: **failed**, **needs-sign-in**,
  **no-space** — until resolved or dismissed.
- The current single inline "Downloading" card is replaced by this queue.

### Queue list

One **flat list**, ordered **active → queued → attention** (no section headers). One row
per job: thumbnail, title, source·quality/size, and a state-specific body + actions.

### Row state catalog

| State | Body | Actions |
|-------|------|---------|
| Downloading | progress bar · `62% · 3.1 MB/s` | pause, cancel |
| Paused | frozen bar · `Paused · 48%` | resume, cancel |
| Queued | `◷ Queued · 1080p` | cancel |
| Waiting (background) | **indeterminate** bar · `Waiting to resume…` | cancel |
| Merging | `Merging video + audio…` | — (auto) |
| Refreshing (link expired) | `Refreshing link…` | — (auto-resumes) |
| Needs sign-in | `warn` notice · `Sign in to continue` | Sign in to `<host>` |
| Failed · network | `err` · `Couldn't finish — network` | Retry, dismiss |
| Failed · no space | `err` · `Not enough storage · needs X` | Manage storage, dismiss |

Maps 1:1 to the state machine: `.needsRefresh` renders as **Refreshing** (auto) or, when
re-extraction needs credentials, **Needs sign-in** (reuses the existing sign-in notice);
`.failed(reason)` splits into **network** vs **no-space**. **Waiting (background)** is shown
explicitly — a suspended, iOS-deferred 4K download must read as "fine, will resume," not
frozen/broken.

### Interaction

- Frequent controls — **pause/resume + cancel** — are inline icon buttons on the
  active/paused card.
- Terminal rows put their **primary recovery inline** (Retry / Sign in / Manage storage)
  and offer **swipe-to-dismiss** (or a context-menu "Remove") for `✕`.
- `Refreshing` and `Merging` are automatic and actionless — they resolve on their own.
- **Pause semantics** (platform reality): a background task can't truly pause mid-flight.
  "Pause" = for **chunked**, stop enqueueing after the current chunk (resumes cleanly from
  `bytesWritten`); for **single-shot**, cancel-with-`resumeData`. Cancelling mid-chunk
  wastes at most one chunk — bounded, not corruption.

### Deferred UI details

iPad split-view specifics beyond the badged sidebar item, the exact toast treatment, and
any changes to the quality-picker flow are not yet designed — revisit before the Phase-6 UI
build.

## Error handling

- Keep the existing `KeraunosError` mapping (`.cancelled`, `.downloadNetwork`). Add a
  durable per-job `.failed(reason)` state so failures survive relaunch and are retryable
  from the list. Reasons include: `network`, `insufficientSpace`, `refreshFailed`
  (re-extraction could not re-select the format), `integrityCheckFailed`.
- Network drop mid-chunk → task fails → job stays `.downloading` with intact
  `bytesWritten`; auto-resume on next launch / reachability, retry from offset.
- **Expiry / auth failure** (`403`/`410` or `urlExpiresAt` reached) → **`.needsRefresh`**,
  recovered by foreground re-extraction (see "Media-URL refresh"); only a failed refresh
  becomes `.failed(refreshFailed)`.
- Corruption guards from today (200-not-at-offset-0, zero-byte, HTTP non-2xx) port over,
  plus the pre-merge integrity check (`part length == totalBytes`).
- Merge failure → `.failed`; part files retained for retry until the user deletes.

The riskiest paths (relaunch ordering, discretionary scheduling, completion-handler
plumbing, wake throttling) cannot be hit by `swift test` or reliably in the simulator, so
coverage is **layered**, and the un-automatable layer is a **committed artifact**, not
folklore.

- **Core (simulator-free, `swift test`) — the bulk of the logic:**
  - `TransferJobStore` persistence / rehydration round-trips.
  - Chunk-offset math and the **truncate-to-`bytesWritten` reconcile**, including a
    *simulated crash*: append, drop the persist, re-init the store, assert reconcile.
  - Adaptive state-machine transitions (queued → downloading → readyToMerge → completed)
    and the pre-merge integrity check.
  - **Expiry parsing (`expire=`) and `.needsRefresh` transitions** with an **injectable
    clock** (no real time).
  - The sequential chunk engine driven against a **mock `TransferSession` that scripts
    adversarial orderings** — a completion for an unknown/not-yet-loaded job delivered
    *first* (the launch race), out-of-order deliveries, relaunch-with-missing-task,
    206 / 200 / short-chunk / failure.
- **App integration (simulator, localhost):** a real background `URLSession` against a
  localhost server serving Range requests (per the existing "never real sites" rule).
  Exercise reassociation by tearing down and recreating the session object and asserting
  `getAllTasks()` rebinds; a UI test that kills and relaunches the app process and asserts
  resume.
- **Manual device test plan (committed doc):** the OS behaviors nothing can fake — system
  termination of a suspended app, discretionary deferral, locked-device transfer,
  wake-rationed background throughput. Checklist: large download → background → lock →
  kill from app switcher → airplane-mode toggle mid-chunk → expired-URL refresh, asserting
  completion/resume each time. This is the safety net for the highest-risk code.
- **Chaos flag:** a debug switch in the driver injecting forced `403`/expiry, random task
  failure, and resume-data loss, so device runs can trigger recovery paths on demand.

## De-risk spikes (gate the build, like the roadmap's SABR spike)

Two unknowns can invalidate design choices; resolve them with throwaway device spikes
**before** committing the phases that depend on them:

- **S1 — Background chunk size.** Probe the largest Range googlevideo serves without
  re-triggering the throttle. Output: the background chunk size (and confirmation that
  large ranges don't behave like an unranged GET). Gates Phase 2's chunked driver and the
  scheduling parameters.
- **S2 — Background-launch merge & Photos.** Determine whether `AVAssetExportSession` and
  `PHPhotoLibrary.performChanges` run reliably during a URLSession background-launch
  window. Output: keep the "try immediately" merge branch, or always defer to foreground.
  Gates Phase 4.

## Implementation phasing

One spec; implementation lands in dependency order, each step independently testable:

1. **Job model + `TransferJobStore` + persistence** — including the crash-consistency
   (fsync → persist → truncate-reconcile) rule and orphan GC (pure Core, TDD).
2. **`TransferSession` seam + `TransferCoordinator`**: single-shot, then sequential
   chunked (with the S1 chunk size), then resume — against the scripted mock session.
3. **App-target background `URLSession` driver + session delegate + app-delegate relaunch
   glue** — with the **launch-ordering** (load store → wire delegate → create session) and
   **synchronous stage-out** guarantees, and the singleton owner. Keychain (`AfterFirstUnlock`)
   auth wiring lands here.
4. **Adaptive orchestration + pre-merge integrity check + merge-with-fallback** (shaped by
   S2), and disk-space guards.
5. **Media-URL refresh**: `expire=` parsing, `.needsRefresh` transitions, and the
   foreground re-extraction + resume-safety (`Content-Length` match) path.
6. **Downloads-list UI + progress reconnection** — states (`.needsRefresh`, waiting,
   `.failed(reason)`), pause semantics, per-row actions.
7. **Manual device test-plan doc + chaos flag.**
