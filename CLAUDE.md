# Keraunos

A video downloader for iOS, powered by [yt-dlp](https://github.com/yt-dlp/yt-dlp).
GPLv3.

## Architecture

**Python extracts; Swift downloads** — embedded CPython + yt-dlp resolves a URL to a
direct media URL; native `URLSession` does the transfer. For DASH (separate video/audio
tracks), `AVFoundationMerger` muxes them into one file natively.

**Two layers:**
- **`app/KeraunosCore/`** — a Swift 6 SPM package holding the platform-agnostic core:
  URL normalization, format selection, `Downloader` (incl. ranged/chunked transfer),
  `MediaMerging`/`MediaAssembler`, stores, cookies, and the `KeraunosError` model.
  Protocol-seamed (`MediaExtracting`, `MediaMerging`, `PhotoSaving`) so it's testable
  without a simulator.
- **`app/Keraunos/Keraunos/`** — the app target: the CPython/yt-dlp bridge
  (`PythonRuntime/`), the "Refined Native" SwiftUI UI (`Theme/`, `Components/`, `UI/`),
  and authenticated-extraction plumbing (`Auth/`).

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
  -destination 'platform=iOS Simulator,name=iPhone 17' build

# Test the app (Swift Testing, needs a simulator)
xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos \
  -destination 'platform=iOS Simulator,name=iPhone 17' test

# Test the core package — fast, no simulator
swift test --package-path app/KeraunosCore
```

Day-to-day: open `app/Keraunos/Keraunos.xcodeproj` in Xcode, select the `Keraunos`
scheme, set your development team under *Signing & Capabilities*, ▶ Run.

## Key locations

- Core package (testable logic): `app/KeraunosCore/Sources/KeraunosCore/`
- App target: `app/Keraunos/Keraunos/` — `PythonRuntime/` (CPython bridge),
  `Theme/` · `Components/` · `UI/` (Refined Native SwiftUI), `Auth/` (cookies/login)
- Tests: core `app/KeraunosCore/Tests/` · app `app/Keraunos/KeraunosTests/` ·
  UI `app/Keraunos/KeraunosUITests/`
- Design specs: `docs/superpowers/specs/` · Implementation plans: `docs/superpowers/plans/`

## Design system

The Keraunos UI reference lives as a Claude Design project. When the user asks to
implement, sync, or check "the designs," use the **`claude_design`** MCP to fetch
layouts and tokens:

- **Endpoint:** `https://api.anthropic.com/v1/design/mcp`
- **Auth:** `/design-login` (first-time setup)
- **Project:** <https://claude.ai/design/p/117a4f30-f615-43c1-b7ce-fc11c9327e62>

Import the project through the MCP and implement designs from it against the SwiftUI
UI layer under `app/Keraunos/Keraunos/Theme/` · `Components/` · `UI/` (the "Refined
Native" palette).

## Testing

- Use **Swift Testing** (`import Testing`, `@Test`, `#expect`) — not XCTest.
- **`KeraunosCore` tests run without a simulator** (`swift test`) — the fastest loop;
  keep new pure-Swift logic in the package so it stays simulator-free.
- Pure-Swift units (format selector, path/filename, error mapping) are written first (TDD).
- `Downloader`/`Extractor` integration tests run against **localhost**, never real
  sites — avoids flakiness and ToS concerns.

## Gotchas

- **Swift 6 language mode, strict concurrency, everywhere.** All app targets
  (app, Share Extension, tests) are `SWIFT_VERSION = 6.0`, and `KeraunosCore` builds
  in Swift 6 mode. App + extension use `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`;
  the package keeps `nonisolated` default isolation. Keep new targets on 6.0.
- Deployment target is **iOS 26.0**.
- Embedded Python has **no `subprocess`/`fork`** → yt-dlp post-processors that shell
  out (ffmpeg) can't run. DASH video+audio merging therefore runs **natively**
  (`AVFoundationMerger`), and transfer is native `URLSession` — not Python. (An
  ffmpeg-backed `MediaMerging` could drop in later behind the same protocol.)
- Embedded Python has **no system CA store** — bundle `certifi` and point the SSL
  context at it, or all HTTPS extraction fails.
- **Multi-threaded embedded Python needs `PyEval_SaveThread()` after init.**
  `keraunos_python_init` releases the GIL once after `Py_InitializeFromConfig`; without
  it any worker thread (e.g. the extraction watchdog) deadlocks in `PyGILState_Ensure`.
- **`@_cdecl` entry points must be `nonisolated`.** The app target builds with
  `-default-isolation=MainActor`, so even global functions default to MainActor; a C
  entry point called off the main thread (e.g. `keraunos_js_eval` on the extraction
  worker) traps in `dispatch_assert_queue` unless marked `nonisolated`.
- **Clean-build after Swift/ObjC/bridge changes.** Incremental Xcode builds reliably
  re-sync `PythonResources/` (the "Process Python libraries" phase is `alwaysOutOfDate`),
  but can ship **stale compiled Swift/ObjC** — if on-device behavior contradicts the
  source, suspect a stale binary first and ⇧⌘K (Clean Build Folder) before debugging.
- **YouTube (googlevideo) throttles unranged full-file GETs** → a single
  `URLSession.download` receives no bytes and dies with `-1001`. yt-dlp hints
  `downloader_options.http_chunk_size` on those formats; `Downloader` honors it with
  HTTP Range chunks (`downloadChunked`). Only hinted tracks are chunked — every other
  site stays single-shot. Don't "simplify" the chunked path away.
