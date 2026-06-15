import Testing
import Foundation
import KeraunosCore

struct ExtractionDecodingTests {
    @Test func decodesSuccess() throws {
        let json = #"{"ok":true,"direct_url":"https://x.test/v.mp4","filename":"clip.mp4","title":"My Clip"}"#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        #expect(media == ResolvedMedia(directURL: URL(string: "https://x.test/v.mp4")!,
                                       suggestedFilename: "clip.mp4",
                                       title: "My Clip"))
    }

    @Test func mapsErrorPayloadToKeraunosError() {
        let json = #"{"ok":false,"error_kind":"needs_ffmpeg","detail":"hls only"}"#
        #expect(throws: KeraunosError.needsFfmpeg) {
            try ExtractionDecoder.decode(Data(json.utf8))
        }
    }

    @Test func fallsBackToURLLastComponentWhenFilenameMissing() throws {
        let json = #"{"ok":true,"direct_url":"https://x.test/abc/video.mp4","title":""}"#
        let media = try ExtractionDecoder.decode(Data(json.utf8))
        #expect(media.suggestedFilename == "video.mp4")
    }
}
