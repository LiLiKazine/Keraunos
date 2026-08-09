# UI rebuild — decision log

> Historical log above/below may cover earlier branches. The active test-harness work is
> tracked in the section appended at the end of this file.

Branch: `ui/production-refined-native`. Goal: replace the throwaway PoC SwiftUI with
the locked "Refined Native" (dark) production design, wired to the existing view models.
Behavior stays; only the UI is rebuilt.

## Done-criteria (definition of done for the whole goal)
- [ ] Theme layer: color tokens, spacing, radius, type styles.
- [ ] Shared components: buttons, link-paste input, progress card, quality chip/row,
      download row, empty-state, toast, notice card.
- [ ] Screens rebuilt & wired: Home, Library (+ iPad detail/player), Accounts, Settings,
      Quality picker, plus empty/error/sign-in states and confirm toasts / delete sheet.
- [ ] Adaptive shell: TabView (compact) ↔ NavigationSplitView (regular) by size class.
- [ ] Build green (iPhone 17 sim) + full test suite green + a whole-branch review clean.

## Hard-stop allowlist for this task
Nothing task-specific beyond the standard list (no prod/release, no new worktree, no
irreversible actions). This is a build-from-source personal app; no external comms.

---

## [checkpoint 1] Theme layer + Home screen
- **Workspace:** feature branch `ui/production-refined-native` in the *current* worktree
  off `origin/main`. Did not create a new worktree (escalation rule).
  Reversible: yes. Confidence: high.
- **oklch → sRGB baked once:** SwiftUI has no oklch initializer, so tokens are converted
  to sRGB in `Theme/Palette.swift` with the source oklch kept in comments. Alternative
  (asset catalog) rejected: harder to review/diff, same result.
  Reversible: yes (single file). Confidence: high.
- **`bolt.fill` SF Symbol as the brand mark** instead of the design's custom bolt polygon
  — constraint says system font/symbols only; the SVG bolt has no SwiftUI equivalent
  without shipping a custom path/asset. Reversible: yes. Confidence: high.
- **Row actions via `.contextMenu`, not swipe:** the design's Recent list is a custom
  hairline-separated list in a `ScrollView`; `.swipeActions` requires a `List`, which
  fights the design. Context menu preserves Delete / Share / Save-to-Photos (long-press)
  and tap-to-play. Delete-confirm + toasts come with the Feedback step.
  Reversible: yes. Confidence: medium — will revisit when the Feedback board lands.
- **Gear → minimal `SettingsView` stub now:** carries the diagnostics (failure-log
  share/clear) affordance that used to live on the PoC Home Form, so that behavior isn't
  lost before the full Settings screen is built. Reversible: yes. Confidence: high.
- **Quality picker kept as `confirmationDialog` for now** (behavior preserved); the
  chip-based sheet/dialog from the QualityPicker board is a later step.
  Reversible: yes. Confidence: high.
- **Deleted `DownloadScreen.swift`; `ContentView` → `HomeScreen`.** The old PoC screen is
  superseded. Reversible: yes (git). Confidence: high.

## [checkpoint 2] Steps 2–4 — components, screens, adaptive shell (user approved "proceed with all of it")
- **Direct sequential implementation (not subagent swarm):** UI fidelity needs the on-sim
  screenshot loop and I hold the design-system context I just authored. SDD spirit executed
  by me, verified per screen. Reversible: yes. Confidence: high.
- **Data honesty over pixel-literal metadata:** boards show duration/resolution/source/
  byte-rate/codec chips per file that the store does not persist. Render only real data
  (filename, size, saved date via file mod-date, file type; quality options use real
  `FormatOption` height/codec/bytes). No fabricated figures. Reversible: yes. Confidence: high.
- **Settings preferences — implement the two that wire to real behavior** (`defaultQuality`
  ask/highest → skips picker & auto-picks best; `autoSaveToPhotos` → saves after a compatible
  download), backed by `Preferences` (UserDefaults) and covered by tests. **Omit "Download
  over Wi-Fi only"** — would require threading URLSession config through `Downloader`/
  `MediaAssembler` in KeraunosCore (out of scope, destabilizing). Theme row is a static
  "Dark" value (app is dark-only). No dead switches shipped. Reversible: yes. Confidence: med.
- **Adaptive shell:** 2-column `NavigationSplitView` (custom sidebar + `NavigationStack`
  detail with system title/toggle) at regular width; `TabView` at compact. Library owns its
  own master-detail (grid + player pane) inside the detail column, so the app shell stays
  2-column. Reversible: yes. Confidence: med — verify on-sim.
- **Row/tile actions:** context menu (long-press) + iPad detail-pane buttons; destructive
  Delete routes through a confirmation dialog; save/complete surface a toast. Reversible: yes.

### [checkpoint 2] Review outcome
Whole-branch review via the code-reviewer agent: no critical/high findings; concurrency
(no GCD, MainActor-correct), force-unwraps (all guarded), and observation/ownership all
confirmed sound. Fixed: iPad Library kept a stale `selected` when its file was deleted
elsewhere (now reconciled via `.onChange(of: savedFiles)`); removed dead code (unused
`saveToPhotosAlert`, unused `ToastCenter` env in `DetailPane`). Left as acceptable judgment
calls: a benign auto-save toast that briefly precedes the "Saved to Photos" toast; a few
intentional design radii as literals; three similar-but-distinct surface-2 input fields.

### Verification (checkpoint 2)
Build green (iPhone 17 + iPad Pro 11"); 42/42 tests pass. Screenshotted on-sim: iPhone
Home (first-run + populated), Library, Accounts, Settings; iPad Download + Library
(grid + player detail). Temporary DEBUG launch hooks used only to screenshot each screen
without UI-automation taps were removed before commit.

### Known tuning items / honest deviations (not blockers)
- iPad 11" **portrait with the sidebar expanded** shows a single Library grid column
  (sidebar 260 + detail 340 leaves a narrow middle); it reflows to 2–3 columns when the
  sidebar is collapsed or on larger/landscape iPads. Acceptable size-class behavior.
- The **quality-picker sheet** is code-verified but not screenshotted live (needs a real
  multi-format extraction from a site, which the localhost/mock path doesn't produce).
- Per-file **duration / resolution / source host / byte-rate** and the Settings **storage
  bar denominator** are not shown — the data model doesn't persist them; we show only real
  values (size, saved date, file type). "Download over Wi-Fi only" omitted (see checkpoint 2).

---

# Domain and component test harnesses — decision log

Branch: `test/domain-component-harnesses`. Goal: establish reusable test harnesses for
each architectural domain and application component before broader feature work.

## Done-criteria
- [x] Core domain harnesses cover transfer construction, persistence, coordination,
      progress, and finalization without simulator dependencies.
- [x] App component harnesses cover extraction/enqueue and queue-presentation behavior
      without the process-wide transfer singleton.
- [x] Background lifecycle and relaunch/finalization boundaries are deterministic and
      exercised by focused tests.
- [x] Core and app test suites pass, simulator build/typecheck passes, and final review
      has no critical or major findings.

## Hard-stop allowlist
Standard irreversible/external actions only: no release, publish, force-push, new
worktree, destructive data operation, or external communication.

## [iteration 1] Harness boundaries before feature expansion
- **Chose behavior-oriented harnesses rather than one mock per production type.** Each
  harness owns a domain aggregate and exposes outcomes (persisted job, requests, progress,
  rendered rows), preventing tests from coupling to incidental call order.
  Alternatives: a global test container (too much shared mutable state), per-test ad hoc
  setup (the duplication this slice is intended to remove).
  Reversible: yes. Confidence: high.
- **Keep Core, app-feature, and lifecycle harnesses in separate test scopes.** This matches
  the real dependency direction and lets Core remain simulator-free.
  Reversible: yes. Confidence: high.
- **Permit the smallest production seam/refactor required for lifecycle tests.** The goal
  is executable harnesses, not test-only replicas of production ordering.
  Reversible: yes. Confidence: high.

## [iteration 2] Crash-safe filesystem and background-event contracts
- **Persist a finalization phase and retain an inode checkpoint until durable job removal.**
  Progressive output advances by hard-link/rename without copying; adaptive output uses one
  deterministic partial/ready stage. Relaunch trusts a destination only when its device/inode
  matches the job-owned checkpoint, so replacements are preserved and recovery neither remuxes
  nor deletes unrelated files. The checkpoint deliberately survives `.completed` Photos work
  and is removed only by `TransferJobStore.remove`.
  Reversible: yes (model field is optional for legacy decoding). Confidence: high.
- **Make every persisted filesystem name an owned, validated component.** Store load/mutation
  rejects traversal, terminal symlinks, duplicate job IDs, and case/Unicode ownership aliases;
  mutations publish only after atomic persistence. Directly enumerated orphan symlinks are
  unlinked without following their targets.
  Reversible: yes. Confidence: high.
- **Serialize background delegate ingress and coalesce progress per task.** Completion/failure
  work and the URLSession drain marker remain lossless FIFO, while high-volume progress keeps
  only the latest pending value. The staging root is validated and stale bodies/symlinks are
  reconciled synchronously before session recreation.
  Reversible: yes. Confidence: high.
- **Bound AVFoundation scratch ownership.** Media-daemon hard links use deterministic job-owned
  names instead of crash-leakable UUID directories; retry, job removal, and orphan reconciliation
  all converge on the same artifacts.
  Reversible: yes. Confidence: high.

### Verification
- Core package: 256 tests across 29 suites passed on macOS.
- App unit target: 66 tests / 68 invocations passed on iPhone 17 simulator.
- iPhone 17 simulator build succeeded; `git diff --check` is clean.
- Final independent closure audits: 0 unresolved Critical, 0 unresolved Major.

### Residual limitations
- Filesystem validation has an unavoidable check-before-I/O race without adopting
  descriptor-relative `openat(..., O_NOFOLLOW)` operations.
- Legacy `.completed` jobs with neither a checkpoint nor recoverable source bytes use structural
  output validation for compatibility; there is no remaining source data that path can destroy.
