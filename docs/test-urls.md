# Manual test sources (7-site measurement)

> **Manual QA only — not wired into the automated suite.** Per `CLAUDE.md`, the
> `Downloader`/`Extractor` tests run against **localhost**, never real sites (flakiness
> + ToS). This is the hand-run checklist for the coverage roadmap's **Phase 3**
> ("run the 7 URLs by hand, keep a local failure log"). Paste each through an on-device
> build and record the `error_kind` (from the in-app **Share failure log**) + whether a
> playable file landed.

| Site | URL | Last result | Notes |
|------|-----|-------------|-------|
| Twitter / X | `https://x.com/AnatoliKopadze/status/2068750209652560159/video/1?s=46` | ⚠️ `extract_network` | SSL `UNEXPECTED_EOF_WHILE_READING` fetching X JSON — transient/X-side reset; retry, or sign in to x.com. Progressive ≤720p path otherwise. |
| YouTube | `https://youtu.be/WuMlsfKeWHc?is=UvPuvc7agzS-LGeP` | — | ≤1080p H.264/AAC expected to work (tv/android_vr clients + PoT); >1080p gated on the SABR spike. |
| Reddit | _(add a v.redd.it post)_ | — | Phase 1 fix (bare `h264` + audio pairing) — verify live. |
| Bilibili | `https://b23.tv/BZUxFJQ` → `bilibili.com/video/BV1EHLd68E6k` | ❌ `extract_network` (really **HTTP 412 anti-bot**) | Reproduced in python-dev: Bilibili returns **412 Precondition Failed** at first webpage fetch for BOTH the short link and the resolved BV URL — extraction never reaches format selection (Phase 1 codecs irrelevant here). Needs a `buvid` cookie / **sign-in** (try Accounts → Sign in to bilibili.com), and/or a yt-dlp bump. `b23.tv` also isn't mapped to `BilibiliIE` (falls to `[generic]`). 412 is mis-bucketed as `extract_network`. |
| RedNote (Xiaohongshu) | _(add a note URL)_ | — | Phase 1 fix (bare `h264`/`aac`, no-ext URL) — verify live. |
| Instagram | _(add a reel/post URL)_ | — | Gated; sign in via the in-app web view (Phase 2 confirmed wired). |
| TikTok / Douyin | _(add a video URL)_ | — | Progressive H.264/AAC — expected to work today. |

## How to record a result
1. Paste the URL, attempt the download on-device.
2. On failure, open **Diagnostics → Share failure log** and read the `error_kind`
   (`extract_network`, `download_network`, `requires_auth`, `needs_ffmpeg`,
   `unsupported`, `timeout`, `runtime`).
3. Note here whether a playable `.mp4` landed. That row-by-row result is the Phase 3
   measurement that, together with the Phase 3.5 SABR spike, decides Phase 4 scope.
