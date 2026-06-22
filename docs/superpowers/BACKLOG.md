# Keraunos Backlog — autonomous-loop state

> **This file is the loop's working memory.** The PM reads it at the start of every
> cycle to orient, and updates it at the end (done / next / learned). It is the bridge
> across context resets — keep it current and terse.
>
> Source-of-truth for *strategy* remains the coverage-roadmap memory + the plans in
> `docs/superpowers/plans/`. This file tracks *executable state* against them.

Last updated: 2026-06-22 (cycle 3). Git policy: commit verified increments straight to
`main`. Verify gate: full build + Swift Testing suite on the iPhone 17 simulator.

---

## ⛔ The loop's hard boundary (do NOT burn cycles here)

A build-from-source downloader cannot responsibly do these from an unattended loop.
They are **owner-manual** — log them, don't attempt them:

- **On-device / live-site runs.** Anything that needs the running app, the
  JavaScriptCore bridge (PoT/nsig), or hitting the 7 real sites. This includes the
  whole live half of Phase 3, the Phase 3.5 SABR spike, and any "verify against live
  X" step. Integration tests stay **localhost-only**.
- **Xcode project surgery requiring signing/targets.** Adding the Share Extension
  target, registering the `keraunos://` URL scheme, anything touching entitlements or
  the dev team. Hand-editing `project.pbxproj` for new targets is too risky.

If the next-best roadmap item is one of these, record it and **pivot to code-level
work below** instead of stalling.

---

## Roadmap status (against the coverage roadmap)

- **Phase 1 — Codec-regex fix** ✅ DONE (`1db9df0`). Localhost fixtures only; live
  confirm is owner-manual.
- **Phase 2 — Instagram cookies** ✅ DONE (`90f60dd`). Was already-working; regression
  guard added. Live confirm is owner-manual.
- **Phase 3 — Measure + local failure log** ⏳ Code done (`fdc6d28`, `472db28`):
  `network` split into `extract_network`/`download_network`; on-device `FailureLog`
  automated. **Remaining half is owner-manual** (run 7 URLs on-device).
- **Phase 3.5 — SABR spike** ⛔ Owner-manual (on-device, live YouTube). Procedure ready
  in `2026-06-22-phase-3.5-sabr-spike.md`. **GATES Phase 4.**
- **Phase 4 — >1080p libav bundle** 🔒 Blocked on Phase 3.5 verdict. NOTE: step 5
  (Downloader delegate rewrite) is independently loop-doable — see below.
- **Share-into-Keraunos** ⏳ App-side receiving logic DONE + tested. Remaining = URL
  scheme registration + Share Extension target, both **owner-manual**.

---

## ▶ Loop-doable work (code-level, localhost/unit-testable, TDD)

The PM picks the highest-value item each cycle and may re-rank or add ideas. Roughly
ordered by leverage for a 7-site personal tool:

1. ~~**Downloader delegate rewrite.**~~ ✅ DONE (pre-loop). `Downloader.swift` already
   uses `session.download(for:delegate:)` + `DownloadProgressDelegate` for byte-progress
   (`DownloadProgressDelegateTests` cover it). **Remaining**: background-configuration
   transfer + resume-data — both need a real app/background env (not localhost-unit-
   testable) → treat as **owner-manual / lower priority**, not a clean loop item.
2. ~~**Error-mapping completeness (slice 1).**~~ ✅ DONE (cycle 2). Added `unavailable`
   (removed/private/geo → not retryable) and `rate_limited` (HTTP 429 → retryable, "wait"
   message) end-to-end; was collapsing into `unsupported`/`extract_network`. **Next
   slices if wanted**: age-gate as its own kind (currently → requires_auth, arguably
   fine), `members_only`/paid, live-not-started/premiere.
3. **Format-selector edge cases.** More `test_extract.py` fixtures: m3u8-only results,
   audio-less video, DRM-flagged formats, duplicate-resolution tie-breaks. Harden the
   selector against the long tail *within* the 7 sites.
4. **Filename / path safety.** Stress the filename/path builder: unicode, emoji,
   path-separator injection, over-length names, collisions with existing files. Pure
   Swift, pure TDD.
5. **Download queue / concurrency.** Actor-based queue for multiple simultaneous
   downloads (cancel, retry, dedupe in-flight URLs). Aligns with the actors-over-locks
   house rule.
6. **FailureLog hardening.** ✅ Size cap/rotation, clear-log, and (cycle 3) **redaction
   of secret-bearing query params** in both url + detail all DONE. Nothing left here
   unless a new need appears.
7. **Retry/backoff policy.** The auto-retry logic (commits `01b94ad`, `d3b837d`) is
   ad-hoc. Extract a tested backoff policy type; cover transient vs terminal
   classification.
8. **Cookie store robustness.** Expiry handling, per-host isolation, Netscape-export
   round-trip edge cases (`CookieStore`/`NetscapeCookieWriter`).
9. **SwiftUI polish (lower priority).** Accessibility labels, dynamic-type, empty/error
   states. Verifiable via build + UI test target.

---

## 📝 Learnings / notes (append as the loop discovers things)

- **Python tests run via the in-repo venv**, not Xcode's python3 (no pytest there):
  `cd app/Keraunos/python-dev && .venv/bin/python -m pytest test_extract.py -q`.
  These are NOT part of the xcodebuild gate — run them separately for Python changes.
- **`KeraunosError` mapping contract lives in two places that must stay in sync**: the
  Python `error_kind` slug strings (`keraunos_extract.py`) and the Swift `init(errorKind:)`
  / `kind` round-trip (`KeraunosError.swift`). `KeraunosErrorTests` asserts the round-trip;
  add new kinds to BOTH the slug list and the `everyCaseHasAUserMessage` array.
- **Error-classification ordering matters** in `_extract_impl`'s except block: auth
  checks (hints + 401/403/412) come first so a private-video "sign in" message routes to
  `requires_auth`; rate_limit before the network bucket (429 messages also say "unable to
  download"); unavailable before the final `unsupported` fallback.
- **Simulator flake**: `xcodebuild test` intermittently dies with "Invalid device state /
  Mach error -308 / server died" on the UI-test runner (`testExample`). Not a code
  failure — `xcrun simctl shutdown all` then re-run clears it. Don't deep-debug it.
- **BACKLOG #1 (delegate progress) was already shipped before the loop started** — the
  roadmap/BACKLOG was stale. Always read the actual source before picking the "top" item.
- **KeraunosCore is a SwiftPM package** — subagents verify Swift fast via
  `cd app/KeraunosCore && swift test` (compiles + runs the core suite standalone, ~0.2s)
  without the slow simulator. The PM still runs the full `xcodebuild` sim gate to commit.
- **`No such module 'Testing'` SourceKit diagnostic** on test files is an editor-index
  artifact (the package index isn't loaded); ignore it — `swift test`/xcodebuild compile
  the Testing module fine.
- **DownloadStore.sanitizedFilename is already hardened** (path-sep/colon/control-char →
  `_`, `..` can't escape, 255-byte UTF-8 cap, collision uniquing) — BACKLOG #4 is
  effectively done; don't re-spend a cycle there without a concrete new gap.
