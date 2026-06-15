import Testing
import Foundation
import KeraunosCore

struct DownloadStoreTests {
    @Test func listsOnlyMP4FilesSorted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: dir.appendingPathComponent("b.mp4"))
        try Data().write(to: dir.appendingPathComponent("a.mp4"))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))

        let names = DownloadStore(directory: dir).savedFiles().map(\.lastPathComponent)
        #expect(names == ["a.mp4", "b.mp4"])
    }

    @Test func defaultDirectoryIsDocuments() {
        #expect(DownloadStore().directory.path.contains("/Documents"))
    }
}
