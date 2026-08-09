import Testing
import Foundation
import KeraunosCore

struct AVFoundationMergerTests {
    private func tempFile(_ name: String, bytes: Data) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try? bytes.write(to: url)
        return url
    }

    @Test func throwsMergeFailedOnNonMediaInputs() async {
        let video = tempFile("v.mp4", bytes: Data("not a video".utf8))
        let audio = tempFile("a.m4a", bytes: Data("not audio".utf8))
        let out = tempFile("out.mp4", bytes: Data()).deletingLastPathComponent().appendingPathComponent("out.mp4")
        await #expect(throws: KeraunosError.mergeFailed) {
            try await AVFoundationMerger().merge(video: video, audio: audio, into: out)
        }
    }

    /// A non-media body (e.g. an auth/error page) fails the mux; the diagnostic must name it
    /// as `html`, not leave "mergeFailed" opaque — that's the whole point of the capture.
    @Test func recordsBodySignatureWhenTrackIsNotMedia() async {
        let diag = RecordingDiagnostics()
        let video = tempFile("v.mp4", bytes: Data("<!DOCTYPE html><html><body>login</body></html>".utf8))
        let audio = tempFile("a.m4a", bytes: Data("<html>nope</html>".utf8))
        let out = tempFile("out.mp4", bytes: Data()).deletingLastPathComponent().appendingPathComponent("out.mp4")
        await #expect(throws: KeraunosError.mergeFailed) {
            try await AVFoundationMerger(diagnostics: diag).merge(video: video, audio: audio, into: out)
        }
        let line = diag.lines.first { $0.kind == "merge_unsupported" }
        #expect(line != nil)
        #expect(line?.detail.contains("video-body=html") == true)
    }

    @Test func staleDeterministicHardLinksAreReusedAndCleanedWithoutAccumulating() async throws {
        let id = UUID()
        let video = tempFile("v.mp4", bytes: Data("not video".utf8))
        let audio = tempFile("a.m4a", bytes: Data("not audio".utf8))
        let outputDirectory = video.deletingLastPathComponent()
        let output = outputDirectory.appendingPathComponent(
            "\(id.uuidString).finalizing.partial.mp4")
        let videoScratch = outputDirectory.appendingPathComponent(
            "\(id.uuidString).finalizing.partial.mp4.scratch-video.mp4")
        let audioScratch = outputDirectory.appendingPathComponent(
            "\(id.uuidString).finalizing.partial.mp4.scratch-audio.m4a")
        try Data("stale video".utf8).write(to: videoScratch)
        try Data("stale audio".utf8).write(to: audioScratch)

        await #expect(throws: KeraunosError.mergeFailed) {
            try await AVFoundationMerger().merge(video: video, audio: audio, into: output)
        }

        #expect(!FileManager.default.fileExists(atPath: videoScratch.path))
        #expect(!FileManager.default.fileExists(atPath: audioScratch.path))
        let leftovers = try FileManager.default.contentsOfDirectory(
            at: outputDirectory, includingPropertiesForKeys: nil)
        #expect(!leftovers.contains { $0.lastPathComponent.hasPrefix(id.uuidString) })
    }
}

/// Collects diagnostic lines so a test can assert what was recorded.
private final class RecordingDiagnostics: TransferDiagnostics, @unchecked Sendable {
    private(set) var lines: [(kind: String, detail: String)] = []
    func record(kind: String, detail: String) { lines.append((kind: kind, detail: detail)) }
}
