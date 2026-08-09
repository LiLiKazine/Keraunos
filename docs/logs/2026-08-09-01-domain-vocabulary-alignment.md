# 2026-08-09-01: Align the code with the domain glossary

**Status:** Implemented

## Commits

| Commit | Description |
| --- | --- |
| (this) | Record the glossary as `CONTEXT.md` and open the alignment arc |

## Context

The codebase ran two parallel vocabularies for overlapping concepts, with no written
glossary to arbitrate between them:

- `Transfer*` — `TransferJob`, `TransferCoordinator`, `TransferEngine`, `TransferJobStore`,
  `TransferFinalizer`, `TransferProgress`, `TransferSession`, `TransferRowState`,
  `TransferStagingStore`
- `Download*` — `DownloadViewModel`, `DownloadsViewModel`, `DownloadStore`, `Downloader`,
  `DownloadProgressDelegate`, `DownloadTile`

They overlapped rather than partitioned: `DownloadsViewModel` renders `TransferRowState`,
and `TransferJob` carries `sourcePageURL` / `autoSaveToPhotos` / `suggestedFilename` — the
user's *request*, not merely its execution.

A second, narrower conflict: video+audio-as-separate-streams is called `adaptive` in code
(`TransferJob.Kind.adaptive`, `FormatSelection.isAdaptive`, `FormatOption.isAdaptive`) and
**DASH** in CLAUDE.md prose. Two names, one concept.

## Options

| Approach | Pros | Cons |
| --- | --- | --- |
| Leave both vocabularies | Zero churn | The ambiguity keeps generating inconsistent names in new code; no basis for review |
| Collapse everything to `Download` | Matches product language most directly | Largest rename; Core loses a useful word for the durable execution layer |
| Collapse everything to `Transfer` | One word, Core-consistent | "Transfer" is not what a user calls it; UI copy would diverge from the domain anyway |
| **Download = request, Transfer = execution (chosen)** | Keeps both words with a real boundary — Download crosses to the user, Transfer never does | Requires renaming the `Download*` types that sit on the machinery side |

For the second conflict:

| Approach | Pros | Cons |
| --- | --- | --- |
| Keep `adaptive` | Matches the code as written; zero renames | Contradicts CLAUDE.md and the wider yt-dlp ecosystem |
| **`DASH` (chosen)** | Matches the docs and the ecosystem; already the word used in prose | Renames three API surfaces, two of them persisted |

## Decision

**Download** names what the user asks for and receives; **Transfer** names the durable
background execution of it. **DASH** names a Format whose video and audio arrive as separate
streams. Recorded in `CONTEXT.md` at the repo root.

## Rationale

The Download/Transfer boundary was chosen because it is the only option that keeps a
distinct word for the durable execution layer while matching what a user actually says.
The test is mechanical and reviewable: if the concept crosses to the user, it is a Download;
if it never does, it is a Transfer.

DASH was chosen over `adaptive` because CLAUDE.md already used it, so the choice aligns the
glossary with existing documentation and leaves only the code out of step — a smaller and
more mechanical gap than re-writing the docs.

## What Changed

- Added `CONTEXT.md` at the repo root — 18 terms in four clusters (what the user asks for /
  choosing what to fetch / carrying it out / access), each with an `_Avoid_` list.

## What Was Discovered

- **`Downloader`, `DownloadProgressDelegate`, `FileDownloading` and `MediaAssembler` have
  zero production references.** The `Download*`-on-machinery half of the conflict resolves by
  deleting code rather than renaming it.
- **CLAUDE.md's YouTube-chunking gotcha was stale.** It credited `Downloader.downloadChunked`
  with the live ranged-chunk behavior, but nothing constructs a `Downloader`;
  `TransferCoordinator` re-implemented chunking against `TrackJob.chunkSize`, and its own doc
  comment says it ported the guards "from the old `Downloader.downloadChunked`".
- **`TransferJob` persists through a bare `JSONEncoder`/`JSONDecoder` with no `CodingKeys`.**
  Renaming `FormatSelection.isAdaptive` or `Kind.adaptive` therefore changes the on-disk
  format and would break in-flight jobs across an upgrade — the exact durable queue the
  previous branch worked to make crash-safe. The rename must freeze the wire keys.
- **`FormatSelection` may not be earning its documented weight.** Its doc comment says it
  exists to re-pick the same Format on a Refresh, but no production code reads it for that:
  `.isAdaptive` and `.height` are read only by `DownloadsViewModel.qualityLabel`, and
  `.formatID` only by a diagnostic string in `TransferFinalizer`. Left alone deliberately —
  that is a design question, not a rename. Needs follow-up.
- The user-facing `"Adaptive"` quality label (`DownloadsViewModel.swift:100`) is deliberately
  **not** renamed to "DASH". The glossary governs domain language; "DASH" would be worse copy
  for an end user in a slot that otherwise reads "1080p".
