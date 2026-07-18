# 2026-07-19-02: Production UI — screens, adaptive shell, feedback (Refined Native)

**Status:** Implemented (checkpoint 2 — completes the UI rebuild)

## Context

Checkpoint 1 shipped the theme layer + Home. This checkpoint completes the rebuild:
the remaining screens (Library, Accounts, Settings), the quality picker, states,
toasts/confirmations, and the adaptive shell — all wired to the existing view models.

## Decisions

Full rationale in `/DECISIONS.md` (checkpoint 2). Highlights:

- **Adaptive shell:** `TabView` at compact width, custom-sidebar `NavigationSplitView`
  at regular width, switched on `horizontalSizeClass`. Library owns its own master/detail
  (grid + inline player) inside the detail column, so the shell stays two-column. Section
  titles are rendered in-content (`PaneTitle`) beside the split-view toggle rather than via
  the system nav bar (the scrolling panes didn't surface a large title reliably).
- **Two real preferences, no dead switches:** `Preferences` (UserDefaults) drives
  `defaultQuality` (ask / highest — skips the picker and auto-picks the best muxed stream)
  and `autoSaveToPhotos` (saves a compatible file after download). Both wired into
  `DownloadViewModel` and covered by tests. "Download over Wi-Fi only" omitted (would need
  invasive `Downloader`/`MediaAssembler` plumbing in KeraunosCore).
- **Data honesty:** show only what the store persists (title, size, saved date, file type,
  real `FormatOption` fields). No fabricated duration/resolution/source/byte-rate.
- **Feedback:** app-level `ToastCenter` (download complete, saved, deleted); destructive
  delete routes through a confirmation dialog; row/tile actions via context menu (+ iPad
  detail-pane buttons).

## What Changed

- New components: `DownloadTile`, `Toast`/`ToastCenter`, `Monogram`, `CompactHeader`/
  `PaneTitle`, `IconCircleButton`, richer `NoticeCard`, `primaryInline` button.
- New UI: `AppShell` (+ sidebar), `AppSection`, `LibraryScreen`, `AccountsScreen`,
  full `SettingsView`, `QualityPickerSheet`, `DownloadActions` (shared menu/confirm/toast).
- New model: `Preferences`; `DownloadViewModel` gains prefs wiring + read-only helpers
  (`savedDateText`, `fileTypeLabel`, `librarySubtitle`, `totalDownloadsSizeText`, `bestOption`).
- `ContentView` composes model/cookieStore/preferences and hosts `AppShell`.
  Removed the PoC `AccountsView` (superseded by `AccountsScreen`).

## What Was Discovered

- `.swipeActions` needs a `List`; the custom lists live in `ScrollView`, so actions use
  `.contextMenu` / an ellipsis `Menu` instead.
- The scrolling `NavigationSplitView` detail panes didn't render a system large title
  reliably (only the HStack-rooted Library did) — rendering an in-content `PaneTitle` is
  both more reliable and closer to the design's content-title.
- On an 11" iPad in portrait with the sidebar expanded, sidebar + detail leave a narrow
  middle, so the Library grid drops to one column; it reflows to 2–3 when the sidebar is
  collapsed or on wider iPads. Acceptable size-class behavior, not a bug.
- Review found (and fixed) a stale iPad detail selection when the selected file is deleted
  elsewhere — reconciled via `.onChange(of: savedFiles)`.

Verified: build green on iPhone 17 + iPad Pro 11", 42/42 tests, and on-sim screenshots of
every screen on both idioms.
