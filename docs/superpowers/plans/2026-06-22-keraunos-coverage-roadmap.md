# Keraunos Site-Coverage Roadmap (Revised)

> **Status:** Strategy/roadmap, not a task-by-task implementation plan. Each numbered
> phase below should spawn its own detailed plan in this directory before work starts
> (see the existing milestone plans for the house format). This document is the
> source of truth for **build order and scope** — what to build, in what order, and
> what was deliberately *cut*.

**Audience/scope premise (decided):** Keraunos is a **personal / niche tool** —
build-from-source, no App Store, GPLv3. The audience is "people technical enough to
build it in Xcode with their own signing team," realistically a handful. There is **no
user population to telemeter**, and an on-device privacy-respecting downloader phoning
home would contradict its own values. This premise drives every decision below.

**The seven sites that define the spec:** YouTube, Twitter/X, Reddit, Bilibili,
RedNote (Xiaohongshu), Instagram, TikTok/Douyin. These — not an imagined long tail —
are the whole target. Coverage is judged against this list.

---

## How this revises the earlier roadmap

The earlier roadmap was leverage-ordered around **telemetry** ("let the `error_kind`
distribution drive build order") and named **fragment assembly** as "the biggest
envelope win." Grilling against the actual code and the seven-site list dismantled both
premises. The three load-bearing reversals:

1. **Telemetry → a spreadsheet.** No population exists to measure. "Phase 1
   observability" collapses to: run the 7 URLs by hand, keep a *local* failure log. No
   pipeline, no network. This also un-blocks the cheap correctness fix, which no longer
   waits behind a measurement phase.

2. **Fragment/segmented assembly → CUT.** It rescues **zero** of the seven sites:
   - Reddit's `fallback_url` is a single complete `.mp4`
     (`reddit.py:416-426`, `'vcodec': 'h264'`, `'ext': 'mp4'`, no fragments); its
     DASH/HLS manifest formats are single-BaseURL complete files on `v.redd.it`, not
     segments.
   - Bilibili's winnable path is the modern `dash` branch — single `baseUrl` video +
     separate audio (`bilibili.py:91-106`). The only thing carrying real `fragments`
     is the legacy `durl` path (`bilibili.py:111-131`), which is **FLV** —
     unreadable by AVFoundation in any case, so assembly can't rescue it.
   - The segmented paths that exist are therefore either FLV dead-ends or single-file
     DASH the **existing adaptive path already downloads** once the codec regex stops
     rejecting them.
   The real highest-leverage move was the *other* half of the old "Phase 0": the
   **codec-regex fix**.

3. **"Remux-only ffmpeg" → honestly scoped + SABR-gated.** Remux does **not** make
   AV1/VP9/Opus play in Photos. The owner accepts **non-Photos output** (VLC/transfer),
   which revives remux (stream-copy mux of two streams → `.mkv`) as correct and avoids a
   transcode pipeline. But whether >1080p YouTube is even *fetchable* depends on
   **SABR** — so the libav build is **gated behind a SABR de-risk spike**.

---

## Grounded failure-class map (the seven sites)

| Site | What it serves | Failing class | Fix |
|------|----------------|---------------|-----|
| RedNote | progressive mp4, bare-name codecs (`xiaohongshu.py:58-59`) | codec regex rejects `h264`/`aac` | **Phase 1** |
| Reddit | single-file `fallback_url` h264 + DASH/HLS audio | codec regex rejects bare `h264` | **Phase 1** (+ audio pairing) |
| Bilibili (H.264/HEVC) | `dash` single-`baseUrl` video + audio | works once codecs admitted | **Phase 1** |
| TikTok/Douyin | progressive mp4, H.264/AAC | works today | — |
| Instagram | progressive mp4, gated | auth | **Phase 2** (cookies) |
| Twitter/X | progressive mp4 ≤720p (`twitter.py:109-117`); HLS above | works ≤720p; >720p is MPEG-TS HLS | progressive works; >720p **deferred** (TS) |
| YouTube | H.264/AAC ≤1080p (`tv`/`android_vr`); VP9/AV1/Opus above | works ≤1080p | >1080p **Phase 4**, SABR-gated |
| Bilibili (AV1) | `dash` AV1 video + audio | AVFoundation can't mux | >1080p **Phase 4** (libav) |

**Key consequences:**
- The current selector (`keraunos_extract.py:21-26`) rejects **bare codec names** —
  `vcodec~='^(avc1|hvc1|hev1)'` and `acodec^=mp4a` miss `h264`/`hevc`/`aac`. This single
  bug suppresses RedNote *and* Reddit's clean fallback video.
- `MediaTrack` (`MediaTrack.swift:7`) carries a single `url`; the Python `_track()`
  (`keraunos_extract.py:106-113`) emits only `url`/headers/codecs/ext. Neither needs to
  grow a fragment list anymore — fragment assembly is cut.
- The `MediaMerging` protocol (`MediaMerging.swift:6-8`) is the seam for a second merge
  backend; its doc comment already anticipates an ffmpeg-backed impl. `LibavRemuxer`
  drops in here with no caller changes.

---

## Plan (build order)

### Phase 1 — Codec-regex fix  *(highest result-to-effort; hours)*  ✅ DONE (commit `1db9df0`)
> Landed: `_FORMAT` now admits bare `h264`/`avc`/`hevc`/`h265` + `aac` (named regex
> fragments), `[protocol^=http]` added to the bestaudio branches, and format-selector
> unit tests (`test_extract.py`) cover RedNote no-ext, Reddit video+audio pairing, bare
> HEVC, a fourcc regression guard, and an AV1/VP9/Opus rejection guard. Verified on
> localhost fixtures only — **not yet confirmed against the live sites** (that's Phase 3).
> Next loop iteration: start **Phase 2 (Instagram cookies)**.

Loosen the selector in `keraunos_extract.py:21-26` to admit bare codec names alongside
the `avc1/hvc1/hev1` / `mp4a` forms (e.g. accept `h264`/`avc`, `hevc`/`hvc1`/`hev1`,
`aac`/`mp4a`). Expected to flip **RedNote** and **Reddit** on and stop rejecting
**Bilibili-H.264** — all of which then play in Photos.
- **Do NOT** add the protocol-exclusion "bandage" (`protocol~='^https?$'`). It was only
  ever a stopgap to convert Bilibili's truncated-file into a clean error, and Bilibili's
  winnable path is single-file DASH that this phase already enables. Skipped.
- TDD: extend the format-selector unit tests with bare-codec fixtures first.

### Phase 2 — Cookies for Instagram  ✅ DONE (commit `90f60dd`)
> Confirmed **already-working, no code change**. The full chain is wired:
> `resolve()` → `cookieFile()` (Netscape export) → Python `cookiefile`; on
> `requires_auth` the VM sets `signInURL` = pasted URL → "Sign in to {host}" button →
> `LoginWebView` on the **shared** `WKWebsiteDataStore` → captured cookies persist →
> `retry()` re-exports. Verified every unauthenticated IG failure path maps to
> `requires_auth` (all reach `raise_login_required`/embed `_login_hint`, which carries
> "cookies" ∈ `_AUTH_HINTS`). Added a regression guard for that mapping
> (`test_instagram_login_required_maps_to_requires_auth`). **Not yet exercised against
> live Instagram** (Phase 3). Next loop iteration: **Phase 3 (measure + local failure log)**.

Verify the existing cookie path (`CookieStore`, `NetscapeCookieWriter`, `LoginWebView`,
`cookiefile` wiring at `keraunos_extract.py:150-151`) works **end-to-end for Instagram**
specifically. Likely small or already-working; confirm, don't assume.

### Phase 3 — Measure + local failure log  ⏳ PARTIAL (code half done, commit `fdc6d28`)
> **Code half done:** the overloaded `network` kind is split into `extract_network`
> (Python, `keraunos_extract.py`) and `download_network` (Swift `Downloader`); legacy
> `"network"` aliases to `.extractNetwork`; distinct user messages; tests on both sides.
> **Recording side now automated (commit `472db28`):** the app keeps an on-device,
> no-network `FailureLog` — every non-cancelled failure appends `time/kind/url/detail`,
> exported via a "Share failure log" item. `KeraunosError.kind` slugs match the Python
> `error_kind` vocabulary so logged failures read identically to the extractor output.
> **Still owner-manual (needs an on-device build + live sites; a downloader can't
> responsibly auto-hit the 7 real sites):** run all seven URLs through the build, then
> read the exported log + confirm whether a playable file landed for each.
> Next loop iteration: **Phase 3.5 (SABR de-risk spike)** — pursue the code-level/static
> analysis portion (what `player_client`/PoT produce); the live-dump confirmation is
> likewise an on-device step.

Paste all seven URLs through the patched build; record `error_kind` + whether a playable
file lands. While here, **split the overloaded `network` error-kind** into
`extract_network` vs `download_network` (currently collapsed —
`keraunos_extract.py:169-170`, `KeraunosError.swift:25`) so *your own* debugging can tell
which side failed. This is a **local log**, not telemetry.

#### Phase 3.5 — SABR de-risk spike  *(GATES Phase 4)*  ✅ DONE — SABR-ONLY (2026-07-21)
> Detailed spike plan: **`2026-06-22-phase-3.5-sabr-spike.md`**. **Result: SABR-ONLY**.
> Run on iOS Simulator (iPhone 17, iOS 26.3) against `aqz-KE-bpKQ` with the web client
> forced and the format selector relaxed to `bestvideo+bestaudio/best`. yt-dlp emitted
> the code-grounded pass/fail marker verbatim:
> *"Some web client https formats have been skipped as they are missing a URL. YouTube
> is forcing SABR streaming for this client."* All VP9/AV1 and >1080p H.264 formats
> were dropped for missing URL; only legacy **itag 18** (360p H.264+AAC unified
> pre-merge stream) survived. Confirmed **not a Keraunos wiring bug**: KeraunosPoTokenProvider
> was registered and picked up by yt-dlp (`[pot] PO Token Providers: KeraunosPoTokenProvider-0.1.0`),
> `[jsc:javascriptcore]` nsig solver ran, cookies loaded — this is a YouTube-server
> verdict on the `web` client family, not on our wiring.

For YouTube, force the **web client + the existing PoT provider**
(`keraunos_youtube_pot.py:131` already supports `web`/`web_safari`/`mweb`) and dump the
resolved >1080p format's `protocol`/`url`. Confirm it is a **fetchable URL**, not a
**SABR-only** stream (which `URLSession` cannot fetch and yt-dlp only handles via its
experimental SABR client).
- **If SABR-only:** >1080p YouTube is off the table regardless of libav. Phase 4 then
  justifies itself **only on Bilibili AV1** — reconsider whether the libav maintenance
  cost is worth it for one site.
- **If fetchable:** proceed to Phase 4.

### Phase 4 — The >1080p bundle  ⏸ DEFERRED (2026-07-21) — wait for yt-dlp SABR downloader
> **Decision:** short-term accept a ≤1080p YouTube ceiling; revisit when yt-dlp lands
> stable SABR download support (issue [#12482](https://github.com/yt-dlp/yt-dlp/issues/12482)).
> Phase 3.5 came back SABR-ONLY, which means libav alone cannot unlock YouTube >1080p —
> the URLs aren't fetchable via `URLSession` regardless of muxing. When yt-dlp's SABR
> downloader ships, the plan of record becomes a **bifurcated download path**
> (yt-dlp/Python SABR for YouTube >1080p only, native `URLSession` for everything else),
> not a native Swift SABR reimplementation. Bilibili AV1 alone was judged insufficient
> justification for a permanent hand-cross-compiled libav on this project's scope, so
> it's deferred with the same reconsideration trigger. The current `tv`/`tv_embedded`/
> `android_vr` client set covers YouTube ≤1080p H.264+AAC without incident.
>
> **Original bundle plan (preserved for the revisit):**

A single coordinated change driven by the large-file / high-codec use case. Output is
`.mkv` and **not Photos-playable** (VLC / transfer off-device) — explicitly accepted.
AVFoundation stays the **default** merge path so all ≤1080p H.264/HEVC+AAC sites keep
landing in Photos; libav is the **second** path, used only for AV1/VP9+Opus.

1. **Selector:** add a "best regardless of codec" branch *above* the current
   AVFoundation-only branches in `_FORMAT`.
2. **Routing:** `MediaAssembler` picks merger by codec — `{avc1,hvc1,hev1}` + `mp4a` →
   `AVFoundationMerger` (→ `.mp4`, Photos); else → `LibavRemuxer` (→ `.mkv`).
3. **libav (the real work):** cross-compile a **trimmed, stream-copy** libav for iOS
   `arm64` device + simulator. No encoders/decoders needed for `-c copy` (small binary;
   stays LGPL-eligible, moot under GPLv3). Roughly
   `--disable-everything --enable-demuxer=mov,matroska --enable-muxer=matroska
   --enable-protocol=file` + the AV1/Opus parsers/bitstream filters. **`ffmpeg-kit` was
   retired in early 2025 — there is no prebuilt shortcut; this is a self-owned build,
   re-toolchained on every Xcode/iOS bump.**
4. **`LibavRemuxer: MediaMerging`** + a tiny C shim
   (`keraunos_remux(video, audio, out)`).
5. **`Downloader` delegate rewrite — one change, three wins.** Replace
   `session.download(for:)` (`Downloader.swift:17`, the async-convenience API that
   cannot background, gives no progress, and cannot resume) with the `URLSession`
   **delegate** API on a **background configuration**. This delivers
   background + byte-progress + resume together, and is near-prerequisite for
   hundreds-of-MB 4K downloads (foreground `URLSession.shared` dies on app suspend).
   Sequenced **with** the libav phase, not after — the ≤1080p sites don't need it, so it
   doesn't block the early wins.

Serves: **Bilibili AV1** and (if 3.5 clears) **YouTube >1080p**.
Does **not** serve **Twitter >720p** — that is single-stream **MPEG-TS HLS**, a
different operation (TS→container remux), and stays deferred.

---

## Explicitly cut / deferred

- **Fragment & segmented-stream assembly** — no customer in the seven-site list
  (segmented paths are FLV dead-ends or already-handled single-file DASH).
- **Protocol-exclusion bandage** — stopgap with no place once Phase 1 lands.
- **MPEG-TS HLS** (Twitter >720p) — needs TS→container remux, a different tool than the
  two-stream `.mkv` mux. Deferred indefinitely.
- **Transcode pipeline** (AV1/VP9/Opus → H.264/AAC for Photos playback) — unnecessary
  given the accepted non-Photos output. Not built.
- **Telemetry pipeline** — contradicts the tool's values; replaced by a local log.

## Standing maintenance (accepted, never "done")

- **YouTube PoT path** (`keraunos_youtube_pot.py`) — hardcoded keys/`requestKey`, the
  most fragile surface; budget for ongoing repair.
- **YouTube n/sig path** (`keraunos_youtube_jsc.py`) — a `JsChallengeProvider` that runs
  yt-dlp's EJS solver bundle (`yt-dlp-ejs`) in JavaScriptCore. A yt-dlp bump must keep the
  vendored `yt-dlp-ejs` version aligned with yt-dlp's expected `vendor.VERSION`/hashes, and
  the EJS framework internals can shift — re-verify on-device after each bump.
- **yt-dlp re-vendor** — manual bumps on the owner's cadence (currently pinned
  `2026.6.9`; **requires Python ≥ 3.10** to test — dev venv must be 3.10+, embedded is 3.13).

---

## Why this is correct for *this* project

The earlier roadmap reasoned about a generic long tail and an imagined user
distribution. For a seven-site personal tool whose code we've read, the answers were
already determined: the cheap codec-regex fix is the real spine, fragment assembly has
no customer, and the only genuine envelope-expander (>1080p) is gated by SABR and paid
for with a permanent libav build. Build order follows leverage against the actual seven
sites, not against an abstraction.
