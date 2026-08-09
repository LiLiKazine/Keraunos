import Testing
import Foundation
import KeraunosCore

struct TransferJobTests {
    private func dashJob() -> TransferJob {
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
            formatSelection: FormatSelection(formatID: "137+140", height: 1080, isDASH: true),
            credentialRef: "youtube.com",
            createdAt: Date(timeIntervalSince1970: 1000),
            state: .downloading,
            kind: .dash(video: video, audio: audio),
            suggestedFilename: "Clip.mp4",
            savedFilename: nil,
            autoSaveToPhotos: true)
    }

    /// The Swift names moved from `adaptive` to DASH, but the durable format must not: a job
    /// queued by an older build has to keep decoding after the upgrade. A round-trip test
    /// cannot catch a wire break (both sides move together), so this pins literal bytes —
    /// the `"adaptive"` kind discriminator and the `"isAdaptive"` selection key.
    @Test func legacyAdaptivePayloadStillDecodesAfterTheDASHRename() throws {
        let legacy = Data("""
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "sourcePageURL": "https://youtube.com/watch?v=x",
          "formatSelection": { "formatID": "137+140", "height": 1080, "isAdaptive": true },
          "createdAt": -978306200,
          "state": { "queued": {} },
          "kind": {
            "adaptive": {
              "video": { "remoteURL": "https://cdn.example/v", "partFileName": "v.part",
                         "bytesWritten": 0, "requestHeaders": {} },
              "audio": { "remoteURL": "https://cdn.example/a", "partFileName": "a.part",
                         "bytesWritten": 0, "requestHeaders": {} }
            }
          },
          "suggestedFilename": "Clip.mp4",
          "autoSaveToPhotos": false
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(TransferJob.self, from: legacy)

        #expect(decoded.formatSelection.isDASH)
        guard case .dash(let video, let audio) = decoded.kind else {
            Issue.record("legacy \"adaptive\" kind did not decode as .dash")
            return
        }
        #expect(video.partFileName == "v.part")
        #expect(audio.partFileName == "a.part")
    }

    /// The other direction: what we write today must still carry the legacy key names, or the
    /// next build to read it (or a downgrade) sees an unknown shape.
    @Test func encodingStillEmitsTheLegacyAdaptiveKeys() throws {
        let encoded = try JSONEncoder().encode(dashJob())
        let json = try #require(String(data: encoded, encoding: .utf8))

        #expect(json.contains("\"adaptive\""))
        #expect(json.contains("\"isAdaptive\""))
        #expect(!json.contains("\"dash\""))
        #expect(!json.contains("\"isDASH\""))
    }

    @Test func codableRoundTripPreservesEverything() throws {
        var job = dashJob()
        job.state = .merging
        job.finalizationPhase = .readyToPromote
        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: data)
        #expect(decoded == job)
        #expect(decoded.finalizationPhase == .readyToPromote)
    }

    @Test func failedStateRoundTripsWithReason() throws {
        var job = dashJob()
        job.state = .failed(.insufficientSpace)
        let decoded = try JSONDecoder().decode(TransferJob.self, from: JSONEncoder().encode(job))
        #expect(decoded.state == .failed(.insufficientSpace))
    }

    @Test func finalizationPhaseRoundTripsAndLegacyPayloadDefaultsToNil() throws {
        var job = dashJob()
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

    @Test func tracksAndPartNamesForDASH() {
        let job = dashJob()
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
            formatSelection: FormatSelection(formatID: "18", height: 360, isDASH: false),
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
