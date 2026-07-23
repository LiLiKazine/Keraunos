import Testing
import Foundation
import KeraunosCore

struct TransferJobTests {
    private func adaptiveJob() -> TransferJob {
        let video = TrackJob(
            remoteURL: URL(string: "https://cdn.example/v?expire=123")!,
            urlExpiresAt: Date(timeIntervalSince1970: 123),
            chunkSize: 10_485_760,
            partFileName: "job-video.part",
            bytesWritten: 20_971_520,
            totalBytes: 104_857_600,
            resumeData: nil,
            taskIdentifier: 7)
        let audio = TrackJob(
            remoteURL: URL(string: "https://cdn.example/a")!,
            urlExpiresAt: nil,
            chunkSize: nil,
            partFileName: "job-audio.part",
            bytesWritten: 0,
            totalBytes: nil,
            resumeData: Data([1, 2, 3]),
            taskIdentifier: nil)
        return TransferJob(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            sourcePageURL: URL(string: "https://youtube.com/watch?v=x")!,
            formatSelection: FormatSelection(formatID: "137+140", height: 1080, isAdaptive: true),
            credentialRef: "youtube.com",
            createdAt: Date(timeIntervalSince1970: 1000),
            state: .downloading,
            kind: .adaptive(video: video, audio: audio),
            suggestedFilename: "Clip.mp4",
            savedFilename: nil,
            autoSaveToPhotos: true)
    }

    @Test func codableRoundTripPreservesEverything() throws {
        let job = adaptiveJob()
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: data)
        #expect(decoded == job)
    }

    @Test func failedStateRoundTripsWithReason() throws {
        var job = adaptiveJob()
        job.state = .failed(.insufficientSpace)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.state == .failed(.insufficientSpace))
    }

    @Test func tracksAndPartNamesForAdaptive() {
        let job = adaptiveJob()
        #expect(job.tracks.count == 2)
        #expect(job.trackPartFileNames == ["job-video.part", "job-audio.part"])
    }

    @Test func tracksAndPartNamesForProgressive() {
        let track = TrackJob(
            remoteURL: URL(string: "https://cdn.example/p.mp4")!,
            urlExpiresAt: nil, chunkSize: nil, partFileName: "job-prog.part",
            bytesWritten: 0, totalBytes: nil, resumeData: nil, taskIdentifier: nil)
        let job = TransferJob(
            id: UUID(), sourcePageURL: URL(string: "https://ex.com")!,
            formatSelection: FormatSelection(formatID: "18", height: 360, isAdaptive: false),
            credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
            state: .queued, kind: .progressive(track),
            suggestedFilename: "p.mp4", savedFilename: nil, autoSaveToPhotos: false)
        #expect(job.trackPartFileNames == ["job-prog.part"])
    }
}
