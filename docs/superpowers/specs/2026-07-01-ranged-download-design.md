# Ranged/chunked downloads for YouTube adaptive DASH — design

**Date:** 2026-07-01
**Status:** Approved (brainstorm). Supersedes the draft
`2026-07-01-ranged-download-youtube-dash-draft.md`.
**Topic:** Download YouTube (googlevideo) streams in ranged chunks so they don't stall.

## Problem & root cause (code-confirmed)

Downloading a YouTube adaptive stream (e.g. itag 160, `ANDROID_VR`, from `googlevideo.com`)
times out with `NSURLErrorTimedOut` (`-1001`). Reproduced on-device on two different
YouTube videos; non-YouTube sites (X) download fine.

googlevideo throttles a single unranged full-file GET to a trickle, so `URLSession` receives
no bytes for the 60 s request timeout and fails. yt-dlp avoids this by downloading in **HTTP
Range chunks**: YouTube tags its https formats with
`fmt['downloader_options'] = {'http_chunk_size': CHUNK_SIZE}` (`youtube/_video.py:3605`,
`CHUNK_SIZE = 10 << 20` = 10 MiB) and its downloader honors that with ranged requests
(`downloader/http.py:47`).

Keraunos's `Downloader` (`Downloader.swift:25`) does one unranged `URLSession.download` per
track and `_track()` drops `downloader_options` entirely — so the chunk hint never reaches
Swift and googlevideo stalls the transfer.

## Scope

**Chunk only when hinted.** A track is chunked only when its format carries
`http_chunk_size` (i.e. YouTube). Every other supported site (Twitter/X, Reddit, Bilibili,
RedNote, Instagram) carries no hint and stays on the current single-shot path that already
works — smallest blast radius, fixes exactly what is broken.

## Component 1 — wire the chunk hint end-to-end

- **`keraunos_extract.py::_track`** adds `"chunk_size": fmt.get("downloader_options", {}).get("http_chunk_size")`
  — an int for YouTube formats, `null` otherwise. Applies to progressive, video, and audio
  tracks (adaptive YouTube video+audio both carry it).
- **`ResolvedMedia.swift`**: `TrackPayload` decodes `chunk_size`; `ExtractionDecoder.track(...)`
  passes it into `MediaTrack`.
- **`MediaTrack`** gains `public let chunkSize: Int?`, with a defaulted `chunkSize: Int? = nil`
  in `init` — additive, so existing construction sites (`MockExtractor`, tests) are unaffected.

`nil`/absent/≤0 ⇒ downloads exactly as today; a positive value ⇒ chunked.

## Component 2 — chunked `Downloader`

`Downloader.download(_:to:onProgress:)` branches:

```
if let chunk = track.chunkSize, chunk > 0 { try await downloadChunked(track, chunk, to:, onProgress:) }
else { <existing single-shot path — byte-for-byte unchanged> }
```

`downloadChunked` (writes to a temp file, then moves into place — same atomic pattern):

1. `offset = 0`, `total: Int64? = nil`; open a `FileHandle` on a temp file.
2. Loop:
   - Build a request with `track.httpHeaders` **plus** `Range: bytes=<offset>-<offset+chunk-1>`.
   - Fetch with `session.data(for:)` (≤ chunk bytes, ~10 MB, in memory at a time).
   - **206 Partial Content** → parse `Content-Range: bytes a-b/total` for `total`; append body;
     `offset += body.count`; report `offset/total`; stop when `offset >= total` (or the body is
     empty — defensive against infinite loops).
   - **200 OK** (server ignored `Range`) → the body is the whole file; append and stop.
   - **anything else** → `throw KeraunosError.downloadNetwork`.
   - `try Task.checkCancellation()` each iteration.
3. Keep the existing **>0-byte dud guard**; move temp → destination.

Ranged requests aren't throttled by googlevideo, so each chunk completes well within the 60 s
per-request timeout. Per-chunk progress uses the same `onProgress` closure.

## Error handling

A failing chunk fails the whole download → `.downloadNetwork` (retryable, as today). No
per-chunk resume (YAGNI). Cancellation maps to `.cancelled` via the existing catch. The
single-shot path is untouched, so its behavior and error mapping are unchanged.

## Testing (TDD, localhost only)

Extend `DownloaderTests` with a stateful `StubURLProtocol` handler serving a known N-byte body
that honors the `Range` header (206 + `Content-Range`):

1. Chunked track assembles the **full, correct** file across multiple ranged requests (bytes
   match; size == N).
2. Each request carries the correct `Range: bytes=…`, and `track.httpHeaders` are still sent.
3. **200 fallback**: handler ignores `Range`, returns full body with 200 → one request, full
   file written.
4. Progress reaches ~1.0 across chunks.
5. Mid-chunk cancellation → `.cancelled`; a chunk HTTP error → `.downloadNetwork`.
6. `chunkSize == nil` → single-shot path unchanged (existing `DownloaderTests` still pass).

Python: a small assertion that `_track()` surfaces `chunk_size` from `downloader_options`.

**On-device:** only the owner can confirm the end-to-end googlevideo result (pick several
YouTube resolutions, confirm each completes without `-1001`; re-confirm non-YouTube still
downloads). The chunking mechanism itself is fully covered by the localhost tests.

## Out of scope (YAGNI)

Always-chunk / non-hinted sites; per-chunk resume; background downloads; changing the
single-shot path.
