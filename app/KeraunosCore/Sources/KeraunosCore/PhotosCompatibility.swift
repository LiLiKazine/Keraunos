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
