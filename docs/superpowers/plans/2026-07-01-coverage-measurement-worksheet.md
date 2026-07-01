# Coverage measurement worksheet (Phase 3 + Phase 3.5 SABR spike)

> Run on a **real device** against the live 7 sites. This is the owner-manual half of
> Phase 3 (roadmap) plus the Phase 3.5 SABR spike. Fill in the tables, then the
> "Verdict → decisions" section tells us what to build next (esp. Phase 4 go/no-go).
> Source of truth for strategy: `coverage-roadmap` memory + `2026-06-22-phase-3.5-sabr-spike.md`.

## How to read an outcome

- **PASS** = after paste/share, the download finishes and the file appears in the list
  and **previews/plays** (QuickLook). Open it — confirm it actually has video + audio.
- **FAIL** = an error message shows. The app also appends a line to the on-device
  **failure log** (`failures.log`): `timestamp <tab> errorKind <tab> url <tab> detail`.
  Export it via the failure-log **Share** button and paste the relevant lines below.
- The **errorKind** is the key datum on a failure. Known kinds:
  `requires_auth`, `unavailable`, `rate_limited`, `restricted_or_empty`, `needs_ffmpeg`,
  `unsupported`, `extract_network`, `download_network`, `runtime`.
- For each PASS, if you can, note the **resolved container/codec** (e.g. mp4 H.264+AAC,
  webm VP9, mkv AV1) — it tells us whether the codec-regex fix is doing its job.

## Part A — the 7 sites (one representative public URL each)

Pick a normal, public, non-age-gated post per site. For YouTube also keep a **>1080p**
video handy for Part B. Test both a **paste** and a **share-sheet** entry for at least
one site to confirm both paths.

| # | Site | Pick a URL that is… | Expectation (per roadmap) | Result | Codec / errorKind | Notes |
|---|------|--------------------|---------------------------|--------|-------------------|-------|
| 1 | **YouTube** | a normal ≤1080p video | PASS (PoT/nsig via JS bridge) | ⬜ | | |
| 2 | **Twitter / X** | a tweet with a native video | PASS ≤720p; >720p is MPEG-TS (deferred) | ⬜ | | |
| 3 | **Reddit** | a v.redd.it post | PASS — **codec-regex fix target** | ⬜ | | |
| 4 | **Bilibili** | a standard video (H.264) | PASS — **codec-regex fix target** | ⬜ | | |
| 5 | **RedNote (Xiaohongshu)** | a video note | PASS — **codec-regex fix target**; may serve http:// mp4 | ⬜ | | |
| 6 | **Instagram** | a public reel/post | PASS **only if signed in** (needs cookies) — else `requires_auth` | ⬜ | | |
| 7 | **TikTok / Douyin** | a public video | PASS | ⬜ | | |

**Auth note (site 6):** if Instagram fails with `requires_auth`, sign in via the app's
login WebView first (that's the Safari-UA path we just fixed), then retry. Record whether
sign-in → retry flips it to PASS.

### Failure-log excerpts (paste here)
```
(paste the relevant failures.log lines)
```

## Part B — SABR spike (decides Phase 4: libav / >1080p)

**Binary question:** for a known **>1080p** YouTube video, forcing the **web** client,
does the >1080p VP9/AV1 format come back as a **fetchable URL** or is it **SABR-only**?

**Temporary edits (do NOT commit — revert after):**
1. `keraunos_extract.py::_extract_impl` — force the web client:
   ```python
   "extractor_args": {"youtube": {"player_client": ["web"]}},
   ```
2. Same file — dump all formats instead of filtering:
   ```python
   _FORMAT = "bestvideo+bestaudio/best"   # spike only
   ```
   (or set `opts["listformats"] = True` and read the table from stderr).
3. Resolve the >1080p video. Read the verdict from stderr:
   - **SABR-only (FAIL):** warning *"…missing a url. YouTube is forcing SABR streaming
     for this client."* **and** no >1080p VP9/AV1 format appears.
   - **Fetchable (PASS):** a >1080p VP9/AV1 format is present with a real `url` and
     `protocol` ∈ {`https`, `http_dash_segments`}. **Also note single-file vs fragmented**
     (`&sq=N` segments = fragmented → effectively FAIL for our single-GET transfer unless
     it exposes one complete `BaseURL`).
4. **Revert both edits.**

**One-line result:**
```
YouTube >1080p web-client: [ FETCHABLE(single-file) | FETCHABLE(fragmented) | SABR-ONLY ]
```

## Verdict → decisions

- **Any of sites 3/4/5 FAIL** → the codec-regex fix regressed or is incomplete; that's a
  concrete, loop-doable bug to fix next (highest priority — it's the cheap win).
- **Instagram PASS only after sign-in** → expected; document it as the supported flow.
- **SABR = FETCHABLE(single-file)** → **Phase 4 is justified** for YouTube + Bilibili AV1.
  Start the libav bundle.
- **SABR = FETCHABLE(fragmented)** → YouTube >1080p needs fragment assembly (CUT) → Phase 4
  helps **Bilibili AV1 only**; decide if one site is worth the libav maintenance cost.
- **SABR = SABR-ONLY** → YouTube >1080p is off the table regardless of libav → Phase 4
  justifies itself on **Bilibili AV1 only** → likely **not worth it**; close Phase 4.
