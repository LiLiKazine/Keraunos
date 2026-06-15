<div align="center">

# ⚡ Keraunos

**A video downloader for iOS, powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp).**

Save videos from X (Twitter) and hundreds of other sites, straight to your iPhone or iPad.

[![Platform](https://img.shields.io/badge/platform-iOS-blue.svg)](https://www.apple.com/ios/)
[![Status](https://img.shields.io/badge/status-early%20development-orange.svg)](#project-status)
[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](#license)

</div>

---

## What is Keraunos?

*Keraunos* (κεραυνός) is the thunderbolt of Zeus — the weapon that strikes from the sky and brings things down to earth. The app does the same for video: point it at a link, and it pulls the video down onto your device.

Under the hood, Keraunos builds on **yt-dlp**, the open-source extractor that knows how to find and download media from [a thousand-plus sites](https://github.com/yt-dlp/yt-dlp/blob/master/supported-sites.md). Keraunos wraps that capability in a native iOS experience.

> **⚠️ Project status:** Keraunos is in **early development**. There is no installable release yet — this repository is for people who want to build it themselves, follow along, or contribute. See [Project Status](#project-status).

## Features

> Planned. Tracking what's built in the [Roadmap](#roadmap).

- 📥 **Paste a link, get a video** — share or paste a URL from X and other supported sites.
- 🎞️ **Quality selection** — choose resolution and format before downloading.
- 🔊 **Audio-only extraction** — pull just the audio when that's all you need.
- 📂 **Files app integration** — downloads land somewhere you can actually use them.
- 🔗 **Share Sheet support** — send a link to Keraunos directly from another app.
- 🌑 **Native, offline-friendly UI** — built for iOS, no ads, no accounts.

## Supported sites

Keraunos inherits its reach from yt-dlp. That includes **X (Twitter)** and many others — see the full, always-current list in the [yt-dlp supported sites](https://github.com/yt-dlp/yt-dlp/blob/master/supported-sites.md) document.

Actual support in Keraunos depends on how the yt-dlp integration is wired up (see below) and may be a subset during early development.

## How it works (open design question)

yt-dlp is a **Python** program. iOS apps don't run Python out of the box, so the central architectural decision for Keraunos is *how* to run yt-dlp's extraction logic. This is **not yet decided**, and the README will be updated once it is. The candidates:

| Approach | Summary | Trade-offs |
| --- | --- | --- |
| **Backend service** | The app sends a URL to a server (self-hostable) that runs yt-dlp and returns the media. | Simplest to ship; keeps yt-dlp up to date easily. Requires hosting; not fully on-device. |
| **On-device Python** | Bundle a Python runtime (e.g. [python-apple-support](https://github.com/beeware/Python-Apple-support)) and yt-dlp into the app. | Fully private and offline. Larger binary, more fragile to maintain and update. |
| **Native Swift port** | Reimplement extraction in Swift, using yt-dlp as the reference. | No Python dependency. By far the most work; hard to keep pace with yt-dlp. |

If you have opinions or experience here, this is the best place to [contribute](#contributing) — open a discussion or issue.

## Getting started

There is **no App Store release**, and one is unlikely: Apple does not approve video downloaders for sites like X and YouTube. Keraunos is distributed as **source you build yourself**.

### Requirements

- macOS with **Xcode** (latest stable recommended)
- An Apple ID for local code signing (a free account works for building to your own device)
- An iPhone or iPad, or the iOS Simulator

### Build from source

```bash
git clone https://github.com/<your-org>/Keraunos.git
cd Keraunos
open Keraunos.xcodeproj   # or Keraunos.xcworkspace
```

Then in Xcode:

1. Select the **Keraunos** scheme.
2. Choose your target device (or a Simulator).
3. Set your **development team** under *Signing & Capabilities*.
4. Press **▶ Run**.

> Detailed setup — including how the yt-dlp integration is configured — will be documented here once the [architecture](#how-it-works-open-design-question) is settled.

## Roadmap

- [ ] Decide the yt-dlp integration approach
- [ ] Core: resolve a URL → list available formats
- [ ] Download a selected format to local storage
- [ ] Files app / Photos export
- [ ] Share Sheet extension
- [ ] Quality and audio-only options
- [ ] Download queue and history

## Contributing

Contributions are welcome — especially input on the [core architecture question](#how-it-works-open-design-question). For now:

- Open an **issue** to report bugs or propose features.
- Open a **discussion** for architecture and design.
- Keep pull requests focused and describe the *why*, not just the *what*.

A formal contributing guide and code style will land as the project takes shape.

## Legal & disclaimer

Keraunos is a tool. **You are responsible for how you use it.**

- Only download content you have the right to download. Respect copyright and the terms of service of any site you use.
- Downloading some content may violate a platform's terms of service or local law in your jurisdiction.
- Keraunos is not affiliated with X Corp., yt-dlp, or any site it can access.
- The software is provided "as is", without warranty of any kind.

## Acknowledgements

- [**yt-dlp**](https://github.com/yt-dlp/yt-dlp) — the engine that makes this possible.
- Everyone who has contributed to the long lineage of open-source media tools that came before it.

## License

Keraunos is licensed under the **GNU General Public License v3.0** — see [`LICENSE`](./LICENSE) for the full text.

In short: you're free to use, modify, and distribute this software, but any distributed derivative must also be released under the GPLv3 with its source available. (yt-dlp itself is released under the [Unlicense](https://github.com/yt-dlp/yt-dlp/blob/master/LICENSE), which places no additional restrictions on this project.)

---

<div align="center">
<sub>⚡ Named for the thunderbolt of Zeus.</sub>
</div>
