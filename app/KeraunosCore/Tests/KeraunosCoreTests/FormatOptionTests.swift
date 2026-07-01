import Testing
import Foundation
import KeraunosCore

struct FormatOptionTests {
    private func option(height: Int = 1080, codec: String = "H.264",
                        bytes: Int64? = nil, id: String = "137",
                        adaptive: Bool = true) -> FormatOption {
        FormatOption(height: height, codecLabel: codec, approxBytes: bytes,
                     formatID: id, isAdaptive: adaptive)
    }

    @Test func labelWithAllFields() {
        let bytes: Int64 = 47_185_920   // 47.2 MB (file-style)
        #expect(option(height: 1080, codec: "H.264", bytes: bytes).displayLabel
                == "1080p · H.264 · 47.2 MB")
    }

    @Test func labelDropsSizeWhenUnknown() {
        #expect(option(height: 720, codec: "HEVC", bytes: nil).displayLabel
                == "720p · HEVC")
    }

    @Test func labelDropsCodecWhenEmpty() {
        #expect(option(height: 360, codec: "", bytes: nil).displayLabel == "360p")
    }
}
