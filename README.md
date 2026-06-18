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

> **⚠️ Project status:** Keraunos is in **early development**. There is no installable release — this repository is for people who want to build it themselves, follow along, or contribute. Pasting an X video link and getting an `.mp4` in Files works end-to-end today; see [Status](#project-status).

## Features

**Working today**

- 📥 **Paste a link, get a video** — resolve a URL with embedded yt-dlp and download it to your device.
- 🧩 **Automatic stream merging** — when a site serves video and audio separately (adaptive), both tracks download and are muxed into a single `.mp4` natively (AVFoundation, no ffmpeg).
- 📂 **Files app integration** — downloads land in the app's Documents folder, visible and usable in the Files app.
- 🔐 **Account sign-in** — log in to a site in an in-app web view; cookies are reused for extraction so signed-in/age-gated content resolves.

**In progress**

- ▶️ **YouTube** — on-device extraction needs a Proof-of-Origin (PO) token; Keraunos mints one via [bgutils](https://github.com/Brainicism/bgutil-ytdlp-pot-provider) inside JavaScriptCore. Actively being hardened.

**Planned**

- 🎞️ Quality / format selection before downloading.
- 🔊 Audio-only extraction.
- 🔗 Share Sheet extension (send a link to Keraunos from another app).
- 🗂️ Download queue and history.

## Supported sites

Keraunos inherits its reach from yt-dlp — see the full, always-current list in the [yt-dlp supported sites](https://github.com/yt-dlp/yt-dlp/blob/master/supported-sites.md) document. In practice, support depends on what each extractor needs at runtime: extractors that resolve to a **progressive or adaptive** stream work well, while anything that requires **HLS remuxing or shelling out to ffmpeg** is not supported on-device (see [How it works](#how-it-works)). **X (Twitter)** is verified end-to-end; **YouTube** is in progress.

## How it works

The central question for an iOS yt-dlp app is *how* to run yt-dlp, which is Python. Keraunos's answer:

> **Python extracts; Swift downloads.**

- An **embedded CPython 3.13** runtime ([BeeWare Python-Apple-support](https://github.com/beeware/Python-Apple-support)) runs yt-dlp to resolve a URL into direct media URL(s) — this is the only thing Python does.
- Native **`URLSession`** performs the actual transfer.
- If the result is adaptive (separate video + audio), Swift muxes the tracks into one MP4 with **AVFoundation**.

This keeps everything **on-device and private** — no backend service. It also imposes real constraints, which is why the feature set is shaped the way it is:

- Embedded Python has **no `subprocess`/`fork`**, so yt-dlp post-processors that shell out (ffmpeg) can't run — hence native download + AVFoundation merge, and no HLS remuxing.
- Embedded Python has **no system CA store**, so a bundled `certifi` CA bundle is wired into the SSL context.

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
- [ ] YouTube extraction (PO tokens) — *in progress*
- [ ] Quality and audio-only options
- [ ] Share Sheet extension
- [ ] Download queue and history

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
