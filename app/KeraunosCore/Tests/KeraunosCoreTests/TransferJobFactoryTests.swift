import Testing
import Foundation
@testable import KeraunosCore

@Suite struct TransferJobFactoryTests {
    private let page = URL(string: "https://site.example/watch?v=1")!
    private let sel = FormatSelection(formatID: "22", height: 720, isAdaptive: false)

    private func track(_ url: String, headers: [String: String] = ["User-Agent": "yt"], chunk: Int? = nil,
                      approxBytes: Int64? = nil) -> MediaTrack {
        MediaTrack(url: URL(string: url)!, httpHeaders: headers, codec: "h264", fileExtension: "mp4",
                   chunkSize: chunk, approxBytes: approxBytes)
    }

    /// The extraction-time size estimate rides along as `approxBytes` — display only. It must
    /// NOT land in `totalBytes`, which gates chunk termination, track completeness, and the
    /// finalizer's integrity check.
    @Test func carriesApproxBytesWithoutSeedingTotalBytes() {
        let media = ResolvedMedia(kind: .adaptive(video: track("https://cdn/v.m4s", approxBytes: 9000),
                                                  audio: track("https://cdn/a.m4s", approxBytes: 1000)),
                                  title: "T", suggestedFilename: "T.mp4")
        let id = UUID()
        let job = TransferJobFactory.make(id: id, from: media, sourcePageURL: page, selection: sel,
                                          autoSaveToPhotos: false, credentialRef: nil,
                                          createdAt: Date(), partPrefix: id.uuidString)
        guard case .adaptive(let v, let a) = job.kind else { Issue.record("expected adaptive"); return }
        #expect(v.approxBytes == 9000)
        #expect(a.approxBytes == 1000)
        #expect(v.totalBytes == nil)
        #expect(a.totalBytes == nil)
    }

    @Test func progressiveCarriesHeadersAndChunkAndName() {
        let media = ResolvedMedia(kind: .progressive(track("https://cdn/v.mp4", chunk: 1_048_576)),
                                  title: "T", suggestedFilename: "T.mp4")
        let id = UUID()
        let job = TransferJobFactory.make(id: id, from: media, sourcePageURL: page, selection: sel,
                                          autoSaveToPhotos: true, credentialRef: nil,
                                          createdAt: Date(), partPrefix: id.uuidString)
        guard case .progressive(let t) = job.kind else { Issue.record("expected progressive"); return }
        #expect(job.state == .queued)
        #expect(job.autoSaveToPhotos == true)
        #expect(t.requestHeaders["User-Agent"] == "yt")
        #expect(t.chunkSize == 1_048_576)
        #expect(t.partFileName == "\(id.uuidString)-media.part")
        #expect(t.bytesWritten == 0)
        #expect(t.totalBytes == nil)
    }

    @Test func adaptiveMakesTwoNamedTracks() {
        let media = ResolvedMedia(kind: .adaptive(video: track("https://cdn/v.m4s", chunk: 2),
                                                  audio: track("https://cdn/a.m4s")),
                                  title: "T", suggestedFilename: "T.mp4")
        let id = UUID()
        let job = TransferJobFactory.make(id: id, from: media, sourcePageURL: page, selection: sel,
                                          autoSaveToPhotos: false, credentialRef: nil,
                                          createdAt: Date(), partPrefix: id.uuidString)
        guard case .adaptive(let v, let a) = job.kind else { Issue.record("expected adaptive"); return }
        #expect(v.partFileName == "\(id.uuidString)-video.part")
        #expect(a.partFileName == "\(id.uuidString)-audio.part")
        #expect(v.chunkSize == 2)
        #expect(a.chunkSize == nil)
    }
}
