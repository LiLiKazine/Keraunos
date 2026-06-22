import Testing
import Foundation
@testable import KeraunosCore

struct DownloadProgressDelegateTests {
    /// Reference collector so the @Sendable progress closure can record without
    /// capturing a mutable var (the calls here are synchronous, so no real races).
    private final class Collector: @unchecked Sendable { var values: [Double] = [] }

    private func makeTask() -> URLSessionDownloadTask {
        URLSession(configuration: .ephemeral).downloadTask(with: URL(string: "https://x.test/v.mp4")!)
    }

    @Test func reportsCompletionFractionFromBytes() {
        let reported = Collector()
        let delegate = DownloadProgressDelegate { reported.values.append($0) }
        let task = makeTask()
        delegate.urlSession(.shared, downloadTask: task,
                            didWriteData: 25, totalBytesWritten: 25, totalBytesExpectedToWrite: 100)
        delegate.urlSession(.shared, downloadTask: task,
                            didWriteData: 75, totalBytesWritten: 100, totalBytesExpectedToWrite: 100)
        #expect(reported.values == [0.25, 1.0])
    }

    @Test func ignoresUnknownTotalSize() {
        // A length-unknown response reports total == -1; we must not emit a bogus fraction.
        let reported = Collector()
        let delegate = DownloadProgressDelegate { reported.values.append($0) }
        delegate.urlSession(.shared, downloadTask: makeTask(),
                            didWriteData: 10, totalBytesWritten: 10, totalBytesExpectedToWrite: -1)
        #expect(reported.values.isEmpty)
    }
}
