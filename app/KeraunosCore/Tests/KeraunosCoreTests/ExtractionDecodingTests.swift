import Testing
import Foundation
import KeraunosCore

struct ExtractionDecodingTests {
    @Test func decodesProgressive() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"My Clip","filename":"clip.mp4",
         "media":{"url":"https://x.test/v.mp4","headers":{"User-Agent":"yt"},"vcodec":"avc1","acodec":"mp4a","ext":"mp4"}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        #expect(media.title == "My Clip")
        #expect(media.suggestedFilename == "clip.mp4")
        guard case let .progressive(track) = media.kind else { Issue.record("expected progressive"); return }
        #expect(track.url == URL(string: "https://x.test/v.mp4"))
        #expect(track.httpHeaders["User-Agent"] == "yt")
        #expect(track.fileExtension == "mp4")
    }

    @Test func decodesAdaptive() throws {
        let json = #"""
        {"ok":true,"kind":"adaptive","title":"T","filename":"clip.mp4",
         "video":{"url":"https://x.test/v.m4v","headers":{"User-Agent":"yt"},"vcodec":"hvc1","ext":"mp4"},
         "audio":{"url":"https://x.test/a.m4a","headers":{"Referer":"r"},"acodec":"mp4a","ext":"m4a"}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        guard case let .adaptive(video, audio) = media.kind else { Issue.record("expected adaptive"); return }
        #expect(video.url == URL(string: "https://x.test/v.m4v"))
        #expect(video.codec == "hvc1")
        #expect(audio.url == URL(string: "https://x.test/a.m4a"))
        #expect(audio.httpHeaders["Referer"] == "r")
        #expect(audio.fileExtension == "m4a")
    }

    @Test func mapsErrorPayloadToKeraunosError() {
        let json = #"{"ok":false,"error_kind":"needs_ffmpeg","detail":"hls only"}"#
        #expect(throws: KeraunosError.needsFfmpeg) {
            try ExtractionDecoder.decode(Data(json.utf8))
        }
    }

    @Test func fallsBackToURLLastComponentWhenFilenameMissing() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"",
         "media":{"url":"https://x.test/abc/video.mp4","headers":{},"vcodec":"avc1","acodec":"mp4a","ext":"mp4"}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        #expect(media.suggestedFilename == "video.mp4")
    }

    @Test func throwsRuntimeOnMalformed() {
        #expect(throws: KeraunosError.self) {
            try ExtractionDecoder.decode(Data("not json".utf8))
        }
    }

    @Test func decodesChunkSizeFromWire() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"T","filename":"c.mp4",
         "media":{"url":"https://x.test/v.mp4","headers":{},"vcodec":"avc1","acodec":"mp4a","ext":"mp4","chunk_size":10485760}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        guard case let .progressive(track) = media.kind else { Issue.record("expected progressive"); return }
        #expect(track.chunkSize == 10485760)
    }

    @Test func chunkSizeNilWhenAbsent() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"T","filename":"c.mp4",
         "media":{"url":"https://x.test/v.mp4","headers":{},"vcodec":"avc1","acodec":"mp4a","ext":"mp4"}}
        """#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        guard case let .progressive(track) = media.kind else { Issue.record("expected progressive"); return }
        #expect(track.chunkSize == nil)
    }
}
