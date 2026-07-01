import Testing
import Foundation
import KeraunosCore

extension StubNetworkSuite {
struct DownloaderTests {
    private func tempFile(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(name)
    }
    private func track(_ s: String = "https://x.test/v.mp4") -> MediaTrack {
        MediaTrack(url: URL(string: s)!, httpHeaders: [:], codec: "avc1", fileExtension: "mp4")
    }

    /// Chunked track helper (opts into ranged download).
    private func chunkedTrack(_ s: String = "https://x.test/v.mp4", chunk: Int) -> MediaTrack {
        MediaTrack(url: URL(string: s)!, httpHeaders: [:], codec: "avc1",
                   fileExtension: "mp4", chunkSize: chunk)
    }

    /// Serves `body` honoring the Range header with 206 + Content-Range (or a single
    /// 200 with the whole body when `ignoreRange`), counting requests. Thread-safe;
    /// the Downloader issues chunk requests serially so contention is nil in practice.
    final class ChunkServer: @unchecked Sendable {
        let body: Data
        let ignoreRange: Bool
        private let lock = NSLock()
        private var _count = 0
        init(body: Data, ignoreRange: Bool = false) { self.body = body; self.ignoreRange = ignoreRange }
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return _count }
        func respond(_ req: URLRequest) -> (HTTPURLResponse, Data) {
            lock.lock(); _count += 1; lock.unlock()
            if ignoreRange {
                return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
            }
            let raw = (req.value(forHTTPHeaderField: "Range") ?? "bytes=0-").dropFirst("bytes=".count)
            let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
            let start = Int(parts.first ?? "") ?? 0
            let end = min(Int(parts.count > 1 ? parts[1] : "") ?? (body.count - 1), body.count - 1)
            let slice = body.subdata(in: start..<(end + 1))
            let resp = HTTPURLResponse(url: req.url!, statusCode: 206, httpVersion: nil,
                headerFields: ["Content-Range": "bytes \(start)-\(end)/\(body.count)"])!
            return (resp, slice)
        }
    }

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock(); private var _v = 0.0
        var value: Double { lock.lock(); defer { lock.unlock() }; return _v }
        func set(_ v: Double) { lock.lock(); _v = v; lock.unlock() }
    }

    @Test func savesFileToDestination() async throws {
        let payload = Data("fake mp4 bytes".utf8)
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, payload)
        }
        let dest = tempFile("clip.mp4")
        try await Downloader(session: StubURLProtocol.session()).download(track(), to: dest)
        #expect(try Data(contentsOf: dest) == payload)
    }

    @Test func mapsHTTPErrorToDownloadNetwork() async throws {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await #expect(throws: KeraunosError.downloadNetwork) {
            try await Downloader(session: StubURLProtocol.session()).download(track(), to: tempFile("clip.mp4"))
        }
    }

    @Test func rejectsEmptyBodyInsteadOfSavingAZeroByteDud() async throws {
        // A 200 with no body would otherwise persist an unplayable 0-byte .mp4 and
        // report success; treat it as a (retryable) network failure and leave no file.
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data())
        }
        let dest = tempFile("clip.mp4")
        await #expect(throws: KeraunosError.downloadNetwork) {
            try await Downloader(session: StubURLProtocol.session()).download(track(), to: dest)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }

    @Test func mapsCancellationToCancelled() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await #expect(throws: KeraunosError.cancelled) {
            try await Downloader(session: StubURLProtocol.session()).download(track(), to: tempFile("clip.mp4"))
        }
    }

    @Test func sendsTrackHTTPHeaders() async throws {
        StubURLProtocol.lastRequest = nil
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("x".utf8))
        }
        let t = MediaTrack(url: URL(string: "https://x.test/v.mp4")!,
                           httpHeaders: ["X-Keraunos-Test": "yes", "Referer": "https://x.test/"],
                           codec: "avc1", fileExtension: "mp4")
        try await Downloader(session: StubURLProtocol.session()).download(t, to: tempFile("clip.mp4"))
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-Keraunos-Test") == "yes")
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer") == "https://x.test/")
    }

    @Test func chunkedDownloadAssemblesFullFileAcrossRangedRequests() async throws {
        let body = Data((0..<25).map { UInt8($0) })   // 25 bytes, chunk 10 → 3 requests
        let server = ChunkServer(body: body)
        StubURLProtocol.handler = { server.respond($0) }
        let dest = tempFile("clip.mp4")
        try await Downloader(session: StubURLProtocol.session()).download(chunkedTrack(chunk: 10), to: dest)
        #expect(try Data(contentsOf: dest) == body)
        #expect(server.requestCount == 3)
    }

    @Test func chunkedDownloadSendsRangeAndTrackHeaders() async throws {
        StubURLProtocol.lastRequest = nil
        let server = ChunkServer(body: Data((0..<5).map { UInt8($0) }))   // one chunk
        StubURLProtocol.handler = { server.respond($0) }
        let t = MediaTrack(url: URL(string: "https://x.test/v.mp4")!,
                           httpHeaders: ["Referer": "https://x.test/"],
                           codec: "avc1", fileExtension: "mp4", chunkSize: 10)
        try await Downloader(session: StubURLProtocol.session()).download(t, to: tempFile("clip.mp4"))
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=") == true)
        #expect(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Referer") == "https://x.test/")
    }

    @Test func chunkedDownloadFallsBackToWholeBodyOn200() async throws {
        let body = Data("the whole file".utf8)
        let server = ChunkServer(body: body, ignoreRange: true)   // server ignores Range → 200
        StubURLProtocol.handler = { server.respond($0) }
        let dest = tempFile("clip.mp4")
        try await Downloader(session: StubURLProtocol.session()).download(chunkedTrack(chunk: 4), to: dest)
        #expect(try Data(contentsOf: dest) == body)
        #expect(server.requestCount == 1)   // no further ranged requests after the 200
    }

    @Test func chunkedDownloadReportsProgressToCompletion() async throws {
        let server = ChunkServer(body: Data((0..<25).map { UInt8($0) }))
        StubURLProtocol.handler = { server.respond($0) }
        let progress = ProgressBox()
        try await Downloader(session: StubURLProtocol.session())
            .download(chunkedTrack(chunk: 10), to: tempFile("clip.mp4"), onProgress: { progress.set($0) })
        #expect(progress.value == 1.0)
    }

    @Test func chunkedDownloadMapsHTTPErrorToDownloadNetwork() async throws {
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        await #expect(throws: KeraunosError.downloadNetwork) {
            try await Downloader(session: StubURLProtocol.session()).download(chunkedTrack(chunk: 10), to: tempFile("clip.mp4"))
        }
    }

    @Test func chunkedDownloadMapsCancellation() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.cancelled) }
        await #expect(throws: KeraunosError.cancelled) {
            try await Downloader(session: StubURLProtocol.session()).download(chunkedTrack(chunk: 10), to: tempFile("clip.mp4"))
        }
    }
}
}
