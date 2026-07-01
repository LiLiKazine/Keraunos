# Resolution picker — design

**Date:** 2026-07-01
**Status:** Approved (brainstorm)
**Topic:** Let the user choose which resolution to download, per download.

## Goal

Today `keraunos_extract.py` always resolves a URL to the single **best** AVFoundation-muxable
stream (a hardcoded `_FORMAT` string). This adds a **per-download resolution picker**: after
pasting a link, the app lists the resolutions actually available for that video and lets the
user pick one before downloading.

Scope is the existing 7-site personal tool. The practical ceiling is **1080p** across all
sites (YouTube >1080p is SABR-gated and unreachable — see the coverage roadmap; do not
re-litigate). No global setting, no telemetry.

## UX

Flow changes from `paste → download` to `paste → resolve & list → pick → download`.

- After the user starts, the app resolves and lists distinct available resolutions.
- **2+ resolutions** → show a picker; the user taps one; it downloads.
- **0–1 resolution** (single stream, or direct-file links whose formats yt-dlp can't probe
  under `skip_download`, e.g. Twitter/X, RedNote) → **skip the picker, download directly** —
  no added friction and no extra network round-trip vs. today.
- Each picker row reads: **`1080p · H.264 · ~45 MB`**. Size and codec are shown when yt-dlp
  reports them and omitted when it doesn't.

## Approach

**Two extractions (Approach A).** Phase 1 lists formats; phase 2 re-resolves the chosen one
by reusing the existing selector. The phase-2 extraction is the *warm* path (yt-dlp caches
the YouTube player/nsig/PoT), so it is cheap. This maximizes reuse of the battle-tested
video↔audio pairing and codec-muxability logic and keeps the phase-1 payload small.

Rejected alternatives:
- **One extraction, select client-side (B):** saves a round-trip but forces replicating
  yt-dlp's per-resolution pairing in Python, a much larger payload, and force-deciphering
  *every* YouTube URL upfront. More logic, more fragile.
- **Global quality preference (C):** ruled out — the user wants per-download control.

## Data model (`KeraunosCore`)

```swift
public struct FormatOption: Equatable, Sendable {
    public let height: Int          // 1080, 720, …
    public let codecLabel: String   // "H.264" / "HEVC"
    public let approxBytes: Int64?  // nil when yt-dlp reports no size
    public let formatID: String     // yt-dlp id, used to re-select in phase 2
    public let isAdaptive: Bool     // video-only (needs +bestaudio) vs progressive

    /// Pure, unit-tested display string, e.g. "1080p · H.264 · ~45 MB".
    /// Size and codec segments are dropped when unavailable.
    public var displayLabel: String { … }
}

public enum FormatListing: Sendable {
    case ready(ResolvedMedia)       // 0–1 real choice → download now, no picker
    case choices([FormatOption])    // 2+ distinct heights → show picker
}
```

## Python (`keraunos_extract.py`)

Two entry points; all existing codec/error/timeout logic is preserved.

- **`list_formats(url, socket_timeout, cookiefile, overall_timeout)`** — runs `extract_info`
  **once** with the current default `_FORMAT`, then:
  1. builds today's default success payload (the `.ready` `ResolvedMedia`);
  2. scans `info["formats"]` for distinct **muxable** heights — http + AVFoundation-muxable
     vcodec (`avc*`/`h264`/`hvc*`/`hev*`/`h265`), pairable with AAC audio. One entry per
     distinct height, keeping the best muxable codec at that height, recording its
     `format_id`, codec label, `isAdaptive`, and approx size (video `filesize`/
     `filesize_approx` + best-audio size for adaptive).

  Returns `{"ok":true,"kind":"choices","options":[…]}` when it finds **≥2** heights;
  otherwise `{"ok":true,"kind":"ready", …}` (byte-for-byte today's payload). Runs under the
  same watchdog and returns error payloads via the same mapping as `extract`.

- **`extract(url, …, format_id=None, adaptive=None)`** — today's function, extended: when a
  `format_id` is passed it builds the selector from it —
  - progressive: `"{id}/{_FORMAT}"`
  - adaptive: `"{id}+bestaudio[protocol^=http][{_ACODEC_AAC}]/{id}+bestaudio/{_FORMAT}"`

  The trailing `_FORMAT` is a graceful fallback if a stale/invalid id fails (a resolution
  mismatch is acceptable; a failed download is not). With no `format_id`, behavior is
  unchanged.

## Bridge (`PythonBridge.h` / `.m`)

- Add `char *keraunos_python_list_formats(const char *url, const char *cookieFilePath);`
  mirroring `keraunos_python_extract` (same GIL/watchdog machinery, calls
  `keraunos_extract.list_formats`).
- Add an optional `format_id` kwarg to `keraunos_python_extract` (passed through to
  `extract` when non-empty; absent → unchanged).

## Swift extractor (`MediaExtracting`)

```swift
public protocol MediaExtracting: Sendable {
    func listFormats(_ url: URL) async throws -> FormatListing
    func resolve(_ url: URL, option: FormatOption) async throws -> ResolvedMedia
}
```

- `PythonExtractor` implements both, each wrapped in the existing `withTimeout` +
  serial-executor machinery. `listFormats` calls `keraunos_python_list_formats`;
  `resolve(_:option:)` calls `keraunos_python_extract` with `option.formatID`.
- `MockExtractor` gains a configurable `listing` (and keeps a resolve result) so previews
  and tests drive both the `.ready` and `.choices` paths.
- Decoding of the `list_formats` JSON into `FormatListing` lives in `ExtractionDecoder`
  (alongside the existing `ResolvedMedia` decode), mapping failure payloads to
  `KeraunosError` identically.

## View model (`DownloadViewModel`)

- Extract the resolve→assemble→save body **and** its entire `do/catch` error-mapping block
  into one private helper `runDownload(url:, resolve:)`. Both entry paths reuse it, so
  auto-retry, failure logging, and Sign-In routing stay identical and centralized.
- `startDownload` → `extractor.listFormats(url)`:
  - `.ready(media)` → `runDownload` immediately (today's behavior).
  - `.choices(options)` → stash `pendingURL`/`pendingOptions`, stop the spinner; the UI
    shows the picker. `listFormats` errors flow through the same catch as `resolve`.
- `func selectFormat(_ option:)` → clear pending, then
  `runDownload(url: pendingURL) { try await extractor.resolve(pendingURL, option: option) }`.
- `func cancelSelection()` → clear pending (user dismissed the picker).
- New observable state: `private(set) var pendingOptions: [FormatOption]?`
  (non-nil = picker showing).

## UI (`DownloadScreen`)

A `.confirmationDialog` bound to `pendingOptions != nil`: one button per option titled
`option.displayLabel`, plus Cancel (→ `cancelSelection`). No new view file; native action
sheet.

## Testing (TDD)

Pure units first, then wiring; integration against **localhost fixtures only**.

- **Pure:** `FormatOption.displayLabel` (size present/absent, HEVC vs H.264); `ExtractionDecoder`
  → `FormatListing` (`.ready` vs `.choices`; malformed → `KeraunosError`).
- **`DownloadViewModel` (MockExtractor):** `.ready` downloads with no picker; `.choices`
  populates `pendingOptions` and does **not** download until `selectFormat`; `selectFormat`
  resolves + saves; `cancelSelection` clears state; a `listFormats` error maps exactly like a
  `resolve` error (proves the shared helper).
- **Python `list_formats`:** height grouping + muxability + `.ready`/`.choices` threshold
  against localhost fixtures, consistent with existing `keraunos_extract` tests.

## Out of scope (YAGNI)

Audio-only rows; codec-preference toggle; remembering the last choice; anything >1080p
(SABR-gated).
