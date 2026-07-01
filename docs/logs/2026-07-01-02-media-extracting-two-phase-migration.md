# 2026-07-01-02: MediaExtracting two-phase migration (listFormats + resolve:option)

**Status:** Implemented

## Context

The resolution picker feature needs to list available formats for a URL before
committing to a download. The existing `MediaExtracting` protocol only exposed a
single `resolve(_ url:)` that always resolved to the "default best" media. Task 5
(per `docs/superpowers/specs/` and `.superpowers/sdd/task-5-brief.md`) split this
into two phases — `listFormats` (returns either a ready-to-download result or a
list of `FormatOption` choices) and `resolve(_:option:)` (re-resolves a specific
chosen format, `nil` meaning default-best) — and migrated all conformers
(`MockExtractor`, `PythonExtractor`) and test doubles (`SequenceExtractor`,
`HangingExtractor`) accordingly. This task deliberately keeps `DownloadViewModel`
on the old single-call behavior (`resolve(url, option: nil)`) as an interim step;
the picker UI flow itself is Task 6.

## Options

The brief specified the exact code for every file verbatim, so there was no
design choice to make for the protocol shape itself. The one open question was
how `HangingExtractor` (a test double simulating an in-flight, cancellable
extraction) should signal "I have started work" now that there are two possible
entry points.

| Approach | Pros | Cons |
|----------|------|------|
| Yield only in `listFormats` (brief's literal text) | Matches brief verbatim | Breaks `cancelStopsInFlightDownloadWithoutSurfacingAnError`: `DownloadViewModel.startDownload` calls `resolve(_:option:)` directly in this interim task, so the signal never fires and the test hangs forever |
| Yield only in `resolve` | Test passes today | Silently wrong once Task 6 rewires `DownloadViewModel` to call `listFormats` first — the double would then stop signalling entry and every user of it would hang again |
| Yield in both `listFormats` and `resolve` (chosen) | Test passes today; stays correct after Task 6 switches the call site to `listFormats` | None found |

## Decision

`HangingExtractor` calls `entered.yield(())` at the top of **both**
`listFormats` and `resolve(_:option:)`, so "entered phase 1 or phase 2" reliably
signals regardless of which method the caller currently exercises.

## Rationale

The double's contract (per its doc comment) is "signal when it has actually
entered so a test can cancel a genuinely in-flight download" — it does not
promise which method was entered, only that *some* extraction call is now
in-flight. Yielding in both methods honors that contract independent of which
phase `DownloadViewModel` calls, decoupling the test double's correctness from
the interim/final wiring split across Task 5 and Task 6.

## What Changed

- `app/KeraunosCore/Sources/KeraunosCore/MediaExtracting.swift`: protocol gains
  `listFormats(_:)` and `resolve(_:option:)`; `MockExtractor` gains `listing`
  override (nil derives `.ready` from `result`).
- `app/KeraunosCore/Tests/KeraunosCoreTests/MockExtractorTests.swift` (new):
  3 tests covering the derived-ready default, the explicit `.choices` override,
  and `resolve(_:option:)`.
- `app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`: added
  `listFormats` (calls `keraunos_python_list_formats` +
  `ExtractionDecoder.decodeListing`); `resolve` now takes `option:` and calls
  the 4-arg `keraunos_python_extract` bridge function.
- `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`: interim one-line change,
  `extractor.resolve(url)` → `extractor.resolve(url, option: nil)`.
- `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`: `SequenceExtractor`
  and `HangingExtractor` migrated to the two-phase protocol.

## What Was Discovered

- The brief's `HangingExtractor` code (yield only in `listFormats`) does not
  compile-fail — it hangs at runtime. `xcodebuild test` sat for 12+ minutes with
  the test process barely consuming CPU (confirmed via `sample`) before it was
  identified as `cancelStopsInFlightDownloadWithoutSurfacingAnError` waiting on
  an `AsyncStream` continuation that only `listFormats` fired, while
  `DownloadViewModel.startDownload` (in this interim task) calls `resolve`
  directly. First attempt used the brief's code verbatim and hung twice
  (reproduced identically after a clean simulator shutdown/retry), which ruled
  out simulator flakiness and confirmed a real logic bug rather than
  environment noise.
- `-parallel-testing-enabled NO` was used for the diagnostic re-run to get a
  single, easy-to-sample test process instead of 4 parallel simulator clones;
  not required for correctness, just for debugging the hang.
- Confirms the general lesson (see `superpowers:systematic-debugging`): a test
  double's synchronization primitive must be audited against every call path
  that can reach it, not just the one path the brief's author had in mind when
  writing the double.
