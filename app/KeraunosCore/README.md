# KeraunosCore

The platform-agnostic core of [Keraunos](https://github.com/LiLiKazine/Keraunos),
a video downloader for iOS/macOS. KeraunosCore does the **downloading**: URL
normalization, format selection, native `URLSession` transfer (including
ranged/chunked downloads for hosts that throttle full-file GETs), `AVFoundation`
DASH muxing (separate video+audio → one file), download stores, cookies, and a
typed error model.

It is protocol-seamed (`MediaExtracting`, `MediaMerging`, `FileDownloading`) so it
can be exercised without a simulator.

> **Extraction is not included.** Resolving a page URL to a direct media URL (in
> Keraunos, embedded CPython + yt-dlp) lives in the app, not here. You bring your
> own `MediaExtracting` implementation; KeraunosCore takes it from there.

> **Stability: 0.x.** The public API may change between minor versions.

## Requirements

- iOS 26 / macOS 15
- Swift 6 (language mode), Swift tools 6.2+

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/LiLiKazine/KeraunosCore.git", from: "0.1.0")
```

Then add `"KeraunosCore"` to your target's dependencies.

## Quick start

```swift
import KeraunosCore

// 1. You resolve the page URL to media (bring your own MediaExtracting).
let media: ResolvedMedia = try await myExtractor.resolve(pageURL, option: nil)

// 2. KeraunosCore downloads it — muxing automatically if it's adaptive DASH.
let assembler = MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger())
let store = DownloadStore()   // defaults to the app's Documents directory

let fileURL = try await assembler.assemble(media, into: store) { progress in
    print("progress: \(Int(progress * 100))%")
}
print("saved to \(fileURL.path)")
```

For a progressive (single-file) source, `assemble` downloads straight to the
store. For an adaptive source (`.adaptive(video:audio:)`), it downloads both
tracks and muxes them with `AVFoundationMerger`.

## License

MIT — see [LICENSE](LICENSE). Note: the full Keraunos **app** is licensed GPLv3;
only this core library is MIT.
