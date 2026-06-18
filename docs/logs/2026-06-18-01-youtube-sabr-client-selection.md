# 2026-06-18-01: On-device YouTube — SABR blocker and the PO-token red herring

**Status:** Implemented

## Context

The on-device YouTube milestone's remaining piece was Task 9: minting a GVS PO token via
the full BotGuard flow in JavaScriptCore (the assumption being that a missing PO token was
why signed-in YouTube downloads failed). The flow was designed (approach A: decompose +
Python HTTP + `snapshotSynchronous`) and implemented behind a graceful-degradation ladder.

On a real device (the only viable test bed — the simulator/Mac IP is bot-flagged), a
signed-in YouTube Short still failed with "Download failed — check your connection."
Systematic debugging was needed because that message is the catch-all `.network` mapping
and hid the real error.

## Options

| Approach | Pros | Cons |
|----------|------|------|
| Finish/perfect the BotGuard PO flow (Task 9) | Completes the planned spike | The PO provider was never invoked for the failing format — would not fix the download |
| Implement SABR streaming (consume YouTube's protocol) | "Correct" long-term answer | Weeks-scale; needs protobuf/UMP + PO tokens; breaks the "Python resolves a URL, Swift downloads it" design; pinned yt-dlp has no SABR downloader |
| Switch player clients (chosen) | One config change; mirrors yt-dlp's own default strategy; no PO token, no SABR, no ffmpeg | Client roster is a moving target; some clients return HLS/VP9 the app can't use |

## Decision

Restrict YouTube extraction to non-web player clients that need no GVS PO token and aren't
SABR/HLS-only — `extractor_args={'youtube': {'player_client': ['tv', 'tv_embedded', 'android_vr']}}`.

## Rationale

Evidence gathered on-device (by temporarily routing yt-dlp's logs + the result detail onto
the result JSON, since embedded Python stderr is invisible there):

- Extraction *succeeded*; the **download** of the resolved `googlevideo` URL returned **403**.
- yt-dlp warned: *"YouTube is forcing SABR streaming for this client"* (issue #12482) — the
  **web** client's adaptive formats lost their plain URLs, leaving only the 403-gated
  progressive `itag 18`, which our format selector then picked.
- The **PO provider was never invoked** (no `pot:` lines, no "missing GVS PO Token" warning),
  so the PO token was not the blocker.

Reading the pinned yt-dlp's client roster (`extractor/youtube/_base.py`) showed `tv` has **no**
`GVS_PO_TOKEN_POLICY` (needs no PO token) and returns direct H.264+AAC. `tv`-only hit
*"The page needs to be reloaded"*, so a **set** (`tv`, `tv_embedded`, `android_vr`) is used so
yt-dlp can skip a failing client and merge formats from the rest. Confirmed downloading a
signed-in Short on a real device.

## What Changed

- `keraunos_extract.py`: added `extractor_args` (the non-web client set) and `cachedir`
  (→ `tmp/yt-dlp-cache`) to the yt-dlp options.
- `keraunos_youtube_pot.py`: implemented the approach-A full BotGuard flow (`_waa_post`,
  `_snapshot_snippet`, `_mint_snippet`, `_full_botguard_token`) behind a full → cold-start →
  reject ladder. Kept as registered, graceful-degrading scaffolding (off-path for `tv`-family).
- `test_pot_provider.py`: full-flow payload/return test + cold-start-fallback test.
- Spec + plan: recorded the on-device outcome; the A-vs-C async-bridging decision is deferred
  (not needed for current YouTube support).

## What Was Discovered

- **The PO token was a red herring** for this failure. The real blocker is YouTube's SABR
  enforcement on the **web** client + a format selector that preferred web's 403-gated
  progressive `itag 18`.
- **`.network` hides the real error.** The Swift downloader maps every non-2xx (incl. 403)
  to `.network` ("check your connection"); the underlying detail had to be surfaced explicitly.
- **Embedded Python stderr is invisible on-device** — only `NSLog`/os_log from Swift shows.
  Diagnostics had to ride out on the extraction-result JSON, and os_log truncates ~1 KB, so
  diagnostics had to be placed *before* the long media URL.
- **iOS sandbox isn't `~/.cache`-writable** (only `Documents/`, `Library/`, `tmp/`). yt-dlp's
  cache write failed every run, recomputing nsig and contributing to intermittent 30s watchdog
  timeouts. Fixed via `cachedir` → `tmp`.
- **`tv`-only fails** with "The page needs to be reloaded"; a multi-client set is required.
- **Files-app visibility** was already configured (`UIFileSharingEnabled` +
  `LSSupportsOpeningDocumentsInPlace`); the folder appears under *On My iPhone → Keraunos*
  once `Documents/` is non-empty — no code change needed.
- **Follow-up:** the client roster is a moving target; if `tv`-family clients later require a
  PO token, the BotGuard scaffolding is ready and the A-vs-C decision resumes.
