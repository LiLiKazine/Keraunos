import Foundation
import Photos

/// The real `PhotoSaving`: saves a video into the Photos library with add-only access.
/// Device-only (authorization + `performChanges`), so it isn't unit-tested — the view
/// model's result→message mapping is covered with a mock instead.
struct PhotoLibrarySaver: PhotoSaving {
    // `nonisolated` is load-bearing. The app target builds with
    // -default-isolation=MainActor, so without it this method — and the change
    // block below — are MainActor-isolated. Photos runs that block on its own
    // `com.apple.PHPhotoLibrary.changes` queue, the concurrency runtime checks
    // the isolation, and the check traps in `dispatch_assert_queue` (SIGTRAP).
    // The crash only reproduces once the add-only permission has been *granted*,
    // which is why it hid until the first Allow.
    nonisolated func save(_ fileURL: URL) async -> PhotoSaveResult {
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
