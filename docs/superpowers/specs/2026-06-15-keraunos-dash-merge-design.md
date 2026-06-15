# Keraunos — Native DASH Merge (Milestone 2) Design

**Status:** Designed (awaiting review)
**Date:** 2026-06-15
**Builds on:** `2026-06-15-keraunos-ytdlp-architecture-design.md` (Milestone 1, progressive-only)

## Goal

Add the **merging capability**: produce a single, playable MP4 from a source whose
video and audio are delivered as **separate adaptive (DASH) streams**. Milestone 1
handles only *progressive* sources (one already-muxed file); this milestone unlocks
the large class of "needs format-merging" sources — including YouTube on a
best-effort basis.

## Scope

**In scope**
- Resolve a URL to either a progressive file **or** a video-only + audio-only pair.
- Download both tracks (sending yt-dlp's per-format HTTP headers) and **mux** them
  into one MP4 **natively**, using `AVFoundation` (no ffmpeg, no extra binary).
- Restrict adaptive selection to **AVFoundation-muxable codecs**: HEVC (`hvc1`/`hev1`)
  preferred, H.264 (`avc1`) fallback, AAC (`mp4a`) audio.
- Surface clear errors for everything we can't do (HLS, non-muxable codecs, auth).

**Out of scope (deferred)**
- **HLS** (segmented playlists) — poor fit for native muxing; needs the ffmpeg backend.
- **ffmpeg backend** — designed for as a later drop-in (a second `MediaMerging`
  implementation), not built now.
- **Non-muxable codecs** (VP9/AV1 video, Opus audio) — fail cleanly as `.needsFfmpeg`.
- Format/quality picker, download queue/history, audio-only, cookies/auth, Share
  Sheet, background downloads, percent-progress, parallel track downloads.
- **YouTube-specific anti-bot** (PO tokens / JS player). We propagate HTTP headers
  (cheap, helps many sites) but do **not** chase YouTube's shifting defenses;
  YouTube is best-effort, not an acceptance gate.

## Key constraint (unchanged from M1)

Embedded CPython on iOS has **no `subprocess`/`fork`**, so ffmpeg cannot be
shell-invoked. Merging must be done **natively in Swift** (AVFoundation) or, later,
via an ffmpeg **library** called through its C API. This milestone takes the native
path.

## Approach (chosen)

**Typed `ResolvedMedia` enum + a `MediaAssembler` orchestrator**, with muxing behind
a `MediaMerging` protocol.

Rejected alternatives:
- *Flat `ResolvedMedia` with optional `audioTrack`* — smaller diff, but "must merge"
  isn't compiler-enforced and orchestration leaks into the view model.
- *`Downloader` absorbs merging* — conflates byte-transfer with muxing; both become
  harder to test and to swap for ffmpeg.

The chosen shape keeps **transfer**, **muxing**, and **orchestration** as separate,
swappable, independently testable units — which is exactly what makes the ffmpeg
drop-in clean later.

## Domain model (`KeraunosCore`)

Replaces M1's flat `ResolvedMedia`:

```swift
public struct MediaTrack: Equatable, Sendable {
    public let url: URL
    public let httpHeaders: [String: String]   // yt-dlp's per-format headers (User-Agent, etc.)
    public let codec: String                    // "hvc1…", "avc1…", "mp4a…"
    public let fileExtension: String            // "mp4", "m4a"
}

public struct ResolvedMedia: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case progressive(MediaTrack)                        // already muxed → just download
        case adaptive(video: MediaTrack, audio: MediaTrack) // download both → mux
    }
    public let kind: Kind
    public let title: String
    public let suggestedFilename: String
}
```

The progressive/adaptive distinction is compiler-enforced; `title`/`suggestedFilename`
are shared metadata.

## Extraction contract (Python → Swift)

`keraunos_extract.py` runs yt-dlp with `skip_download` and a codec-restricted format
selector, returning one of:

```jsonc
// progressive (already muxed)
{"ok":true,"kind":"progressive","title":"…","filename":"clip.mp4",
 "media":{"url":"…","headers":{…},"vcodec":"avc1…","acodec":"mp4a…","ext":"mp4"}}

// adaptive (separate video + audio, guaranteed AVFoundation-muxable)
{"ok":true,"kind":"adaptive","title":"…","filename":"clip.mp4",
 "video":{"url":"…","headers":{…},"vcodec":"hvc1…","ext":"mp4"},
 "audio":{"url":"…","headers":{…},"acodec":"mp4a…","ext":"m4a"}}

// failure (unchanged shape)
{"ok":false,"error_kind":"needs_ffmpeg|unsupported|requires_auth|network|runtime","detail":"…"}
```

**Format selection logic:**
1. Prefer a progressive muxed file (http protocol, has both video and audio,
   muxable codecs) → `progressive`.
2. Else best **video-only** preferring `hev1/hvc1`, falling back to `avc1`, **+**
   best **audio-only** `mp4a` → `adaptive`. The two chosen formats come from
   yt-dlp's `requested_formats`; each carries its `url` and `http_headers`.
3. The selector only matches AVFoundation-muxable codecs (H.264/HEVC + AAC). If
   nothing muxable exists (only VP9/AV1/Opus), yt-dlp cannot satisfy the selector
   → mapped to `.needsFfmpeg`.

Per-format `http_headers` are always included so the native downloader can replay
the request context yt-dlp used (fixes many CDN rejections; necessary—though not
always sufficient—for YouTube's `googlevideo` URLs).

## Components

### `KeraunosCore` (nonisolated default, `public` API)

| Component | Responsibility |
|-----------|----------------|
| `MediaTrack`, `ResolvedMedia` | the model above |
| `ExtractionDecoder` | decode the new JSON → `ResolvedMedia`; map failures → `KeraunosError` |
| `FileDownloading` / `Downloader` | `download(_ track: MediaTrack, to dir: URL) async throws -> URL`; sends `track.httpHeaders` on the request |
| `MediaMerging` / `AVFoundationMerger` | `merge(video: URL, audio: URL, into: URL) async throws`; mux via `AVMutableComposition` + `AVAssetExportSession` passthrough |
| `MediaAssembler` | orchestrator: `assemble(_ media: ResolvedMedia, into store: DownloadStore, onPhase:) async throws -> URL` |
| `DownloadStore` | unchanged (Documents destination + listing) |
| `KeraunosError` | + `.mergeFailed` case |

`MediaAssembler` depends only on the `FileDownloading` and `MediaMerging` protocols
plus `DownloadStore` — fully unit-testable with mocks. The **ffmpeg drop-in later =
a second `MediaMerging` implementation**, with no change to the assembler, model, or UI.

`AVFoundationMerger` lives in `KeraunosCore` (AVFoundation is available on iOS and
macOS). It loads each file as an `AVURLAsset`, builds an `AVMutableComposition` with
one video track (from the video file) and one audio track (from the audio file), and
exports with `AVAssetExportPresetPassthrough` to `.mp4` — a container remux only, no
transcoding. Passthrough fails cleanly on a codec it can't carry, which is the safety
net behind the codec-restricted selector (→ `.mergeFailed`).

### App target (main-actor)

- `PythonExtractor` — same `MediaExtracting` interface; only the bridge/Python JSON
  is richer. No Swift signature change.
- `DownloadViewModel` — calls `MediaAssembler` (not `Downloader` directly); exposes a
  `phase` (`.resolving / .downloadingVideo / .downloadingAudio / .merging`).
- `DownloadScreen` — shows the phase label instead of a bare spinner.

## Data flow

**Progressive** (M1 behavior preserved):
```
URL → PythonExtractor.resolve → ResolvedMedia(.progressive(track))
    → MediaAssembler.assemble → Downloader.download(track, to: Documents)  // track.httpHeaders
    → final .mp4 in Documents → DownloadStore.savedFiles → UI list
```

**Adaptive** (new):
```
URL → PythonExtractor.resolve → ResolvedMedia(.adaptive(video, audio))
    → MediaAssembler.assemble:
        phase=.downloadingVideo → Downloader.download(video, to: tmp)   // video.httpHeaders
        phase=.downloadingAudio → Downloader.download(audio, to: tmp)   // audio.httpHeaders
        phase=.merging          → AVFoundationMerger.merge(video, audio,
                                      into: Documents/<suggestedFilename>.mp4)
        defer: delete both tmp files (success OR failure)
    → final .mp4 in Documents → savedFiles → UI list
```

Details:
- Intermediate tracks download into `FileManager.temporaryDirectory/<uuid>/`; only
  the merged result lands in Documents, so the user never sees the silent
  video-only / audio-only files.
- Downloads are **sequential** (video then audio) for simplicity and bounded memory;
  parallelizing is a trivial later change confined to the assembler.
- The adaptive output filename is forced to `.mp4` (the merged container).
- Phase reporting is via an `onPhase` callback; the view model maps phases → label
  ("Downloading video… / Downloading audio… / Combining…"). No percent-progress.

## Error handling

All failures surface as `KeraunosError` with a clear message; never a crash.

| Situation | Where | Case | Message |
|-----------|-------|------|---------|
| Only non-muxable codecs (VP9/AV1/Opus) | Python selection | `.needsFfmpeg` | "This video needs full codec support, coming in a later version." |
| HLS-only | Python | `.needsFfmpeg` | (HLS still deferred) |
| Auth / sensitive | Python | `.requiresAuth` | existing M1 message |
| A track download fails (incl. YouTube `googlevideo` rejection) | Downloader | `.network` | "Download failed — check your connection." |
| Mux fails (incompatible track slips through passthrough) | `AVFoundationMerger` | `.mergeFailed` (new) | "Couldn't combine the video and audio tracks." |

- The assembler `defer`s deletion of both temp tracks on every exit path — a
  failed/cancelled adaptive download never leaks files.
- On partial download (audio fails after video succeeds), the whole `assemble`
  throws and temps are cleaned; Documents only ever receives the final merged MP4.

## Testing

- **`KeraunosCore` unit (`swift test`, no Python/sim):**
  - `ExtractionDecoder`: progressive, adaptive (two tracks + headers), `.needsFfmpeg`
    payload, malformed.
  - `Downloader`: asserts `httpHeaders` are sent (`StubURLProtocol`); saves the track.
  - `MediaAssembler`: progressive (merger **not** called); adaptive (both tracks via
    stub, `MockMerger` receives the two temp URLs, final file in Documents);
    merge-failure and download-failure paths assert temp cleanup. `MockMerger`
    records inputs and can be told to fail.
- **`AVFoundationMerger`:** focused integration test muxing two tiny bundled fixtures
  (a few-frame silent `.mp4` + a short `.m4a`) → output is a valid asset with both a
  video and an audio track. Drops to manual/app verification if fixture muxing is
  flaky in CI.
- **Python dev (`pytest`):** format-selection/JSON-building helpers in isolation
  (progressive vs adaptive vs non-muxable → correct `kind`/`error_kind`) + a
  localhost progressive case as in M1.
- **App (`xcodebuild test`):** view-model tests for progressive success, adaptive
  success, `.mergeFailed`, and `.needsFfmpeg` messaging, using mocks.
- **Manual acceptance:** a real DASH source → single playable MP4 in Files (with
  audio); YouTube best-effort; an HLS/exotic-codec link → clean `.needsFfmpeg`.

## Done criteria

1. A DASH source (separate video + audio, muxable codecs) downloads as a **single
   playable MP4 with audio**, visible in the Files app.
2. Progressive sources (X, etc.) still work exactly as in M1.
3. Per-format HTTP headers are sent on track downloads.
4. Non-muxable / HLS / auth sources fail with the correct clear `KeraunosError`.
5. No temp-file leakage on success or failure.
6. All test tiers green: `KeraunosCore` `swift test`, Python `pytest`, app
   `xcodebuild test`.

## Future drop-in (not this milestone)

An `FFmpegMerger: MediaMerging` (libav\* via C API, no subprocess) replaces the codec
restriction: full coverage of VP9/AV1/Opus and HLS remux. The selector relaxes, the
`.needsFfmpeg` cases shrink, and nothing else changes — the assembler, model, and UI
are untouched.
