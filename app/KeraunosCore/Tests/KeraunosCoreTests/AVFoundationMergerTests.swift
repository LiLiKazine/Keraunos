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
}
