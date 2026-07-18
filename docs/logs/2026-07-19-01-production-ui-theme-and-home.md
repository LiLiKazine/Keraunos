# 2026-07-19-01: Production UI — theme layer + Home screen (Refined Native)

**Status:** Implemented (checkpoint 1 of the UI rebuild)

## Context

The shipped SwiftUI was a throwaway PoC: a single `DownloadScreen` built from a
system `Form`. A production design system ("Refined Native", dark) was authored in
Claude Design and locked. This is the first checkpoint of rebuilding the UI as real
SwiftUI against that system — theme foundations + the Home (Download) screen — wired
to the existing `DownloadViewModel`/`CookieStore` with behavior unchanged.

## Options

| Approach | Pros | Cons |
|----------|------|------|
| Asset-catalog color sets | Xcode-native, light/dark variants | oklch not supported; opaque diffs; the app is dark-only |
| oklch→sRGB baked in a `Color` extension (chosen) | Reviewable, source oklch kept in comments, one place | Manual conversion step |
| Keep `Form`, restyle | Least code | Can't hit the custom cards/lists/hero the design needs |
| Custom `ScrollView` + components (chosen) | Matches design exactly | More components to build |

## Decision

Build a small Theme layer (`Palette`/`Metrics`/`Typography`/`Surfaces`) plus reusable
components, and rebuild Home as a custom `ScrollView` composition wired to the existing
view model. Convert the oklch design tokens to sRGB once, in code.

## Rationale

SwiftUI has no oklch initializer and the app is dark-only, so an asset catalog buys
nothing over a documented `Color` extension. The design's hero card, hairline-separated
Recent list, and progress card can't be expressed with a system `Form`, so a custom
composition is required — which is also what steps 2–4 (components, screens, adaptive
shell) build on.

## What Changed

- **New `Theme/`**: `Palette.swift` (oklch→sRGB tokens), `Metrics.swift` (space/radius/
  stroke scales), `Typography.swift` (SF Pro ramp + `sectionLabelStyle`/tabular helpers),
  `Surfaces.swift` (`card()` + two-layer `cardShadow()`).
- **New `Components/`**: `ButtonStyles` (primary/secondary/ghost), `LinkPasteField`,
  `ProgressBar`, `DownloadProgressCard`, `DownloadRow`, `Thumbnail`, `SectionHeader`,
  `NoticeCard`, `EmptyStateView`.
- **New `UI/`**: `HomeScreen` (the rebuilt Download screen), `HomeModals` (quality dialog,
  save alert, login sheet extracted as view modifiers), `SettingsView` (minimal stub
  carrying the diagnostics affordance).
- **Removed** `UI/DownloadScreen.swift`; `ContentView` now hosts `HomeScreen`.
- Decision trail + ledger in `/DECISIONS.md`.

## What Was Discovered

- **`.swipeActions` needs a `List`.** The design's Recent list is a custom
  hairline-separated stack in a `ScrollView`, where swipe actions silently do nothing.
  Switched row actions (Delete/Share/Save-to-Photos) to `.contextMenu` (long-press),
  keeping tap-to-play. Delete-confirm + toasts are deferred to the Feedback step.
- **SourceKit cross-file lag is loud here.** Every newly-added file reported "cannot
  find X in scope" / "no such module KeraunosCore" until a real build; `xcodebuild`
  compiled clean with zero errors. Trust the build, not the live diagnostics.
- **The project uses `PBXFileSystemSynchronizedRootGroup`**, so files added under
  `Keraunos/` are auto-included — no `project.pbxproj` edits needed for new sources.
- Verified on the iPhone 17 simulator: Home renders faithfully (header, hero, empty
  Recent state); full suite 39/39 green.
