# Keraunos — yt-dlp Integration Architecture (Design)

**Date:** 2026-06-15
**Status:** Approved design — pre-implementation
**Scope:** How Keraunos (iOS app) runs yt-dlp, and the definition of Milestone 1.

---

## 1. Decision

Keraunos runs **yt-dlp under an embedded CPython interpreter on-device**, but splits the work so that the fragile part stays small:

> **Python extracts; Swift downloads.**
> - Embedded Python / yt-dlp resolves a page URL into a **direct media URL + metadata** (`extract_info(url, download=False)`).
> - Native **`URLSession`** performs the actual file transfer.

This is on-device (the user's stated preference), needs no server, and — by moving the byte transfer to `URLSession` — sidesteps the two real iOS constraints on embedded Python (no background execution, no `subprocess`). It matches proven prior art (`kewlbear/YoutubeDL-iOS`).

A **backend service remains a documented fallback** only if on-device packaging proves unworkable. The `Extractor` boundary is designed so its implementation could be swapped to call a server without touching the rest of the app.

### Rejected alternatives

- **Native Swift port of yt-dlp's extractors** — most effort, highest ongoing maintenance (yt-dlp patches sites within days), contradicts the on-device-but-pragmatic stance. Rejected.
- **yt-dlp performs the download itself** (`download=True`) — fails on iOS for large/backgrounded transfers and adds progress-hook bridging. Rejected in favor of the Python-extracts / Swift-downloads split.

---

## 2. Why this is feasible (verified 2026-06-15)

- **iOS is an official CPython platform** (PEP 730, since Python 3.13, Tier 3). BeeWare **Python-Apple-support** ships a prebuilt `Python.xcframework` (device arm64 + simulator), actively maintained (3.13/3.14 builds dated 2026-06-12).
- **yt-dlp core is pure Python with zero mandatory dependencies** (`dependencies = []`). Its `pyproject.toml` already excludes `brotli` on iOS, so the maintainers anticipate iOS use. None of the C-extension optionals (`brotli`, `pycryptodomex`, `curl_cffi`) are required for a progressive MP4.
- **X's extractor exposes progressive `http-*` MP4 formats** that need no ffmpeg, and works **without login** for ordinary public videos via a guest token.
- **`ssl` works** (real OpenSSL 3.5 in the BeeWare build). The single hard gotcha — embedded Python has no system CA trust store — is fixed by bundling **`certifi`** and pointing the SSL context at it.
- **Prior art:** `a-Shell` runs yt-dlp on iOS today; `kewlbear/YoutubeDL-iOS` is a direct precedent for embedding the yt-dlp Python module in a native iOS app.

### Known constraints we design around

- **No `subprocess` / `fork` / `multiprocessing`** on iOS Python → yt-dlp post-processors that shell out (ffmpeg) cannot run. Reinforces deferring ffmpeg and doing the transfer natively.
- **No background execution for blocking Python** → the transfer must be `URLSession` (supports background sessions).
- **App bundle ~35–50 MB** from embedded CPython + stdlib. Acceptable for a build-from-source app.
- **Binary stdlib modules must be repackaged as signed frameworks** (handled by Python-Apple-support's "process libraries" run-script phase). OpenSSL requires a Privacy Manifest (`openssl.xcprivacy`).

---

## 3. Architecture & components

**Bundled into the app:** `Python.xcframework` (Python-Apple-support) · the Python standard library · the `yt-dlp` package · a `certifi` CA bundle.

**Build CPython without the unneeded C-extension optionals** (`brotli`, `pycryptodomex`, `curl_cffi`); ensure `ssl` (and ideally `sqlite3`, for a later cookies path) are present.

| Component | Responsibility | Depends on |
|---|---|---|
| `PythonRuntime` | Owns interpreter lifecycle: initialize once via the CPython C-API (`PyConfig`), set `PYTHONHOME`/`sys.path` to the bundled stdlib + yt-dlp, point the SSL context at the bundled `certifi` cert. The **only** component aware Python exists. | Python.xcframework |
| `Extractor` (an `actor`) | Public API `func resolve(_ url: URL) async throws -> ResolvedMedia`. Calls yt-dlp `extract_info(url, download=False)` with a progressive-single-file format selector and **no post-processors**, maps Python exceptions to `KeraunosError`. | `PythonRuntime` |
| `Downloader` | Native `URLSession` (background-capable) transfer of `ResolvedMedia.directURL` to a destination, with progress and cancellation. No Python. | Foundation |
| `DownloadStore` | Destination in the app's Documents dir, file naming, listing finished downloads. | Foundation |
| SwiftUI view + view model | One screen: URL field, Download button, progress bar, list of saved files. | `Extractor`, `Downloader`, `DownloadStore` |

`ResolvedMedia` = `{ directURL: URL, suggestedFilename: String, title: String }`.

**Boundary rationale:** `PythonRuntime` is the sole holder of Python knowledge; everything above speaks pure Swift. The GIL means all Python calls funnel through the single `Extractor` actor (serialized, off the main thread; wrap call sites in `PyGILState_Ensure/Release`). Swapping `Extractor` to a backend implementation would leave `Downloader`, `DownloadStore`, and the UI untouched.

> **Bridge note:** initialization uses the CPython C-API (the officially documented, most robust path). PythonKit may be layered on for call-site ergonomics, but is community-maintained (issues disabled, no official iOS support) — it is a convenience, not a foundation.

---

## 4. Data flow (Milestone 1)

```
User pastes URL → taps Download
   │
   ▼
Extractor.resolve(url)                      ← actor, off main thread, GIL-guarded
   │  PythonRuntime.ensureReady()           ← idempotent init: sys.path + SSL/certifi
   │  yt-dlp extract_info(url, download=False)
   │     • format: best single progressive file (video+audio in one stream)
   │     • no post-processors
   ▼
ResolvedMedia { directURL, suggestedFilename, title }
   │
   ▼
Downloader.download(resolved, to: <Documents>/<name>.mp4)   ← native URLSession
   │     • native progress → UI (MainActor)
   │     • background-session capable, cancellable
   ▼
file URL → DownloadStore records it → UI lists it / visible in Files app
```

Only the (small) extraction HTTP calls go through Python's networking; the large media transfer is native.

---

## 5. Error handling

Python exceptions are caught at the `Extractor` boundary and mapped to a Swift `KeraunosError` enum — nothing above sees a Python object.

| Condition | Signal | `KeraunosError` | User-facing message |
|---|---|---|---|
| Site/URL unsupported | `UnsupportedError` / `ExtractorError` | `.unsupported` | "This link isn't supported." |
| Only HLS / separate streams (needs ffmpeg) | no progressive format matches | `.needsFfmpeg` | "This video needs format-merging support, coming in a later version." |
| Sensitive / age-gated (X) | extractor requires auth | `.requiresAuth` | "This video requires sign-in (cookies), not yet supported." |
| Network / timeout (extraction or transfer) | `DownloadError` / `URLError` | `.network` | "Download failed — check your connection." |
| Interpreter / SSL init failure | C-API / `ssl` error | `.runtime(detail:)` | Diagnostic (this is a bug, not user error). |
| User cancels | task / `URLSession` cancellation | `.cancelled` | (silent) |

The `.needsFfmpeg` and `.requiresAuth` cases keep the deferrals honest: HLS-only and sensitive X posts fail with a clear explanation rather than cryptically.

---

## 6. Testing strategy

- **Pure-Swift unit tests (no Python):** format-selector string builder, output-path/filename logic, and Python-exception → `KeraunosError` mapping. Written first (TDD).
- **`Downloader` unit/integration tests:** point `URLSession` at a localhost HTTP server serving a small sample `.mp4`; assert bytes land correctly, progress fires, cancellation works. No network, no real sites.
- **`Extractor` integration test (simulator):** resolve a direct/generic URL served from localhost (yt-dlp's generic extractor) and assert the returned `ResolvedMedia.directURL`. Avoids real-site flakiness and ToS concerns.
- **Manual acceptance:** one public X post with a progressive MP4 → downloads and plays; one HLS-only post → surfaces `.needsFfmpeg` cleanly.

---

## 7. Milestone 1 — definition of done

1. App builds and launches with embedded Python (xcframework + stdlib + yt-dlp + certifi), SSL verified working against an HTTPS host.
2. Single SwiftUI screen: URL field, Download button, progress bar, list of saved files.
3. Paste a public progressive-MP4 URL (incl. a qualifying X post) → `Extractor` resolves it → `Downloader` saves the `.mp4` to the app's Documents folder → visible in the Files app.
4. Errors surface clearly via `KeraunosError`, especially `.needsFfmpeg` and `.requiresAuth`.
5. Unit tests (selector / path / error-mapping) + the localhost `Downloader` and `Extractor` integration tests are green.

### Explicitly NOT in Milestone 1

ffmpeg / HLS / merging · Share Sheet extension · format/quality picker · download queue & history · audio-only extraction · cookies/auth. All tracked on the roadmap for later.

---

## 8. Risks & mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Python-Apple-support + C-API setup friction (sys.path, SSL certs, framework signing) | Medium | `PythonRuntime` owns these explicitly; start from the CPython iOS `testbed` Xcode project and Python-Apple-support `USAGE.md`. |
| X guest-token flakiness / intermittent 403s | Medium | Retry logic in `Extractor`; clear `.network` messaging. |
| On-device packaging proves unworkable | Low | `Extractor` boundary allows dropping in the backend fallback without UI/Downloader changes. |
| Bundle size / signing of binary stdlib modules | Low | Use the official "process libraries" run-script phase; add `openssl.xcprivacy`. |

---

## 9. References

- PEP 730 (iOS as a CPython platform); docs.python.org "Using Python on iOS"; CPython `Apple/testbed`.
- BeeWare Python-Apple-support (repo + `USAGE.md`); Python-Apple-support issue #119 (CA-store gotcha + certifi fix).
- yt-dlp `pyproject.toml`, `README` §DEPENDENCIES, `yt_dlp/networking/__init__.py`, `yt_dlp/extractor/twitter.py`.
- Prior art: `kewlbear/YoutubeDL-iOS`; `a-Shell` running yt-dlp.
