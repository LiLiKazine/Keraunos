import Testing
import Foundation
import KeraunosCore

struct PartFileTests {
    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("track.part")
    }

    @Test func appendCreatesFileAndGrowsLength() throws {
        let part = PartFile(url: tempFile())
        #expect(part.length() == 0)
        let afterFirst = try part.append(Data(repeating: 0xAB, count: 100))
        #expect(afterFirst == 100)
        let afterSecond = try part.append(Data(repeating: 0xCD, count: 50))
        #expect(afterSecond == 150)
        #expect(part.length() == 150)
    }

    @Test func truncateDiscardsUnrecordedTail() throws {
        // Simulate a crash: 100 bytes are "committed" (offset persisted elsewhere), then a
        // further 50 are appended but the crash happens before the offset is persisted. On
        // resume we truncate down to the committed offset — the file must end at 100 bytes.
        let url = tempFile()
        let part = PartFile(url: url)
        try part.append(Data(repeating: 0xAB, count: 100))   // committed offset = 100
        try part.append(Data(repeating: 0xFF, count: 50))    // un-recorded tail
        #expect(part.length() == 150)

        try part.truncate(to: 100)

        #expect(part.length() == 100)
        let bytes = try Data(contentsOf: url)
        #expect(bytes == Data(repeating: 0xAB, count: 100))   // only committed bytes survive
    }

    @Test func truncateOnAbsentFileYieldsEmptyFile() throws {
        let url = tempFile()
        try PartFile(url: url).truncate(to: 0)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(PartFile(url: url).length() == 0)
    }
}
