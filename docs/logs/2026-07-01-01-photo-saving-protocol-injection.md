# 2026-07-01-01: PhotoSaving protocol injection into DownloadViewModel

**Status:** Implemented

## Context

Task 2 of the Save-to-Photos feature. Task 1 (already shipped) added
`PhotosCompatibility.canSave(_:) -> Bool` to `KeraunosCore` to gate which
file types can be saved to Photos. This task wires up the actual save flow
in the app's view model, keeping the real Photos API device-only and
testable via a mock.

The goal: the UI should be able to offer "Save to Photos" for compatible
files, call through to a Photos saver, and surface the outcome as a
one-off message. The mapping from `PhotoSaveResult` to a user-facing string
belongs in the view model (not the UI), so it can be verified without a
real Photos library.

## Options

| Approach | Pros | Cons |
|----------|------|------|
| Direct PHPhotoLibrary call in DownloadViewModel | Simpler — fewer types | Not testable without real Photos access; couples VM to Photos framework |
| Protocol injection (chosen) | Fully testable with MockPhotoSaver; real impl is device-only and can be swapped | One extra file (PhotoSaving.swift) |
| Result published on a separate publisher | More reactive | Overengineered for a simple one-shot alert |

## Decision

Inject `(any PhotoSaving)?` into `DownloadViewModel`; map the three result
cases to user-facing strings in `saveToPhotos(_:)`.

## Rationale

Protocol injection keeps the result→message mapping under unit test without
any Photos entitlement or real device. The optional `photoSaver` with a nil
default means all existing call sites compile unchanged — the feature is
additive. The `canSaveToPhotos` guard delegates to `PhotosCompatibility.canSave`
(Task 1), so the file-extension logic lives in one place.

## What Changed

- **New:** `app/Keraunos/Keraunos/Photos/PhotoSaving.swift` — `PhotoSaveResult`
  enum (saved/permissionDenied/failed) and `PhotoSaving` protocol.
- **Modified:** `app/Keraunos/Keraunos/UI/DownloadViewModel.swift` — added
  `photoSaver` stored property, extended `init` with defaulted `photoSaver:`
  parameter, added `saveMessage` state, `canSaveToPhotos`, `saveToPhotos`,
  `dismissSaveMessage`.
- **Modified:** `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift` —
  added `MockPhotoSaver`, `saverVM` helper, and four `saveToPhotos*` tests.

## What Was Discovered

- The project uses `PBXFileSystemSynchronizedRootGroup` for the `Keraunos/`
  source folder — new Swift files in any subdirectory are picked up
  automatically; no `project.pbxproj` edits needed for source files.
- `SWIFT_VERSION` in `project.pbxproj` is actually `6.0` on all app-target
  configs (the CLAUDE.md gotcha about `5.0` is stale for the app target;
  `5.0` only remains on the share extension target).
- The `saveToPhotosSkipsIncompatibleFileAndDoesNotCallSaver` test exercises
  the guard path where `canSaveToPhotos` returns false for `.mkv` — both
  `savedURLs.isEmpty` and `saveMessage == nil` must hold, confirming the
  saver is not called and no state is mutated.

## Commits

| Hash | Description |
|------|-------------|
| (see git log) | feat(photos): inject PhotoSaving into DownloadViewModel, map result to message |
