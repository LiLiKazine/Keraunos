# 2026-08-09-01: Align the code with the domain glossary

**Status:** Implemented

## Commits

| Commit | Description |
| --- | --- |
| `4c773c1` | Record the glossary as `CONTEXT.md` and open the alignment arc |
| `69fa677` | Delete the legacy `Downloader`/`MediaAssembler` path |
| `406cc60` | Rename `DownloadStore` to `LibraryStore` |
| (this) | Rename `adaptive` to DASH in Swift, freezing the persisted keys |

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
- **Deleted** `Downloader.swift` (`FileDownloading`, `Downloader`, `DownloadProgressDelegate`)
  and `MediaAssembler.swift`, plus `DownloaderTests`, `DownloadProgressDelegateTests`,
  `MediaAssemblerTests`, `StubNetworkSuite` and `StubURLProtocol`.
- **Renamed** `DownloadStore` → `LibraryStore` (and its tests), and the `downloadStore`
  parameter/property → `libraryStore` in `TransferFinalizer` and `TransferEngine`.
- **Renamed** `FormatOption.isAdaptive` → `isDASH`, `FormatSelection.isAdaptive` → `isDASH`,
  `TransferJob.Kind.adaptive` → `.dash`, and `ResolvedMedia.Kind.adaptive` → `.dash`, with
  `CodingKeys` on the two persisted types pinning the old wire names.
- Added two wire-format guards in `TransferJobTests`: one decoding a literal legacy payload,
  one asserting today's encoder still emits `"adaptive"` / `"isAdaptive"`.
- Corrected the stale CLAUDE.md chunking gotcha and the architecture blurb.

## Verification

- Core package: 239 tests across 25 suites pass (was 256/29 — 19 tests went with the deleted
  legacy path, 2 wire-format guards added).
- Full app scheme passes on the iPhone 17 simulator.

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
- **A blanket `sed` on the rename is actively dangerous, and it bit once.** Replacing
  `isAdaptive` everywhere rewrote the `CodingKeys` raw value to `case isDASH = "isDASH"` —
  silently undoing the wire freeze the same commit existed to guarantee. Caught only because
  the encoded key was re-checked afterwards. macOS `sed` also has no `\b`, so the paired
  `.adaptive` → `.dash` pass matched nothing and looked like it had succeeded.
- **Three separate meanings of "adaptive" live in this codebase** and only one of them was
  ours to rename:
  - `GridItem(.adaptive(minimum:))` in `LibraryScreen` — SwiftUI layout, unrelated
  - `"adaptive"` as the extraction wire value from Python (`ResolvedMedia`, and the
    `adaptive: Bool` payload field) — an external contract
  - `AppShell`'s "adaptive shell" doc comment — UI layout again

  A whole-word replace across the repo would have corrupted all three.
- The wire format was confirmed empirically rather than assumed, by dumping a real encoded
  job before touching anything: `formatSelection.isAdaptive` is a bool and `kind.adaptive` is
  the enum discriminator, exactly the two keys the `CodingKeys` now pin.
- The pre-existing Codable tests could not have caught a wire break — they encode and decode
  with the same build, so both sides move together. That gap is why the two literal-payload
  guards were added.

## Residual scope

- `FormatSelection` still carries `formatID`/`height`/`isDASH` whose only live readers are a
  quality label and one diagnostic string, despite documenting itself as the Refresh re-pick
  record. Deciding whether it earns its place is a design question, deliberately not folded
  into a rename commit.
