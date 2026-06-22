# Manual test sources (7-site measurement)

> **Manual QA only — not wired into the automated suite.** Per `CLAUDE.md`, the
> `Downloader`/`Extractor` tests run against **localhost**, never real sites (flakiness
> + ToS). This is the hand-run checklist for the coverage roadmap's **Phase 3**
> ("run the 7 URLs by hand, keep a local failure log"). Paste each through an on-device
> build and record the `error_kind` (from the in-app **Share failure log**) + whether a
> playable file landed.

| Site | URL | Last result | Notes |
|------|-----|-------------|-------|
| Twitter / X | `https://x.com/AnatoliKopadze/status/2068750209652560159/video/1?s=46` | ✅ progressive (extract) | Re-run in python-dev resolves a progressive `.mp4`; the earlier `extract_network` was a **transient** SSL `UNEXPECTED_EOF` (X-side reset) that cleared on retry. End-to-end file-lands check still device-side. |
| YouTube | `https://youtu.be/WuMlsfKeWHc?is=UvPuvc7agzS-LGeP` | 🔁 re-verify on device (post-bump) | Earlier (pre-bump) cold-start fail→retry worked. **yt-dlp is now 2026.6.9 with n/sig solved by the new `KeraunosJavaScriptCoreJCP` (EJS-in-JSC) provider** — must be re-confirmed on-device; the JSC solver can't be tested in the harness. Auto-retry still smooths cold start. >1080p gated on the SABR spike. |
| Reddit | `/user/ProtolabsInc/comments/1qcyv5y/…` · `/r/oddlysatisfying/s/lfISGCakLL` | 🔒 auth/blocked | python-dev (this env): **Reddit gates everything** — the `/user/` post → `requires_auth`; the public `/s/` share link → `[generic]` **403 Blocked** (not mapped to `RedditIE`), and resolving its redirect also 403s; the listing JSON API 403s too. Codec path **can't be exercised from here**; inferred-good via the same bare-codec mechanism confirmed on RedNote/Douyin. **Re-verify on-device signed in to reddit.com.** |
| Bilibili | `https://b23.tv/BZUxFJQ` → `bilibili.com/video/BV1EHLd68E6k` | ❌ `extract_network` (really **HTTP 412 anti-bot**) | Reproduced in python-dev: Bilibili returns **412 Precondition Failed** at first webpage fetch for BOTH the short link and the resolved BV URL — extraction never reaches format selection (Phase 1 codecs irrelevant here). Needs a `buvid` cookie / **sign-in** (try Accounts → Sign in to bilibili.com), and/or a yt-dlp bump. `b23.tv` also isn't mapped to `BilibiliIE` (falls to `[generic]`). 412 is mis-bucketed as `extract_network`. |
| RedNote (Xiaohongshu) | `http://xhslink.com/o/6Wjwn9kFbBE` | ✅ progressive (`h264`/`aac`) | **Phase 1 verified live** — bare `h264`/`aac` admitted, resolves a progressive `.mp4`. Pre-fix this was rejected as `needs_ffmpeg`. End-to-end file-lands check still device-side. |
| Instagram | `https://www.instagram.com/reel/DZr09vjtwOC/` | 🔒 `requires_auth` | python-dev: "login required" → correctly mapped to `requires_auth` (Phase 2 path). Sign in to instagram.com (Accounts → Sign in), then retry. |
| TikTok / Douyin | `https://v.douyin.com/nANebZiUHp0/` | ✅ progressive (`h265`/`aac`) | python-dev: resolves a progressive `.mp4` with bare HEVC+AAC (also exercises Phase 1 bare-codec admission). End-to-end file-lands check still device-side. |

## How to record a result
1. Paste the URL, attempt the download on-device.
2. On failure, open **Diagnostics → Share failure log** and read the `error_kind`
   (`extract_network`, `download_network`, `requires_auth`, `needs_ffmpeg`,
   `unsupported`, `timeout`, `runtime`).
3. Note here whether a playable `.mp4` landed. That row-by-row result is the Phase 3
   measurement that, together with the Phase 3.5 SABR spike, decides Phase 4 scope.
