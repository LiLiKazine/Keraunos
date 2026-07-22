import Testing
import Foundation
import KeraunosCore

struct MediaURLExpiryTests {
    @Test func parsesExpireUnixTimestamp() {
        let url = URL(string: "https://r1.googlevideo.com/videoplayback?expire=1750000000&id=abc")!
        #expect(MediaURLExpiry.expiry(of: url) == Date(timeIntervalSince1970: 1_750_000_000))
    }
    @Test func nilWhenNoExpireParam() {
        #expect(MediaURLExpiry.expiry(of: URL(string: "https://cdn.example/v.mp4")!) == nil)
    }
    @Test func nilWhenExpireNotANumber() {
        #expect(MediaURLExpiry.expiry(of: URL(string: "https://x/y?expire=soon")!) == nil)
    }
}
