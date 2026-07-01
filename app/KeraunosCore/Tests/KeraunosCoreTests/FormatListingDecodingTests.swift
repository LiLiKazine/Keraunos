import Testing
import Foundation
import KeraunosCore

struct FormatListingDecodingTests {
    @Test func decodesChoices() throws {
        let json = #"""
        {"ok":true,"kind":"choices","options":[
          {"height":1080,"codec":"H.264","approx_bytes":47185920,"format_id":"137","adaptive":true},
          {"height":360,"codec":"H.264","approx_bytes":null,"format_id":"18","adaptive":false}
        ]}
        """#
        guard case let .choices(options) = try ExtractionDecoder.decodeListing(Data(json.utf8)) else {
            Issue.record("expected choices"); return
        }
        #expect(options.count == 2)
        #expect(options[0] == FormatOption(height: 1080, codecLabel: "H.264",
                approxBytes: 47_185_920, formatID: "137", isAdaptive: true))
        #expect(options[1] == FormatOption(height: 360, codecLabel: "H.264",
                approxBytes: nil, formatID: "18", isAdaptive: false))
    }

    @Test func decodesReadyProgressiveAsReady() throws {
        let json = #"""
        {"ok":true,"kind":"progressive","title":"T","filename":"clip.mp4",
         "media":{"url":"https://x.test/v.mp4","headers":{},"vcodec":"avc1","acodec":"mp4a","ext":"mp4"}}
        """#
        guard case let .ready(media) = try ExtractionDecoder.decodeListing(Data(json.utf8)) else {
            Issue.record("expected ready"); return
        }
        #expect(media.suggestedFilename == "clip.mp4")
    }

    @Test func mapsErrorPayloadToKeraunosError() {
        let json = #"{"ok":false,"error_kind":"requires_auth","detail":"sign in"}"#
        #expect(throws: KeraunosError.requiresAuth) {
            try ExtractionDecoder.decodeListing(Data(json.utf8))
        }
    }
}
