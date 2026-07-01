# 2026-07-01-03: Resolution picker missed direct-file (Twitter/X) resolutions

**Status:** Implemented

## Context

On-device testing of the new resolution picker: YouTube showed a correct picker, but
Twitter/X videos showed **no** picker even though X exposes multiple resolutions (the
owner confirmed the official X app offers resolution choice, and the X video downloaded
fine in Keraunos — just with no picker).

## Root cause

`_muxable_height_options` (the phase-1 scanner that builds the picker list) required a
**recognized muxable vcodec** (`_muxable_vcodec(f["vcodec"])`) for every candidate. But
Twitter's direct MP4 renditions (`twitter.py._extract_variant_formats`, the non-m3u8
branch) are built with only `url`, `format_id`, `tbr`, and `height` (parsed from the URL)
— **no `vcodec`/`acodec`** (yt-dlp doesn't probe codecs under `skip_download`; they come
back `None`). So every X rendition was dropped → 0 options → `.ready` → no picker.

The download still worked because the `_FORMAT` selector's trailing
`best[protocol^=http][ext=mp4]` branch and `_payload_for_info` both accept an already-muxed
file with `None` codecs (the "M1 direct-file" path). That the download succeeded via
`best[protocol^=http][...]` actually proves these formats carry `protocol=https` and pass
every gate except the vcodec one. **The options scanner was stricter than the selector.**

## Options

| Approach | Pros | Cons |
|----------|------|------|
| Probe codecs for direct-file variants | "Correct" codec labels | Needs network/ffprobe; embedded Python can't; defeats skip_download |
| Show picker only for probed-codec sites (status quo) | Simplest | Hides real resolutions on X/RedNote — fails the feature's goal |
| **Admit already-muxed direct-file mp4s with unprobed codecs (chosen)** | Mirrors what the selector already downloads; pure; no network | No codec label / size for these rows (honest: shows just "720p") |

## Decision

Broaden `_muxable_height_options` to admit a third shape: an http `ext == "mp4"` format
with a known `height` and **both codecs unprobed** (`vcodec`/`acodec` are `None`/absent, not
the explicit string `"none"`), classified progressive (`adaptive=False`). This mirrors the
selector's `best[...][ext=mp4]` fallback and `_payload_for_info`'s `None`-acceptance.
Explicit `"none"` tracks (genuinely video-less/audio-less) remain rejected.

## What Changed

- `keraunos_extract.py::_muxable_height_options` — per-format classification rewritten into
  three explicit branches (muxable progressive / muxable video-only / unprobed direct-file
  mp4); explicit `"none"` still rejected.
- `test_extract.py` — 3 new fixture tests: admit Twitter-shaped codec-less mp4s (2 heights,
  `adaptive=False`, empty codec label, `None` size); reject explicit-`"none"` video; require
  `ext == "mp4"` for the direct-file branch.

## What Was Discovered

- The picker is effectively a per-site capability: it lights up wherever yt-dlp exposes ≥2
  distinct muxable http heights. YouTube (probed codecs) always qualified; direct-file sites
  (X, RedNote) now do too. HLS-only sites still won't (m3u8 excluded, no-ffmpeg).
- Direct-file rows legitimately have no codec label or size (yt-dlp reports neither under
  `skip_download`); `displayLabel` already drops those segments, so a bare "720p" is shown.
- The Swift layer needed no change — `ExtractionDecoder.decodeListing` already tolerates
  `codec: ""`/`approx_bytes: null`.

## Not addressed here (separate work)

YouTube adaptive-DASH downloads time out (`-1001`): googlevideo throttles single-shot
(non-`range`) GETs, and `Downloader` does one unranged `URLSession.download`. That's a
`Downloader` ranged/chunked-download limitation, tracked separately.
