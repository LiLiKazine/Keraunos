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
