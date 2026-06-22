import Testing
import Foundation
@testable import KeraunosCore

struct FailureLogTests {
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func formatsOneTabSeparatedLine() {
        let date = Date(timeIntervalSince1970: 0)
        let line = FailureLog.line(date: date, kind: "extract_network",
                                   url: "https://x.test/v", detail: "boom")
        #expect(line == "1970-01-01T00:00:00Z\textract_network\thttps://x.test/v\tboom")
    }

    @Test func flattensNewlinesAndTabsInDetail() {
        // Detail must never break the one-line-per-failure, tab-delimited shape.
        let line = FailureLog.line(date: Date(timeIntervalSince1970: 0), kind: "runtime",
                                   url: "u", detail: "a\nb\tc")
        #expect(line.components(separatedBy: "\t").count == 4)
        #expect(!line.dropFirst("1970-01-01T00:00:00Z\truntime\tu\t".count).contains("\n"))
    }

    @Test func capsRetainedEntriesToTheMostRecent() {
        let log = FailureLog(directory: tempDir(), maxEntries: 3)
        for i in 1...5 {
            log.record(url: "https://x.test/\(i)", errorKind: "timeout", date: Date(timeIntervalSince1970: TimeInterval(i)))
        }
        let lines = log.contents().split(separator: "\n")
        #expect(lines.count == 3)                      // bounded
        #expect(lines.first!.contains("/3"))            // oldest two (1,2) dropped
        #expect(lines.last!.contains("/5"))             // newest retained
    }

    @Test func clearRemovesTheLog() {
        let log = FailureLog(directory: tempDir())
        log.record(url: "u", errorKind: "runtime", date: Date(timeIntervalSince1970: 1))
        #expect(log.hasEntries)
        log.clear()
        #expect(!log.hasEntries)
        #expect(log.contents().isEmpty)
    }

    @Test func redactsSignedMediaURLParamsInDetail() {
        let detail = "HTTP 403 (https://r.googlevideo.com/videoplayback?id=abc&sig=SECRET123&pot=TOKEN)"
        let out = FailureLog.redact(detail)
        #expect(out.contains("sig=REDACTED"))
        #expect(out.contains("pot=REDACTED"))
        #expect(out.contains("id=abc"))
        #expect(!out.contains("SECRET123"))
        #expect(!out.contains("TOKEN"))
    }

    @Test func redactsCloudFrontAndAwsParams() {
        let cf = FailureLog.redact("?Policy=P1&Signature=S1&Key-Pair-Id=K1")
        #expect(cf.contains("Policy=REDACTED"))
        #expect(cf.contains("Signature=REDACTED"))
        #expect(cf.contains("Key-Pair-Id=REDACTED"))
        #expect(!cf.contains("P1") && !cf.contains("S1") && !cf.contains("K1"))

        let aws = FailureLog.redact("?X-Amz-Signature=AAA&X-Amz-Credential=BBB")
        #expect(aws.contains("X-Amz-Signature=REDACTED"))
        #expect(aws.contains("X-Amz-Credential=REDACTED"))
        #expect(!aws.contains("AAA") && !aws.contains("BBB"))
    }

    @Test func doesNotRedactNonSecretParams() {
        let url = "https://www.youtube.com/watch?v=abc123&t=42&list=PL1"
        #expect(FailureLog.redact(url) == url)
    }

    @Test func doesNotMatchParamNameSubstrings() {
        let s = "?monkey=ok&lowkey=ok"
        #expect(FailureLog.redact(s) == s)
    }

    @Test func recordedLineIsRedacted() {
        let log = FailureLog(directory: tempDir())
        log.record(url: "https://x.test/v", errorKind: "download_network",
                   detail: "... &sig=LEAK ...", date: Date(timeIntervalSince1970: 1))
        let contents = log.contents()
        #expect(contents.contains("REDACTED"))
        #expect(!contents.contains("LEAK"))
    }

    @Test func appendsEntriesAndStartsEmpty() {
        let log = FailureLog(directory: tempDir())
        #expect(log.hasEntries == false)
        log.record(url: "https://a.test/1", errorKind: "unsupported", date: Date(timeIntervalSince1970: 1))
        log.record(url: "https://b.test/2", errorKind: "timeout", date: Date(timeIntervalSince1970: 2))
        #expect(log.hasEntries == true)
        let lines = log.contents().split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0].contains("https://a.test/1") && lines[0].contains("unsupported"))
        #expect(lines[1].contains("https://b.test/2") && lines[1].contains("timeout"))
    }
}
