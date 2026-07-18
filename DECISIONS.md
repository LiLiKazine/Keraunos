# UI rebuild — decision log

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
