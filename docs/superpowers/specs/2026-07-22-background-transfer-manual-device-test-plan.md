# Background Transfer — Manual Device Test Plan & De-Risk Spikes

**Date:** 2026-07-22
**Status:** Committed artifact (the un-automatable safety net).
**Companion to:** `docs/superpowers/specs/2026-07-21-background-transfer-design.md` ("Error handling → coverage is layered"; phasing step 7).

Background-transfer's riskiest behaviors — system termination of a suspended app,
discretionary/wake-rationed scheduling, locked-device transfer, resolved-URL expiry — **cannot
be hit by `swift test` or reliably reproduced in the simulator**. The core logic is covered by
`swift test` (Phases 1/2/4-core/5); the app-integration layer is covered by simulator+localhost
tests (Phase 3). This document is the committed safety net for everything below that line: the
OS behaviors nothing can fake. Run it on a **real device** before shipping any change that
touches the transfer engine, the session delegate, or the app-delegate relaunch glue.

> Use the **chaos flag** (below) to trigger recovery paths on demand instead of waiting for
> nature. Each checklist item names the chaos toggle that forces it, where one exists.

---

## Pre-flight

- Real device (not simulator), signed dev build, cellular + Wi-Fi both available.
- A YouTube 4K source (adaptive video+audio, both googlevideo/chunked) — the headline case.
- A large progressive source (single-shot) — the non-chunked case.
- An authenticated source requiring sign-in — exercises `credentialRef` + Keychain.
- Console.app (or Xcode device console) attached to watch transfer lifecycle logs.

---

## Checklist — run each, assert the stated outcome

### A. Suspension & background progress
1. **Start 4K adaptive → background the app immediately.** Assert: transfer continues while
   suspended; returns foregrounded showing advanced progress (not frozen at the value it had
   when backgrounded). *(Validates `isDiscretionary = false`, `sessionSendsLaunchEvents = true`.)*
2. **Start → lock the device.** Assert: transfer proceeds locked; any Keychain auth read
   succeeds on the locked device *(validates `kSecAttrAccessibleAfterFirstUnlock`)*.
3. **Observe background chunk cadence** on a large chunked file left suspended. Assert: it makes
   forward progress across chunk boundaries (wakes are rationed but not stalled forever); note
   throughput for the S1 spike (below).

### B. Termination & relaunch (the highest-risk path)
4. **Start 4K → background → kill from the app switcher.** Relaunch. Assert: the job rehydrates
   from `transfers.json`, `getAllTasks()` reassociation rebinds any surviving task, and a
   vanished task resumes from `bytesWritten` (chunked) / `resumeData` (single-shot). The
   part file is **not** re-downloaded from zero.
5. **Kill mid-chunk, relaunch.** Assert: the part file is truncated to the persisted
   `bytesWritten` (at most one chunk re-downloaded), never corrupted/double-appended.
   *(Chaos: `--chaos-kill-after-chunk`.)*
6. **Force a completion event to arrive before routing** (relaunch with a `didFinishDownloadingTo`
   pending). Assert: the delegate stages the temp file synchronously and no bytes are lost even
   though the job map isn't wired yet. *(Validates launch-ordering + synchronous stage-out.)*

### C. Interruption & resume
7. **Toggle airplane mode mid-chunk.** Assert: task fails, job stays `.downloading` with intact
   `bytesWritten`; on reachability/next launch it auto-resumes from the offset.
   *(Chaos: `--chaos-random-task-failure`.)*
8. **Pause then resume** (chunked): assert it stops enqueueing after the current chunk and
   resumes cleanly from `bytesWritten`. **Pause then resume** (single-shot): assert
   cancel-with-`resumeData` then resume from that data. *(Chaos: `--chaos-drop-resume-data`
   to confirm the single-shot fallback restarts rather than corrupts.)*

### D. Expiry & auth refresh
9. **Let a resolved URL expire** (leave a job deferred past `expire=`), then foreground. Assert:
   job shows **Refreshing**, foreground re-extraction re-selects the **same** `formatSelection`,
   and — matching `Content-Length` — resumes from offset; mismatched length restarts that track.
   *(Chaos: `--chaos-force-403` / `--chaos-force-expiry`.)*
10. **Expired auth cookies** → assert the same `403` → `.needsRefresh` → **Needs sign-in** →
    re-auth → resume (one recovery path covers URL + credential expiry).
11. **Re-extraction that can't re-select the format** → assert `.failed(refreshFailed)`, retryable
    from the list.

### E. Merge & finalize
12. **4K adaptive completes → merge.** Assert: pre-merge integrity check passes; on a
    background-launch window the immediate merge usually loses the race and **falls back** to
    foreground, completing on next activation (remaining `.readyToMerge` in between). Small file:
    assert the immediate branch completes without a reopen. *(Gated by S2 — see below.)*
13. **Truncated/short part** → assert `.failed(integrityCheckFailed)` (loud), not an opaque
    merge error.
14. **Fill the disk, then complete a large adaptive job** → assert `.failed(insufficientSpace)`
    with a "needs X" message before any ENOSPC mid-write.
15. **`autoSaveToPhotos` job** → assert it lands in Photos (compatible container) after
    `.completed`, and the "Saved to Library" toast appears (coalescing on multiple).

### F. Orphan GC & housekeeping
16. **Crash between cancel and cleanup** (leave a part with no owning job) → relaunch → assert
    `reconcileOrphanParts()` deletes it. *(Chaos: `--chaos-orphan-part`.)*

---

## De-risk spikes (throwaway, gate the phases that depend on them)

These are **not** shipping code — they are one-off device probes whose *output is a decision*.

### S1 — Background chunk size (gates Phase 2 scheduling params / Phase 3 driver tuning)
- **Question:** the largest HTTP `Range` googlevideo serves without re-triggering the
  unranged-GET throttle, so we minimize the wake count (chunk *count*, not size, is the cost).
- **Method:** on-device, issue increasing ranged GETs against a live googlevideo URL; record the
  point where throughput collapses to the throttled rate.
- **Output:** the background chunk size constant + confirmation large ranges don't behave like an
  unranged GET. Until measured, the engine uses the yt-dlp hinted size as a conservative floor.

### S2 — Background-launch merge & Photos (gates Phase 4-glue)
- **Question:** can `AVAssetExportSession` (merge) and `PHPhotoLibrary.performChanges` (Photos)
  run reliably during a `URLSession` background-launch window?
- **Method:** trigger a completion→merge during a real background-launch; observe whether the
  export/Photos write completes or is killed.
- **Output:** **keep** the "try-immediately" merge branch, or **drop** it and always defer to
  foreground (behavior-equivalent minus the wasted attempt).

---

## Chaos flag (debug-only)

A debug switch in the transfer driver that injects failure modes so device runs can trigger
recovery paths on demand rather than waiting for nature. **Never compiled into release.**

| Toggle | Effect | Exercises checklist item |
|--------|--------|--------------------------|
| `--chaos-force-403` | next chunk response → `403` | D9, D10 |
| `--chaos-force-expiry` | treat the current URL as already past `expire=` | D9 |
| `--chaos-random-task-failure` | fail a task at a random offset | C7 |
| `--chaos-drop-resume-data` | discard single-shot `resumeData` on cancel | C8 |
| `--chaos-kill-after-chunk` | write an un-recorded tail, then hard-exit | B5 |
| `--chaos-orphan-part` | leave a part file with no owning job | F16 |

Implementation lands with the Phase 3 driver (the flag needs a real task to perturb); this table
is the contract the driver implements.
