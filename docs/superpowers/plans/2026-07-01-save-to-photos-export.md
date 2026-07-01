# Save-to-Photos Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-file "Save to Photos" swipe action to finished downloads, shown only for Photos-compatible files, with a success/failure alert.

**Architecture:** A pure compatibility check in `KeraunosCore`; an injected `PhotoSaving` protocol whose result the view model maps to a user-facing message (unit-tested with a mock); a real `PhotoLibrarySaver` using add-only Photos access; and a `DownloadScreen` swipe action + alert. Mirrors the app's existing DI pattern (`CookieProviding`, injected extractor/merger).

**Tech Stack:** Swift 6.2 / SwiftUI, Swift Testing, Photos framework (`PHPhotoLibrary`, `PHAssetCreationRequest`), KeraunosCore SwiftPM package.

## Global Constraints

- Tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`) — never XCTest.
- Pure units live in **KeraunosCore** and are tested with `swift test` (fast, no simulator). App-target (view model / UI) tests run via `xcodebuild … -destination 'platform=iOS Simulator,name=iPhone 17'`.
- App target builds with `-default-isolation=MainActor` and `SWIFT_VERSION = 5.0`; `DownloadViewModel` is MainActor-isolated.
- Deployment target **iOS 26.5**.
- Add-only Photos access uses the `NSPhotoLibraryAddUsageDescription` Info.plist string — **no** signing capability, so no Xcode/owner step.
- Commit straight to `main` after each task's tests pass. End commit messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

## File Structure

- Create `app/KeraunosCore/Sources/KeraunosCore/PhotosCompatibility.swift` — pure `canSave(_:)`.
- Create `app/KeraunosCore/Tests/KeraunosCoreTests/PhotosCompatibilityTests.swift`.
- Create `app/Keraunos/Keraunos/Photos/PhotoSaving.swift` — `PhotoSaving` protocol + `PhotoSaveResult`.
- Create `app/Keraunos/Keraunos/Photos/PhotoLibrarySaver.swift` — real Photos implementation.
- Modify `app/Keraunos/Keraunos/UI/DownloadViewModel.swift` — inject saver; add `saveToPhotos`, `canSaveToPhotos`, `saveMessage`, `dismissSaveMessage`.
- Modify `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift` — `MockPhotoSaver` + save tests.
- Modify `app/Keraunos/Keraunos/UI/DownloadScreen.swift` — swipe action + alert.
- Modify `app/Keraunos/Keraunos/ContentView.swift` — wire `PhotoLibrarySaver()`.
- Modify `app/Keraunos/Info.plist` — add `NSPhotoLibraryAddUsageDescription`.

---

### Task 1: Photos-compatibility check (pure, KeraunosCore)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/PhotosCompatibility.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/PhotosCompatibilityTests.swift`

**Interfaces:**
- Produces: `public enum PhotosCompatibility { public static func canSave(_ url: URL) -> Bool }`

- [ ] **Step 1: Write the failing test**

Create `app/KeraunosCore/Tests/KeraunosCoreTests/PhotosCompatibilityTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct PhotosCompatibilityTests {
    @Test func acceptsPhotosVideoContainers() {
        for ext in ["mp4", "m4v", "mov", "MP4", "MOV"] {
            #expect(PhotosCompatibility.canSave(URL(fileURLWithPath: "/tmp/clip.\(ext)")))
        }
    }

    @Test func rejectsNonPhotosContainersAndSidecars() {
        for ext in ["mkv", "webm", "txt", "log"] {
            #expect(!PhotosCompatibility.canSave(URL(fileURLWithPath: "/tmp/clip.\(ext)")))
        }
        #expect(!PhotosCompatibility.canSave(URL(fileURLWithPath: "/tmp/noextension")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd app/KeraunosCore && swift test --filter PhotosCompatibilityTests`
Expected: FAIL — `cannot find 'PhotosCompatibility' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `app/KeraunosCore/Sources/KeraunosCore/PhotosCompatibility.swift`:

```swift
import Foundation

/// Which downloaded files the Photos library can accept as a video asset. Complements
/// `DownloadStore.listedExtensions` (broader — it also lists mkv/webm that play in-app but
/// Photos can't import). `PHAssetCreationRequest` reliably accepts only these MP4/QuickTime
/// containers.
public enum PhotosCompatibility {
    static let extensions: Set<String> = ["mp4", "m4v", "mov"]

    public static func canSave(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd app/KeraunosCore && swift test --filter PhotosCompatibilityTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/PhotosCompatibility.swift \
        app/KeraunosCore/Tests/KeraunosCoreTests/PhotosCompatibilityTests.swift
git commit -m "$(cat <<'EOF'
feat(photos): pure PhotosCompatibility.canSave for mp4/m4v/mov

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `PhotoSaving` protocol + view-model save flow (app target, TDD with mock)

**Files:**
- Create: `app/Keraunos/Keraunos/Photos/PhotoSaving.swift`
- Modify: `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`
- Test: `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`

**Interfaces:**
- Consumes: `PhotosCompatibility.canSave(_:)` (Task 1).
- Produces:
  - `enum PhotoSaveResult { case saved, permissionDenied, failed }`
  - `protocol PhotoSaving { func save(_ fileURL: URL) async -> PhotoSaveResult }`
  - `DownloadViewModel.init(..., photoSaver: (any PhotoSaving)? = nil)`
  - `func canSaveToPhotos(_ file: URL) -> Bool`, `func saveToPhotos(_ file: URL) async`,
    `private(set) var saveMessage: String?`, `func dismissSaveMessage()`

- [ ] **Step 1: Create the protocol + result type**

Create `app/Keraunos/Keraunos/Photos/PhotoSaving.swift`:

```swift
import Foundation

/// Outcome of a save-to-Photos attempt; the view model maps it to a user-facing message.
enum PhotoSaveResult {
    case saved
    case permissionDenied
    case failed
}

/// Saves a finished download into the Photos library. Injected into `DownloadViewModel`
/// so the result→message mapping is testable with a mock; the real Photos call is
/// device-only. Not `Sendable` — the view model and the saver are both MainActor.
protocol PhotoSaving {
    func save(_ fileURL: URL) async -> PhotoSaveResult
}
```

- [ ] **Step 2: Write the failing tests**

In `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`, add a mock and a VM helper near the top of the struct (after the existing `vm(extractor:merger:dir:)` helper), then the tests:

```swift
    final class MockPhotoSaver: PhotoSaving {
        var result: PhotoSaveResult
        private(set) var savedURLs: [URL] = []
        init(result: PhotoSaveResult) { self.result = result }
        func save(_ fileURL: URL) async -> PhotoSaveResult {
            savedURLs.append(fileURL); return result
        }
    }

    private func saverVM(_ saver: any PhotoSaving) -> DownloadViewModel {
        DownloadViewModel(extractor: MockExtractor(),
                          assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
                          store: DownloadStore(directory: tempDir()),
                          photoSaver: saver)
    }

    @Test func saveToPhotosReportsSuccess() async {
        let saver = MockPhotoSaver(result: .saved)
        let model = saverVM(saver)
        let file = URL(fileURLWithPath: "/tmp/clip.mp4")
        await model.saveToPhotos(file)
        #expect(saver.savedURLs == [file])
        #expect(model.saveMessage == "Saved to Photos.")
    }

    @Test func saveToPhotosReportsPermissionDenied() async {
        let model = saverVM(MockPhotoSaver(result: .permissionDenied))
        await model.saveToPhotos(URL(fileURLWithPath: "/tmp/clip.mp4"))
        #expect(model.saveMessage == "Allow Photos access in Settings to save videos.")
    }

    @Test func saveToPhotosReportsFailure() async {
        let model = saverVM(MockPhotoSaver(result: .failed))
        await model.saveToPhotos(URL(fileURLWithPath: "/tmp/clip.mp4"))
        #expect(model.saveMessage == "Couldn't save to Photos.")
    }

    @Test func saveToPhotosSkipsIncompatibleFileAndDoesNotCallSaver() async {
        let saver = MockPhotoSaver(result: .saved)
        let model = saverVM(saver)
        await model.saveToPhotos(URL(fileURLWithPath: "/tmp/clip.mkv"))
        #expect(saver.savedURLs.isEmpty)
        #expect(model.saveMessage == nil)
    }
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KeraunosTests/DownloadViewModelTests test 2>&1 | tail -20`
Expected: FAIL to compile — `DownloadViewModel` has no `photoSaver:` parameter / no `saveToPhotos`/`saveMessage`.

- [ ] **Step 4: Implement in `DownloadViewModel.swift`**

Add a stored property alongside the other `private let` dependencies:

```swift
    private let photoSaver: (any PhotoSaving)?
```

Add the parameter to `init` (last, defaulted so existing call sites compile) and assign it. Change the signature to:

```swift
    init(extractor: any MediaExtracting, assembler: MediaAssembler, store: DownloadStore,
         failureLog: FailureLog? = nil, photoSaver: (any PhotoSaving)? = nil) {
```

and add inside the init body (after `self.failureLog = …`):

```swift
        self.photoSaver = photoSaver
```

Add the published state near the other `private(set) var`s:

```swift
    /// Message from the last Save-to-Photos attempt; drives a one-off alert. nil when idle.
    private(set) var saveMessage: String?
```

Add the methods (anywhere in the type body, e.g. after `deleteDownload`):

```swift
    /// Whether the Downloads UI should offer "Save to Photos" for this file.
    func canSaveToPhotos(_ file: URL) -> Bool { PhotosCompatibility.canSave(file) }

    /// Saves a finished download to Photos and reports the outcome via `saveMessage`.
    func saveToPhotos(_ file: URL) async {
        guard canSaveToPhotos(file), let photoSaver else { return }
        switch await photoSaver.save(file) {
        case .saved:            saveMessage = "Saved to Photos."
        case .permissionDenied: saveMessage = "Allow Photos access in Settings to save videos."
        case .failed:           saveMessage = "Couldn't save to Photos."
        }
    }

    /// Clears the Save-to-Photos alert message.
    func dismissSaveMessage() { saveMessage = nil }
```

(`DownloadViewModel.swift` already has `import KeraunosCore`, so `PhotosCompatibility` resolves.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:KeraunosTests/DownloadViewModelTests test 2>&1 | grep -iE "saveToPhotos|TEST SUCCEEDED|TEST FAILED"`
Expected: the 4 `saveToPhotos…` tests pass; `** TEST SUCCEEDED **`.
(If the simulator flakes on launch with `RequestDenied`/`Launchd job spawn failed`, clear it: `xcrun simctl shutdown all; killall Simulator; killall com.apple.CoreSimulator.CoreSimulatorService; sleep 12` then re-run.)

- [ ] **Step 6: Commit**

```bash
git add app/Keraunos/Keraunos/Photos/PhotoSaving.swift \
        app/Keraunos/Keraunos/UI/DownloadViewModel.swift \
        app/Keraunos/KeraunosTests/DownloadViewModelTests.swift
git commit -m "$(cat <<'EOF'
feat(photos): inject PhotoSaving into DownloadViewModel, map result to message

saveToPhotos routes .saved/.permissionDenied/.failed to a user-facing
saveMessage; canSaveToPhotos gates the action; incompatible files no-op
without calling the saver. Covered with a MockPhotoSaver.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Real `PhotoLibrarySaver` + Info.plist + UI + wiring (integration, build-verified)

**Files:**
- Create: `app/Keraunos/Keraunos/Photos/PhotoLibrarySaver.swift`
- Modify: `app/Keraunos/Info.plist`
- Modify: `app/Keraunos/Keraunos/UI/DownloadScreen.swift`
- Modify: `app/Keraunos/Keraunos/ContentView.swift`

**Interfaces:**
- Consumes: `PhotoSaving`/`PhotoSaveResult` (Task 2); `DownloadViewModel.canSaveToPhotos/saveToPhotos/saveMessage/dismissSaveMessage` (Task 2).
- Produces: `struct PhotoLibrarySaver: PhotoSaving`.

- [ ] **Step 1: Implement the real saver**

Create `app/Keraunos/Keraunos/Photos/PhotoLibrarySaver.swift`:

```swift
import Foundation
import Photos

/// The real `PhotoSaving`: saves a video into the Photos library with add-only access.
/// Device-only (authorization + `performChanges`), so it isn't unit-tested — the view
/// model's result→message mapping is covered with a mock instead.
struct PhotoLibrarySaver: PhotoSaving {
    func save(_ fileURL: URL) async -> PhotoSaveResult {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .permissionDenied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                // Keep our copy on disk so the Downloads row, preview, share, and delete
                // all keep working after the save.
                options.shouldMoveFile = false
                request.addResource(with: .video, fileURL: fileURL, options: options)
            }
            return .saved
        } catch {
            return .failed
        }
    }
}
```

- [ ] **Step 2: Add the Info.plist usage string**

In `app/Keraunos/Info.plist`, add this key/value inside the top-level `<dict>` (e.g. right after the `CFBundleURLTypes` array):

```xml
	<!-- Add-only Photos access for the "Save to Photos" action on a finished download.
	     A usage string only — not a signing capability. -->
	<key>NSPhotoLibraryAddUsageDescription</key>
	<string>Keraunos saves a downloaded video to your Photos library when you tap Save to Photos.</string>
```

- [ ] **Step 3: Add the swipe action + alert in `DownloadScreen.swift`**

Inside the finished-downloads `.swipeActions(edge: .trailing)` block (currently Delete + `ShareLink`), add the Save action after the `ShareLink`:

```swift
                                if model.canSaveToPhotos(file) {
                                    Button {
                                        Task { await model.saveToPhotos(file) }
                                    } label: {
                                        Label("Save to Photos", systemImage: "arrow.down.to.line")
                                    }
                                    .tint(.indigo)
                                }
```

Attach the alert to the `Form` — add it immediately after `.quickLookPreview($previewURL)`:

```swift
            .alert("Save to Photos", isPresented: Binding(
                get: { model.saveMessage != nil },
                set: { if !$0 { model.dismissSaveMessage() } }
            )) {
                Button("OK", role: .cancel) { model.dismissSaveMessage() }
            } message: {
                Text(model.saveMessage ?? "")
            }
```

- [ ] **Step 4: Wire the real saver in `ContentView.swift`**

In the non-preview `DownloadViewModel(...)` (the one using `PythonExtractor`), add the `photoSaver` argument:

```swift
            model: DownloadViewModel(
                extractor: PythonExtractor(cookieProvider: cookieStore),
                assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
                store: DownloadStore(),
                photoSaver: PhotoLibrarySaver()),
```

Leave the `#Preview` construction unchanged (it uses the defaulted `photoSaver: nil`).

- [ ] **Step 5: Build to verify it compiles**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' build 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"`
Expected: `** BUILD SUCCEEDED **`, no errors.

- [ ] **Step 6: Run the full test suite (guard against regressions)**

Run: `xcodebuild -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination 'platform=iOS Simulator,name=iPhone 17' test 2>&1 | grep -iE "TEST SUCCEEDED|TEST FAILED|error:"`
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add app/Keraunos/Keraunos/Photos/PhotoLibrarySaver.swift \
        app/Keraunos/Info.plist \
        app/Keraunos/Keraunos/UI/DownloadScreen.swift \
        app/Keraunos/Keraunos/ContentView.swift
git commit -m "$(cat <<'EOF'
feat(photos): Save-to-Photos swipe action + real PhotoLibrarySaver

Add-only Photos save (keeps the on-disk copy), NSPhotoLibraryAddUsageDescription,
a compatible-only swipe action, and a success/failure alert. Real Photos call is
device-only; app builds + full suite green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 8: On-device verification (owner-manual)**

Build to a device, download a video (mp4), swipe the row → **Save to Photos** → approve the add-only prompt → confirm the "Saved to Photos." alert and the video in the Photos app. Confirm the Downloads row/preview/share/delete still work (file kept). Deny-permission path shows the Settings message.

---

## Self-Review

**Spec coverage:** UX swipe action → Task 3 Step 3; compatible-only visibility → `canSaveToPhotos` (Task 2) + gate (Task 3 Step 3); `isPhotosCompatible` → Task 1; `PhotoSaving`/`PhotoLibrarySaver` add-only + `shouldMoveFile=false` → Tasks 2/3; VM result→message → Task 2; alert (success + failure) → Task 3 Step 3 + Task 2 messages; permission-denied/failure/incompatible handling → Task 2 tests + `saveToPhotos`; Info.plist key → Task 3 Step 2; testing (pure + VM mock, real call device-only) → Tasks 1–3. All covered.

**Placeholder scan:** none — every code and command step is concrete.

**Type consistency:** `PhotoSaveResult` cases `saved`/`permissionDenied`/`failed` used identically in the protocol, mock, VM `switch`, and real saver. `canSaveToPhotos`/`saveToPhotos`/`saveMessage`/`dismissSaveMessage` and the `photoSaver:` init label match across Tasks 2 and 3. `PhotosCompatibility.canSave` matches Task 1.
