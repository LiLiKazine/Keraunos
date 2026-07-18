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

### Deferred to later phases (not regressions to ship — in-progress branch state)
- Bottom tab bar + Library + Accounts screens + iPad `NavigationSplitView` (steps 3–4).
  Until the shell lands, Accounts is reachable only via the in-flow sign-in sheet, not a
  standalone tab. Diagnostics live in the Settings stub.
- Quality-picker chip sheet, toasts + delete confirmation (Feedback board).
