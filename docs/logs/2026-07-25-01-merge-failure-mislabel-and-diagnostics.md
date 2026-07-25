# 2026-07-25-01: Merge failures mislabeled as "File check failed" + self-sufficient merge diagnostics

**Status:** Implemented

## Context

A TestFlight tester (build 1.0(38), commit `598403e`) reported "file check failed"
when downloading a bilibili video, with a shared `keraunos-diagnostics.log`.

Two problems surfaced during investigation:

1. **Mislabeling.** `TransferFinalizer.finalize(_:)` set the job state to
   `.failed(.integrityCheckFailed)` in *two* places: the genuine integrity check
   (a part's byte length ≠ its recorded total) **and** the catch-all when the merge
   threw. `FailureReason` had no `mergeFailed` case, so a mux failure borrowed the
   integrity reason and rendered as *"File check failed — the downloaded data was
   incomplete."* The bytes were complete; the **merge** failed. Misleading.

2. **Un-diagnosable cause.** The log carried only `transfer_merge_failed … : mergeFailed`.
   `AVFoundationMerger` swallowed the underlying `NSError` and rethrew a bare
   `KeraunosError.mergeFailed`, and the finalizer line held only the job UUID — no
   codec, no source URL, no format. An unsupported-codec failure (needs ffmpeg) and a
   non-media body (an auth wall that passed the byte-length check) produced *identical*
   logs, so root-causing from the shared export was impossible.

(Investigation aside: the local clone was ~40 commits behind `origin/main`; the whole
`Transfer*` background-job subsystem that build 38 runs landed after the stale HEAD.
Always `git fetch` before debugging a shipped build.)

## Options

### Fixing the label

| Approach | Pros | Cons |
|----------|------|------|
| Keep `.integrityCheckFailed`, change only the copy | one-line | still conflates two distinct causes; retry semantics stay wrong |
| **New `FailureReason.mergeFailed` (chosen)** | honest state, distinct UI + recovery, Codable-safe (additive raw value) | touches the enum + exhaustive UI switch + a test |

### Capturing the "why"

| Approach | Pros | Cons |
|----------|------|------|
| Persist HTTP `Content-Type` into `TrackJob`, thread to finalizer | server's declared type | invasive: durable-schema change, delegate + factory + all init call sites; failure is discovered in Core, which has no HTTP response |
| **Sniff the file's leading bytes at merge-failure time (chosen)** | zero plumbing, ground truth, runs only on failure, also catches `webm`/`ogg` the codec probe can't classify | doesn't report the server's declared MIME type (bytes are more useful anyway) |

## Decision

Add `FailureReason.mergeFailed` and use it for mux failures; enrich the merge/integrity
diagnostics with source-page URL + format ID (redacted at write time) and, when a track
has no readable codec, a leading-byte body signature (`html`/`json`/`mp4`/`webm`/`ogg`/…).

## Rationale

The two failure classes need *different* fixes (codec handling vs auth/cookies), so they
must be distinguishable both to the user and in the log. The byte-sniff wins over HTTP
`Content-Type` because the failure is detected in Core at merge time (no response object
there), the on-disk bytes are ground truth, and it needs no durable-schema change. Logging
the **page** URL (never the signed media URL) plus format ID closes the "which video?" gap
without a new leak — `FailureLog`'s redactor scrubs secret query params on write.

## What Changed

- `KeraunosCore/TransferJob.swift` — new `FailureReason.mergeFailed`.
- `KeraunosCore/TransferFinalizer.swift` — merge failure → `.mergeFailed` (was
  `.integrityCheckFailed`); `sourceTag(_:)` adds `src=…page fmt=…` to the integrity and
  merge diagnostic lines.
- `KeraunosCore/AVFoundationMerger.swift` — `recordMergeFailure(phase:underlying:…)`
  records `merge_unsupported` with each track's codec FourCC + the real `NSError` at all
  three failure sites; `bodySignature(of:)` classifies a non-media body from its head.
- `KeraunosCore/AVFoundationMerger.swift` (follow-up, same day) — the input `.mp4` scratch
  entries are now **hard links** (`linkItem`), not symlinks; see the new discovery below.
- `Keraunos/Components/TransferQueueRow.swift` — honest `.mergeFailed` card ("Couldn't
  combine tracks … this format isn't supported. Try a different quality.").
- Tests — `TransferFinalizerTests` flipped to expect `.mergeFailed`; new
  `AVFoundationMergerTests.recordsBodySignatureWhenTrackIsNotMedia` asserts `video-body=html`.

## What Was Discovered

- The buggy behavior was pinned by an existing test asserting `.integrityCheckFailed` for
  a merge failure — flipping that assertion was the natural failing test.
- The team harness bans `try?`; the codec/body-sniff helpers use `do/catch` returning a
  marker (`unreadable`) instead — a diagnostic read must never become a failure.
- The no-decodable-track `guard` now falls into the same catch as other compose errors, so
  even "no track" gets a `merge_unsupported` line — and its `video=none` + `body=html`
  fingerprint is exactly the auth-wall signature.
- Remaining gap (follow-up): the `video=none`/`body=html` case names *what* but not *why*
  the body was an auth page — and codec-aware format selection (reject non-passthrough
  renditions before downloading) is the real step-2 fix, pending a fresh repro log.
- Doc drift: `CLAUDE.md` still describes `MediaAssembler`/`AVFoundationMerger` as the DASH
  path; the shipping app uses the `Transfer*` background-job subsystem. Needs refreshing.

### Follow-up (same day): the diagnostics immediately paid off — third failure class found

The very first device log carrying the new fields exposed a failure class we hadn't
anticipated, and one the enriched line was *essential* to spot:

```
merge_unsupported  compose: video=unreadable audio=unreadable video-body=mp4 audio-body=mp4:
  NSCocoaErrorDomain#257 The file "video.mp4" couldn't be opened because you don't have permission to view it.
```

- `body=mp4` (from the in-process `FileHandle` sniff) proved the bytes were **valid MP4** —
  so this was neither the codec case (`body=webm`) nor the auth-wall case (`body=html`).
  Only `AVURLAsset` failed, with `#257` = `NSFileReadNoPermissionError`. Without the
  body-signature field this was indistinguishable from an unsupported codec.
- Root cause: `AVFoundationMerger` handed `AVURLAsset` a **symlink** to the `.part` file.
  On a **real device** `loadTracks`/export parse media out-of-process (media-services
  daemon), which gets a sandbox extension only for the path passed in; the symlink resolves
  to the real file under Application Support, a path the daemon has no extension for →
  permission-denied. A **hard link** is another dir entry for the same inode, so the daemon
  opens the real bytes directly through the granted path. `tmp/` and Application Support
  share the container's one filesystem, so `linkItem` is valid.
- **The verification gap that let the symlink version ship:** it passed on the simulator,
  which doesn't enforce the sandbox-extension boundary, and `swift test` runs on
  macOS/simulator — so the whole suite is structurally blind to this. Fix was verified by
  a real bilibili adaptive download completing on a physical iPhone. Lesson:
  AVFoundation/merge changes are not verified until run on-device.
