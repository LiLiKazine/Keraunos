<div align="center">

# ⚡ Keraunos

**A video downloader for iOS, powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp).**

Save videos from X (Twitter), YouTube, and hundreds of other sites, straight to your iPhone or iPad — extracted entirely **on-device**, no server.

[![Platform](https://img.shields.io/badge/platform-iOS%2026.5%2B-blue.svg)](https://www.apple.com/ios/)
[![Status](https://img.shields.io/badge/status-early%20development-orange.svg)](#project-status)
[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](#license)

</div>

---

## What is Keraunos?

*Keraunos* (κεραυνός) is the thunderbolt of Zeus — the weapon that strikes from the sky and brings things down to earth. The app does the same for video: point it at a link, and it pulls the video down onto your device.

Under the hood, Keraunos builds on **yt-dlp**, the open-source extractor that knows how to find media on [a thousand-plus sites](https://github.com/yt-dlp/yt-dlp/blob/master/supported-sites.md). Keraunos runs that extraction logic on the phone itself — nothing is sent to a backend — and downloads with native iOS networking.

## Project status

> **⚠️ Early development.** There is no installable release — this repository is for people who want to build it themselves, follow along, or contribute. Pasting a link and getting an `.mp4` works end-to-end today for YouTube, X, RedNote, and TikTok (with Reddit, Bilibili, and Instagram once signed in; Douyin is currently gated out).

## Features

**Working today**

- 📥 **Paste a link, get a video** — one-tap paste with tolerant URL handling (adds a missing `https://`, trims stray whitespace), resolved by embedded yt-dlp and downloaded natively.
- 🧩 **Automatic stream merging** — when a site serves video and audio separately (adaptive), both tracks download and are muxed into a single `.mp4` natively (AVFoundation, no ffmpeg).
- ▶️ **YouTube on-device** — mints a Proof-of-Origin token via [bgutils](https://github.com/Brainicism/bgutil-ytdlp-pot-provider) and solves the n/sig challenge by running yt-dlp's solver bundle inside JavaScriptCore — entirely on the phone, no server. The slower first ("cold") run is auto-retried so it's seamless. Adaptive YouTube streams (which googlevideo throttles on a plain full-file GET) download in HTTP Range chunks, so higher-resolution transfers don't stall.
- 🎚️ **Resolution picker** — when a video offers more than one downloadable resolution, a picker lists them (e.g. `1080p · H.264 · ~45 MB`) so you choose before downloading; single-stream or direct-file links skip straight to the download with no added friction.
- ⏳ **Live progress & cancel** — a determinate progress bar during the transfer, cancellable at any point.
- ▶️ **Manage downloads** — tap to play/preview in-app (Quick Look), share/export to Photos, Files, or AirDrop, and swipe to delete. Newest-first, with file sizes.
- ♻️ **Resilient by default** — same-titled downloads never overwrite each other, titles with `/` or extreme length are handled safely, 0-byte duds are rejected, and recoverable failures (network blips, cold-start timeouts) auto-retry or offer a one-tap **Try again**.
- 🩺 **Private diagnostics** — a local, on-device failure log (no telemetry) you can export to debug what a site did.
- 📂 **Files app integration** — downloads land in the app's Documents folder, visible and usable in the Files app.
- 🔐 **Account sign-in** — sign into a site from the Accounts screen (or when an extraction reports it needs auth) via an in-app web view; cookies are reused for extraction, so signed-in / age-gated / bot-gated content resolves. Sites that gate behind login (Reddit, Bilibili, Instagram) route you straight to the sign-in prompt.

**In progress**

- 🔗 **Share into Keraunos** — the app-side receiver (deep link / `onOpenURL`) is built and tested; registering the URL scheme and adding the Share Extension target are the remaining Xcode steps (see `docs/superpowers/plans/2026-06-22-share-into-keraunos.md`).

**Planned**

- 🔊 Audio-only extraction.
- 🗂️ Download queue.
- 🛰️ Background transfer & resume for large (4K) files.

## Supported sites

Keraunos inherits its reach from yt-dlp — see the full, always-current list in the [yt-dlp supported sites](https://github.com/yt-dlp/yt-dlp/blob/master/supported-sites.md) document. In practice, support depends on what each extractor needs at runtime: extractors that resolve to a **progressive or adaptive** stream work well, while anything that requires **HLS remuxing or shelling out to ffmpeg** is not supported on-device (see [How it works](#how-it-works)).

Verified end-to-end on-device: **X (Twitter)**, **YouTube**, **RedNote (Xiaohongshu)**, and **TikTok**. **Reddit**, **Bilibili**, and **Instagram** extract once you sign in (they bot-/login-gate unauthenticated requests). **Douyin** is currently not supported in-app — its API is IP/anti-bot gated against the embedded request environment (and `curl_cffi` browser-TLS impersonation can't be bundled on iOS). Resolutions above 1080p (which require VP9/AV1/Opus and an ffmpeg-style merge) aren't supported: YouTube gates them behind SABR and no other single site justifies bundling a native remuxer.

## How it works

The central question for an iOS yt-dlp app is *how* to run yt-dlp, which is Python. Keraunos's answer:

> **Python extracts; Swift downloads.**

- An **embedded CPython 3.13** runtime ([BeeWare Python-Apple-support](https://github.com/beeware/Python-Apple-support)) runs yt-dlp to resolve a URL into direct media URL(s) — this is the only thing Python does.
- Native **`URLSession`** performs the actual transfer.
- If the result is adaptive (separate video + audio), Swift muxes the tracks into one MP4 with **AVFoundation**.

This keeps everything **on-device and private** — no backend service. It also imposes real constraints, which is why the feature set is shaped the way it is:

- Embedded Python has **no `subprocess`/`fork`**, so yt-dlp post-processors that shell out (ffmpeg) can't run — hence native download + AVFoundation merge, and no HLS remuxing.
- Embedded Python has **no system CA store**, so a bundled `certifi` CA bundle is wired into the SSL context.
- YouTube's JS challenges (`n`/`sig`) can't use a subprocess JS runtime either, so they're solved by running yt-dlp's solver bundle in the app's **in-process JavaScriptCore** — registered as a provider in yt-dlp's challenge-provider framework — alongside the on-device PO-token minting.

The detailed, evolving design lives under [`docs/superpowers/specs/`](docs/superpowers/specs/).

## Getting started

There is **no App Store release**, and one is unlikely: Apple does not approve video downloaders for sites like X and YouTube. Keraunos is distributed as **source you build yourself**.

### Requirements

- macOS with **Xcode** (latest stable recommended)
- iOS **26.5+** target — a device or the iOS Simulator
- An Apple ID for local code signing (a free account works for building to your own device)
- [`gh`](https://cli.github.com) or `curl` (to fetch the Python runtime, below)

### Build from source

```bash
git clone https://github.com/<your-org>/Keraunos.git
cd Keraunos
```

**1. Restore the Python runtime.** `Python.xcframework` (~115 MB) is a prebuilt binary and is **not** committed — you must fetch it before building, or the app won't link:

```bash
gh release download 3.13-b14 --repo beeware/Python-Apple-support \
  --pattern 'Python-3.13-iOS-support.b14.tar.gz'
tar -xzf Python-3.13-iOS-support.b14.tar.gz -C /tmp
cp -R /tmp/Python.xcframework app/Keraunos/PythonResources/
```

(See [`app/Keraunos/PythonResources/README.md`](app/Keraunos/PythonResources/README.md) for what else lives there and how it's wired. On Xcode Cloud this restore is automatic via `app/Keraunos/ci_scripts/ci_post_clone.sh`.)

**2. Open and run:**

```bash
open app/Keraunos/Keraunos.xcodeproj
```

Then in Xcode:

1. Select the **Keraunos** scheme.
2. Choose your target device (or a Simulator).
3. Set your **development team** under *Signing & Capabilities*.
4. Press **▶ Run**.

## Roadmap

- [x] Decide the yt-dlp integration approach (on-device embedded Python)
- [x] Core: resolve a URL → direct media stream(s)
- [x] Download a selected stream to local storage (progressive + adaptive merge)
- [x] Files app export
- [x] Account sign-in / cookie reuse for gated content
- [x] YouTube extraction (PO token + n/sig solved in JavaScriptCore) — *working on-device*
- [x] In-app playback/preview, share/export, and delete for downloads
- [x] Per-download resolution/quality picker
- [ ] Audio-only extraction
- [ ] Share Sheet extension — *app-side receiver done; Xcode target pending*
- [ ] Download queue
- [ ] Background transfer & resume for large (4K) files
- [x] >1080p (VP9/AV1/Opus) — *investigated & closed: YouTube is SABR-gated and Bilibili-AV1-only doesn't justify bundling an ffmpeg-style merge*

## Contributing

Contributions are welcome. For now:

- Open an **issue** to report bugs or propose features.
- Open a **discussion** for architecture and design.
- Keep pull requests focused and describe the *why*, not just the *what*.

A formal contributing guide and code style will land as the project takes shape.

## Legal & disclaimer

Keraunos is a tool. **You are responsible for how you use it.**

- Only download content you have the right to download. Respect copyright and the terms of service of any site you use.
- Downloading some content may violate a platform's terms of service or local law in your jurisdiction.
- Keraunos is not affiliated with X Corp., Google/YouTube, yt-dlp, or any site it can access.
- The software is provided "as is", without warranty of any kind.

## Acknowledgements

- [**yt-dlp**](https://github.com/yt-dlp/yt-dlp) — the engine that makes this possible.
- [**Python-Apple-support**](https://github.com/beeware/Python-Apple-support) — the embeddable CPython that runs it on iOS.
- Everyone who has contributed to the long lineage of open-source media tools that came before it.

## License

Keraunos is licensed under the **GNU General Public License v3.0** — see [`LICENSE`](./LICENSE) for the full text.

In short: you're free to use, modify, and distribute this software, but any distributed derivative must also be released under the GPLv3 with its source available. (yt-dlp itself is released under the [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE), which places no additional restrictions on this project.)

---

<div align="center">
<sub>⚡ Named for the thunderbolt of Zeus.</sub>
</div>
