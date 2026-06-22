# Plan: list all playable video downloads, not just .mp4

Date: 2026-06-22 (cycle 6) · Roadmap item: net-new correctness gap (found by cycle-6 scout).

## Problem

`DownloadStore.savedFiles()` filters the Documents dir by the literal extension `"mp4"`
(`DownloadStore.swift:16`). But the **progressive** download path saves
`media.suggestedFilename` verbatim (`MediaAssembler.swift:25`), whose extension comes from
yt-dlp's `prepare_filename` — and the first selector branch
`best[protocol^=http][muxable][aac]` (`keraunos_extract.py:33`) has **no ext constraint**.
So a muxable progressive stream in a non-mp4 container (e.g. `.mov`, or an extension-less
RedNote URL that resolves to non-mp4) is downloaded and saved, but **silently orphaned**:
it never appears in the Downloads list, so it can't be shared (`ShareLink`), previewed
(QuickLook), or deleted in-app — it just sits in Documents invisibly.

The adaptive path is unaffected (it forces `.mp4`, `MediaAssembler.swift:45`). The planned
libav `.mkv` path (coverage-roadmap phase 4) would make this strictly worse.

## Change (`DownloadStore.swift`)

Replace the literal filter with a small allow-set of playable/listable video extensions:

```swift
static let listedExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm"]
...
.filter { Self.listedExtensions.contains($0.pathExtension.lowercased()) }
```

Keep the existing `.lowercased()` normalization and the newest-first sort. The allow-set
naturally keeps non-video sidecar files (`failures.log`, `cookies.txt`) out of the list —
this exclusion is an invariant the tests must lock.

## Tests (TDD, write FIRST) — `DownloadStoreTests.swift`

Follow the existing test style (write marker files into a temp dir, then assert
`savedFiles()`):
- `listsNonMp4VideoExtensions`: write `a.mp4`, `b.mov`, `c.m4v`, `d.mkv`, `e.webm` → all 5
  returned. (FAILS before the change — only `a.mp4` is returned.)
- `excludesNonVideoSidecarFiles`: write `clip.mp4`, `failures.log`, `cookies.txt`,
  `notes.txt` → only `clip.mp4` returned (invariant: no sidecars leak into the list).
- `extensionMatchIsCaseInsensitive`: write `CLIP.MP4` / `clip.MOV` → returned.
- Preserve/confirm any existing newest-first ordering test still passes.

## Verify gate

Full build + Swift Testing suite on iPhone 17 simulator. KeraunosCore alone:
`cd app/KeraunosCore && swift test`. Recurring UI-runner flake:
`xcrun simctl shutdown all; killall Simulator; killall com.apple.CoreSimulator.CoreSimulatorService; sleep 12` then re-run.
