# Ranged/chunked downloads for YouTube adaptive DASH — draft

**Date:** 2026-07-01
**Status:** DRAFT — problem + root cause confirmed; approach NOT yet brainstormed/approved.
Brainstorm before implementing.

## Problem

Downloading a YouTube adaptive stream (e.g. itag 160, 144p video-only, `ANDROID_VR`
client, from `googlevideo.com`) times out with `NSURLErrorTimedOut` (`-1001`). Observed
on-device 2026-07-01: two consecutive ~60s stalls (the initial attempt + the transparent
auto-retry) on a ~3.5 MB stream. Surfaced by the new resolution picker, which lets the
user select adaptive YouTube formats; the default best-muxable path had been masking it.

## Root cause (confirmed)

`googlevideo` throttles single-shot (non-`range`) GETs on adaptive DASH streams to a
trickle, so a whole-file `URLSession.download(for:)` receives no bytes for the request
timeout window and fails `-1001`. yt-dlp itself avoids this by downloading googlevideo
formats in **HTTP Range chunks** (`http_chunk_size` / `&range=START-END`).

Keraunos's `Downloader` (`Downloader.swift:25`) does **one unranged** `URLSession.download`
per track with no chunking. Fine for every other supported site (Twitter/X, Reddit,
Bilibili, RedNote, Instagram — progressive or single-file DASH tolerate single GETs);
YouTube adaptive googlevideo is the exception.

Evidence it is transfer-only, not extraction/picker: the picker resolved the chosen format
correctly (itag 160), headers are replayed (`Downloader.swift:29`), and non-YouTube
downloads (X) succeed. So this is isolated to the transfer layer.

## Candidate approaches (to brainstorm — not decided)

1. **Range-chunked GETs in `Downloader`.** Issue sequential `Range: bytes=off-off+chunk-1`
   requests (e.g. 5–10 MB chunks), append to the destination file, until `Content-Range`
   total is reached. Mirrors yt-dlp's `http_chunk_size`. Keeps native transfer, adds
   progress/resume naturally. Most faithful fix; needs care around servers that ignore
   Range (fall back to single GET) and around the existing `DownloadProgressDelegate`.
2. **Append `&range=0-` (or the `gir` init range) to the URL.** Some googlevideo URLs
   change throttling behavior when a range param is present. Cheaper but fragile / not
   guaranteed.
3. **Prefer progressive/`ratebypass` formats for YouTube in the picker.** Constrain YouTube
   options to formats that download reliably single-shot. Sidesteps the transfer fix but
   limits the resolutions offered — partially defeats the feature for YouTube.

Leaning toward (1); it also subsumes the deferred background/resume backlog item (one
delegate rewrite). Confirm on-device against real googlevideo URLs before committing.

## Verification

Owner-run on-device: pick several YouTube resolutions (144p → 1080p) and confirm each
downloads to completion without `-1001`; re-confirm non-YouTube sites still download.

## Out of scope

Extraction, the picker UI, and non-YouTube sites (all working).
