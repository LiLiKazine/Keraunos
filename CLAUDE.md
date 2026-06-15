# Keraunos

A video downloader for iOS, powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp).
Build-from-source only — no App Store release. GPLv3.

## Architecture

**Python extracts; Swift downloads** — embedded CPython + yt-dlp resolves a URL to a
direct media URL; native `URLSession` does the transfer.

The detailed design (components, boundaries, error model) lives in
`docs/superpowers/specs/` and is **still evolving** — treat the spec as the source of
truth and read the latest one before working on extraction internals.

## Tech decisions

- **iOS app, SwiftUI, Swift 6 language mode.** UI is SwiftUI; no UIKit unless a
  capability is unavailable in SwiftUI.
- **Swift Concurrency over GCD.** Use `async`/`await`, `Task`, and structured
  concurrency for parallelism — not `DispatchQueue`/GCD.
- **Actors over locks for data safety.** Protect shared mutable state with `actor`
  isolation (and `@MainActor` for UI state), not `NSLock`/`os_unfair_lock`/serial queues.

## Commands

```bash
# Build (simulator)
xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Test (Swift Testing)
xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Day-to-day: open `app/Keraunos/Keraunos.xcodeproj` in Xcode, select the `Keraunos`
scheme, set your development team under *Signing & Capabilities*, ▶ Run.

## Key locations

- App sources: `app/Keraunos/Keraunos/`
- Unit tests: `app/Keraunos/KeraunosTests/` · UI tests: `app/Keraunos/KeraunosUITests/`
- Design specs: `docs/superpowers/specs/` · Implementation plans: `docs/superpowers/plans/`

## Testing

- Use **Swift Testing** (`import Testing`, `@Test`, `#expect`) — not XCTest.
- Pure-Swift units (format selector, path/filename, error mapping) are written first (TDD).
- `Downloader`/`Extractor` integration tests run against **localhost**, never real
  sites — avoids flakiness and ToS concerns.

## Gotchas

- **Swift 6 not yet enabled:** `project.pbxproj` still has `SWIFT_VERSION = 5.0`.
  Switch to the Swift 6 language mode before relying on strict concurrency checking.
- Deployment target is **iOS 26.5**.
- Embedded Python has **no `subprocess`/`fork`** → yt-dlp post-processors that shell
  out (ffmpeg) can't run; that's why HLS/merging is deferred and transfer is native.
- Embedded Python has **no system CA store** — bundle `certifi` and point the SSL
  context at it, or all HTTPS extraction fails.
