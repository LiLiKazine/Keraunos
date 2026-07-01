# Save-to-Photos export — design

## Goal

Let the owner save a finished download into the iOS Photos library (camera roll) with a
per-file action. This is the one net-new UX item left after the coverage roadmap; `ShareLink`
→ "Save Video" already covers most of it, but a direct action is cleaner.

Add-only Photos access requires only the `NSPhotoLibraryAddUsageDescription` Info.plist
string — **not** a signing capability — so this ships without any Xcode/owner step.

## UX

A new **"Save to Photos"** swipe action on each finished download in `DownloadScreen`,
alongside the existing Delete and Share (`ShareLink`) actions. It is shown **only** for
Photos-compatible files (`mp4`/`m4v`/`mov`). Tapping it saves the file to the camera roll
and shows a brief `.alert`:

- Success → "Saved to Photos."
- Permission denied → "Allow Photos access in Settings to save videos."
- Failure → "Couldn't save to Photos."

Decisions (confirmed): per-file manual action (no auto-save); compatible-only visibility
(no doomed button); alert on both success and failure.

## Components

Mirrors the app's existing dependency-injection + testability pattern (`CookieProviding`,
the injected extractor/merger).

1. **`isPhotosCompatible(_ url: URL) -> Bool`** — pure function in `KeraunosCore`, next to
   the `savedFiles()` video allow-set it complements. Returns true for a lowercased
   extension in `{mp4, m4v, mov}` (the containers `PHAssetCreationRequest` reliably
   accepts), false otherwise (`mkv`/`webm`/anything else). Pure, fast unit test.

2. **`PhotoSaving` protocol + `PhotoLibrarySaver`** — app target, `import Photos`.
   - `protocol PhotoSaving: Sendable { func save(_ fileURL: URL) async -> PhotoSaveResult }`
   - `enum PhotoSaveResult { case saved, permissionDenied, failed(String) }`
   - `PhotoLibrarySaver` requests **add-only** authorization
     (`PHPhotoLibrary.requestAuthorization(for: .addOnly)`); on `.authorized`/`.limited`,
     runs `performChanges` with
     `PHAssetCreationRequest.forAsset().addResource(.video, fileURL: url, options:)` where
     `options.shouldMoveFile = false` (keep our copy so Share/preview/delete still work).
     Maps `.denied`/`.restricted` → `.permissionDenied`, thrown/`performChanges` errors →
     `.failed(message)`.
   - Injected into the view model like `CookieProviding`.

3. **`DownloadViewModel.saveToPhotos(_ file: URL)`** — `@MainActor`. Calls the injected
   `photoSaver`, maps `PhotoSaveResult` → a published `saveMessage: String?`. Guarded by
   `isPhotosCompatible` (defensive; the UI already hides the action for incompatible files).
   Unit-tested with a mock saver.

4. **`DownloadScreen`** — adds the swipe action (visible only when
   `isPhotosCompatible(file)`), systemImage `arrow.down.to.line` / `photo`, tinted to
   distinguish from Share; and one `.alert` presenting `model.saveMessage` (dismiss clears it).

## Data flow

Tap swipe action → `model.saveToPhotos(file)` → `await photoSaver.save(file)` →
`PhotoLibrarySaver` requests add-only auth → `performChanges` copies the file into Photos →
result mapped to `saveMessage` → `.alert` shows it. The on-disk file is unchanged
(`shouldMoveFile = false`), so the existing Downloads row, preview, share, and delete keep
working.

## Error handling

- **Permission denied / restricted** → `.permissionDenied` → "Allow Photos access in
  Settings to save videos." (No deep-link to Settings in v1; the message is enough.)
- **`performChanges` error / unexpected** → `.failed(detail)` → "Couldn't save to Photos."
- **Incompatible file** → the action isn't shown; `saveToPhotos` also no-ops defensively.

## Testing

- **Pure (KeraunosCore, `swift test`):** `isPhotosCompatible` — true for `mp4`/`m4v`/`mov`
  (incl. uppercase extensions), false for `mkv`/`webm`/`txt`/no-extension.
- **View model (app target):** `saveToPhotos` with a mock `PhotoSaving` → sets the correct
  `saveMessage` for `.saved` / `.permissionDenied` / `.failed`; and no-ops (no save call)
  for an incompatible file.
- **Not unit-tested:** the real `PhotoLibrarySaver` Photos call (authorization +
  `performChanges`) is device/simulator-only — consistent with how `LoginWebView` and the
  Share Extension are handled. Verified by an on-device save.

## Out of scope (YAGNI)

Auto-save on completion, choosing/creating albums, saving still images, a Settings toggle,
and deep-linking to the Settings app on denial. Any of these can be added later.
