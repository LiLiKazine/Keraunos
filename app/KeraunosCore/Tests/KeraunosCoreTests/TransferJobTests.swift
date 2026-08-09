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
        var job = adaptiveJob()
        job.state = .merging
        job.finalizationPhase = .readyToPromote
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: data)
        #expect(decoded == job)
        #expect(decoded.finalizationPhase == .readyToPromote)
    }

    @Test func failedStateRoundTripsWithReason() throws {
        var job = adaptiveJob()
        job.state = .failed(.insufficientSpace)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.state == .failed(.insufficientSpace))
    }

    @Test func finalizationPhaseRoundTripsAndLegacyPayloadDefaultsToNil() throws {
        var job = adaptiveJob()
        job.finalizationPhase = .readyToPromote
        let data = try JSONEncoder().encode(job)

        let checkpointed = try JSONDecoder().decode(TransferJob.self, from: data)
        #expect(checkpointed.finalizationPhase == .readyToPromote)

        var legacyPayload = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacyPayload.removeValue(forKey: "finalizationPhase")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyPayload)
        let legacy = try JSONDecoder().decode(TransferJob.self, from: legacyData)
        #expect(legacy.finalizationPhase == nil)
    }

    @Test func tracksAndPartNamesForAdaptive() {
        let job = adaptiveJob()
        #expect(job.tracks.count == 2)
        #expect(job.trackPartFileNames == ["job-video.part", "job-audio.part"])
        #expect(job.finalizationPartialFileName ==
                "11111111-1111-1111-1111-111111111111.finalizing.partial.mp4")
        #expect(job.finalizationReadyFileName ==
                "11111111-1111-1111-1111-111111111111.finalizing.ready.mp4")
        #expect(job.finalizationPromotionCheckpointFileName ==
                "11111111-1111-1111-1111-111111111111.finalizing.promoted.mp4")
        #expect(job.ownedPartFileNames == [
            "job-video.part",
            "job-audio.part",
            "11111111-1111-1111-1111-111111111111.finalizing.partial.mp4",
            "11111111-1111-1111-1111-111111111111.finalizing.ready.mp4",
            "11111111-1111-1111-1111-111111111111.finalizing.promoted.mp4",
            "11111111-1111-1111-1111-111111111111.finalizing.partial.mp4.scratch-video.mp4",
            "11111111-1111-1111-1111-111111111111.finalizing.partial.mp4.scratch-audio.m4a"
        ])
        #expect(Set(job.ownedPartFileNames).count == job.ownedPartFileNames.count)
    }

    @Test func tracksAndPartNamesForProgressive() {
        let track = TrackJob(
            remoteURL: URL(string: "https://cdn.example/p.mp4")!,
            urlExpiresAt: nil, chunkSize: nil, partFileName: "job-prog.part",
            bytesWritten: 0, totalBytes: nil, resumeData: nil, taskIdentifier: nil)
        let job = TransferJob(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sourcePageURL: URL(string: "https://ex.com")!,
            formatSelection: FormatSelection(formatID: "18", height: 360, isAdaptive: false),
            credentialRef: nil, createdAt: Date(timeIntervalSince1970: 1),
            state: .queued, kind: .progressive(track),
            suggestedFilename: "p.mp4", savedFilename: nil, autoSaveToPhotos: false)
        #expect(job.trackPartFileNames == ["job-prog.part"])
        #expect(job.finalizationPartialFileName ==
                "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.finalizing.partial.media")
        #expect(job.finalizationReadyFileName ==
                "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.finalizing.ready.media")
        #expect(job.finalizationPromotionCheckpointFileName ==
                "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.finalizing.promoted.media")
        #expect(job.ownedPartFileNames == [
            "job-prog.part",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.finalizing.partial.media",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.finalizing.ready.media",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.finalizing.promoted.media",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.finalizing.partial.media.scratch-video.mp4",
            "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.finalizing.partial.media.scratch-audio.m4a"
        ])
        #expect(Set(job.ownedPartFileNames).count == job.ownedPartFileNames.count)
    }
}
