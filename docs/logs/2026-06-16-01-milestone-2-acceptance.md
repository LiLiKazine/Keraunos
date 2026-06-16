# 2026-06-16-01: Milestone 2 (native DASH merge) acceptance results

**Status:** Automated acceptance passed; on-device progressive + auth paths
confirmed; a live DASH-merge round-trip still **pending** (needs a non-auth-gated
adaptive source).

## Environment

- macOS (Darwin 25.4), Xcode 26.5 toolchain.
- Core tests run on macOS (no simulator); app tests on the iPhone 17 Pro Max
  simulator (iOS 26.5).
- Embedded CPython 3.13 + yt-dlp 2025.10.14 (unchanged from Milestone 1).
- Built `.app` size (Debug, iphonesimulator): **90 MB** (embedded Python
  framework + stdlib + `app_packages/yt_dlp` dominate; merge adds no binary —
  AVFoundation is a system framework).
- `ffmpeg`/`ffprobe` available locally (used only for the merge proof below; the
  app itself never shells out to ffmpeg).

## Automated test tiers — all green

| Tier | Command | Result |
|------|---------|--------|
| Core | `swift test --package-path app/KeraunosCore` | **19 tests, 7 suites — passed** |
| Python dev | `.venv/bin/pytest -q` (python-dev) | **3 passed** |
| App | `xcodebuild test … -only-testing:KeraunosTests` | **TEST SUCCEEDED** (4 view-model tests) |
| App build | `xcodebuild build … (simulator)` | **BUILD SUCCEEDED** |

Coverage of the new milestone-2 behavior:
- `ExtractionDecodingTests` — progressive + adaptive (two tracks + headers),
  `.needsFfmpeg` payload, filename fallback, malformed → runtime.
- `DownloaderTests` — saves the track; maps HTTP/cancel errors; **replays
  per-track HTTP headers** (`sendsTrackHTTPHeaders`).
- `MediaAssemblerTests` — progressive (merger not called); adaptive (both tracks
  downloaded → merge → temp cleanup); merge-failure (temp cleanup + no half-file
  in Documents).
- `AVFoundationMergerTests` — error path: non-media inputs → `.mergeFailed`.
- `DownloadViewModelTests` — progressive success, merge-failure message,
  extraction-error message, invalid-URL rejection.
- Python pytest — progressive/adaptive payload shape (headers + codecs) +
  localhost progressive resolution.

## Merge happy-path — proven on real media (automated, non-CI)

The design deferred happy-path mux verification to manual "if fixture muxing is
flaky in CI." To raise confidence ahead of GUI acceptance, a one-off (not
committed) test ran `AVFoundationMerger` on real fixtures generated with ffmpeg:

- Inputs: a 2s **H.264 video-only** `.mp4` (`testsrc`) + a 2s **AAC audio-only**
  `.m4a` (`sine`).
- `AVFoundationMerger().merge(video:audio:into:)` produced `merged.mp4`.
- `ffprobe` of the output:
  - streams: `h264,video` **and** `aac,audio`
  - container: `mov,mp4,m4a,3gp,3g2,mj2`, duration `2.000000`

This demonstrates the native passthrough mux combines a separate video-only +
audio-only pair into one playable MP4 with both streams — done-criterion #1's
core mechanism. The fixtures and throwaway test were removed (tree clean), per
the design's choice to keep ffmpeg-fixture muxing out of the committed suite.

## On-device acceptance (iPhone simulator, live network)

| URL | Outcome | Interpretation |
|-----|---------|----------------|
| Public X video post | ✅ **Downloaded** — `Movez - Claude Code creator… [2066225283271708672].mp4` appears in the Downloads list | **Done-criterion #2 met**: progressive X resolves + downloads through the migrated model (M1 parity preserved). |
| YouTube Shorts `…/shorts/SJp529flHbE…` | "This video requires sign-in (cookies), which isn't supported yet." (no crash) | YouTube's anti-bot wall ("sign in to confirm you're not a bot") matches `_AUTH_HINTS` → `.requiresAuth`. **Done-criterion #4 auth path met**; YouTube is best-effort, not a gate. |
| A DASH source (separate video+audio) → single playable MP4 with audio | **pending** | Needs a non-auth-gated adaptive source; YouTube is currently blocked by anti-bot. Mux mechanism already proven on real fixtures (above). |

## Done-check (spec §"Done criteria")

1. **DASH source → single playable MP4 with audio** — mux mechanism **proven**
   above on real H.264+AAC fixtures. End-to-end via the app on a live DASH URL is
   **pending user** (GUI + Files playback).
2. **Progressive sources still work** — ✅ confirmed on-device (X video downloaded
   to the list). The Python selector keeps a progressive `mp4` fallback so M1's
   direct-file path still resolves (see commit `feat(python): emit
   progressive/adaptive contract`).
3. **Per-format HTTP headers sent** — ✅ unit-tested (`sendsTrackHTTPHeaders`).
4. **Non-muxable / HLS / auth fail with the correct KeraunosError** — ✅ for the
   mapping (decoder/error unit tests) **and** the auth path confirmed on-device
   (YouTube Shorts → `.requiresAuth`, no crash); a live HLS/VP9-only link is the
   only remaining unverified sub-case.
5. **No temp-file leakage** — ✅ unit-tested (assembler cleans scratch on success
   and on merge failure).
6. **All test tiers green** — ✅ (table above).

## Pending manual steps (require the app GUI + live network)

These cannot be scripted reliably here (real network, YouTube anti-bot, and
visual playback confirmation), so they are left for an on-device/simulator run:

1. Paste a public X video post → confirm `.mp4` appears in the list (M1 parity).
2. Paste a DASH source whose best muxable result is separate video+audio →
   confirm status cycles "Downloading video… → Downloading audio… → Combining…"
   and one `.mp4` appears that **plays with both video and audio** in the Files
   app (On My iPhone → Keraunos). Optionally verify on disk:
   `ffprobe -show_entries stream=codec_type …` lists both `video` and `audio`.
3. Paste an HLS-only or VP9/AV1-only link → confirm a clear `.needsFfmpeg`
   message, not a crash.

YouTube remains best-effort (locked `googlevideo` URLs / anti-bot), not an
acceptance gate, per the design.
