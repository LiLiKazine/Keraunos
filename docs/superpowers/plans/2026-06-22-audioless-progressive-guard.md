# Plan: guard against silent audio-less / video-less "success"

Date: 2026-06-22 (cycle 4) · Roadmap item: BACKLOG #3 (format-selector edge cases), thin slice.

## Problem

`_payload_for_info` (`keraunos_extract.py:92-110`) emits a `progressive` payload whenever
a single resolved format has `info.get("url")`, WITHOUT checking that the format actually
carries both audio and video. If the selector ever lands on a video-only (or audio-only)
single format — e.g. the trailing `best[protocol^=http][ext=mp4]` fallback matching a
video-only mp4 with `acodec: "none"` — the app saves a **silent audio-less file and
reports success**. For a hand-run tool, a "successful" download that's actually broken is
the worst failure mode (no error to read).

## Critical invariant (do NOT break)

The legitimate already-muxed **direct-file** path (M1 behavior) resolves formats yt-dlp
can't probe under `skip_download`, so `vcodec`/`acodec` come back as **`None` / missing** —
and that progressive payload is correct and must keep working (see the comment at
`keraunos_extract.py:26-31`). Therefore the guard must distinguish:
- `acodec == "none"` / `vcodec == "none"` → the **explicit string** "none" means the
  stream genuinely lacks that track → reject (`needs_ffmpeg`).
- `None` / missing → **unprobed direct file** → allow (current behavior).

## Change (`_payload_for_info`, progressive branch only)

Before emitting the `progressive` payload (the `if info.get("url"):` block), if the
format's `vcodec` or `acodec` is the explicit string `"none"`, return
`_err("needs_ffmpeg", "...")` instead. The adaptive branch is unchanged. Use a small
helper or inline check; keep it minimal and well-commented (explain the "none" string vs
`None` distinction, since it is the whole point).

## Tests (TDD, write FIRST) — `app/Keraunos/python-dev/test_extract.py`

Use the existing `_payload_for_info` / `_select` styles already in the file.

1. `test_videoonly_progressive_with_explicit_none_audio_is_needs_ffmpeg`: feed
   `_payload_for_info` an info dict with `url` set, `vcodec:"avc1..."`, `acodec:"none"` →
   expect `ok False`, `error_kind == "needs_ffmpeg"` (the silent-success bug). EXPECT THIS
   TO FAIL before the fix.
2. `test_audioonly_progressive_with_explicit_none_video_is_needs_ffmpeg`: `vcodec:"none"`,
   `acodec:"mp4a..."`, url set → needs_ffmpeg.
3. `test_directfile_progressive_with_unprobed_codecs_still_succeeds` (regression guard for
   the invariant): info with `url` set and NO `vcodec`/`acodec` keys (or both `None`) →
   still `ok True`, `kind == "progressive"`. This must pass before AND after.
4. Selector regression fixtures via `_select(...)` (no network), each asserting current
   correct behavior so it can't regress:
   - a video-only mp4 with `acodec:"none"` alone in the list — assert what `_select`
     returns (document whether `best[ext=mp4]` picks it or rejects it; either way the
     `_payload_for_info` guard above is the real safety net).
   - duplicate-resolution tie-break: two muxable progressive formats same height, differing
     `tbr` → assert the higher-`tbr` one is picked.
   - a format with `height: None` / missing `tbr` mixed with a normal one → selector must
     not crash and picks the valid muxable one.

If fixture #4's video-only `_select` assertion reveals the selector itself returns the
video-only format (i.e. `best` DOES pick it), note it in the test comment — the
`_payload_for_info` guard still catches it, which is the point.

## Verify gate

1. Python: `cd app/Keraunos/python-dev && .venv/bin/python -m pytest test_extract.py -q`
   — all green, new tests included.
2. Full build + Swift Testing suite on iPhone 17 simulator (no Swift change expected, but
   the gate is mandatory).
