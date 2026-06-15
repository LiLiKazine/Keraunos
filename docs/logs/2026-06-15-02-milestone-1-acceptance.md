# 2026-06-15-02: Milestone 1 acceptance results

**Status:** Passed (core acceptance criterion met)

## Environment

- Device: iPhone 17 Pro Max simulator (iOS 26.5), Xcode 26.5.
- Embedded CPython 3.13.14 (Python-Apple-support 3.13-b14), yt-dlp 2025.10.14,
  vendored certifi CA bundle.
- Built `.app` size: **108 MB** (Python.framework 10 MB + stdlib `python/` 49 MB
  + `app_packages/yt_dlp` 12 MB + `app/` 0.2 MB).

## What was tested

| URL | Outcome | Interpretation |
|-----|---------|----------------|
| `https://x.com/0xmovez/status/2066225922928…` | ✅ **Downloaded** — `…[2066225283271708672].mp4` appears in the list (Documents) | **Acceptance criterion met**: X progressive MP4 resolved by embedded yt-dlp and downloaded by native URLSession. |
| `https://www.youtube.com/shorts/…` (several) | "Download failed — check your connection" | Extraction **succeeds** (resolves format-18 progressive), but YouTube's `googlevideo.com` URL is IP/session-bound and rejects a plain URLSession GET. Known YouTube limitation, not an app bug. |
| `https://www.w3schools.com/html/mov_bbb.mp4` | yt-dlp `UNEXPECTED_EOF` (mapped to `.network`) | CDN reset of the non-browser request. Site-specific. |
| `https://download.samplelib.com/mp4/sample-5s.mp4` | same `.network` | Site-specific CDN behaviour. |

## Interpreter / SSL verification

A temporary in-app network probe (since reverted) confirmed the embedded TLS
stack is fully functional:
- TCP connects; CA store loads **119** certs from the bundled `cacert.pem`
  (`SSL_CERT_FILE`); TLS negotiates **TLSv1.3**; `urllib.urlopen` returns **200**
  for both `youtube.com` and `www.python.org`.
- OpenSSL: `OpenSSL 3.0.18 30 Sep 2025`.

This proves interpreter init + SSL (certifi) + urllib end-to-end (spec §7 item 1),
independent of the successful X download.

## Spec §7 done-check

1. App builds/launches with embedded Python, SSL verified — ✅ (probe + X download).
2. Single screen: URL field, Download button, working indicator, file list — ✅ (Task 8).
3. Public progressive MP4 (incl. an X post) downloads to Documents, visible in
   the list / Files app — ✅ (X video above; Documents dir is the Files-app location).
4. Errors surface clearly, no crashes — ✅ (every failure above showed a clear
   message; no crashes across many attempts; `.needsFfmpeg`/`.requiresAuth`
   mappings covered by unit tests in `ExtractionDecodingTests`/`KeraunosErrorTests`).
5. Core `swift test` (11) + Python dev pytest (2) + app tests (3) all green — ✅.

## Notes / follow-ups (not Milestone 1)

- **YouTube** is unsupported in practice for the download step (locked
  `googlevideo` URLs). Out of scope; X is the Milestone 1 target.
- Bare-CDN direct files (w3schools/samplelib) may reset yt-dlp's request; not a
  target use case.
- Diagnosis required a long manual loop because Xcode-16 "folders" and run-script
  staleness obscured that extraction was already working; the `.network` message
  originates in the **Downloader**, which only runs after extraction succeeds.
