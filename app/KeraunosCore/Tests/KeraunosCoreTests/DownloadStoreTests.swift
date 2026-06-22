import Testing
import Foundation
import KeraunosCore

struct DownloadStoreTests {
    private func write(_ name: String, in dir: URL, modified: Date) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data().write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @Test func listsOnlyMP4FilesNewestFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Alphabetically "a" < "b", but a downloads list must surface the most recent
        // file first regardless of name.
        _ = try write("a.mp4", in: dir, modified: Date(timeIntervalSince1970: 100))
        _ = try write("b.mp4", in: dir, modified: Date(timeIntervalSince1970: 200))
        try Data().write(to: dir.appendingPathComponent("notes.txt"))

        let names = DownloadStore(directory: dir).savedFiles().map(\.lastPathComponent)
        #expect(names == ["b.mp4", "a.mp4"])
    }

    @Test func reportsFileSizeAndNilForMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("clip.mp4")
        try Data(count: 2048).write(to: file)
        let store = DownloadStore(directory: dir)
        #expect(store.fileSize(file) == 2048)
        #expect(store.fileSize(dir.appendingPathComponent("ghost.mp4")) == nil)
    }

    @Test func defaultDirectoryIsDocuments() {
        #expect(DownloadStore().directory.path.contains("/Documents"))
    }

    @Test func deleteRemovesFileAndDropsItFromListing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DownloadStore(directory: dir)
        let keep = dir.appendingPathComponent("keep.mp4")
        let drop = dir.appendingPathComponent("drop.mp4")
        try Data().write(to: keep)
        try Data().write(to: drop)

        try store.delete(drop)

        #expect(!FileManager.default.fileExists(atPath: drop.path))
        #expect(store.savedFiles().map(\.lastPathComponent) == ["keep.mp4"])
    }

    @Test func uniqueDestinationAvoidsClobberingExistingFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DownloadStore(directory: dir)

        #expect(store.uniqueDestination(for: "clip.mp4").lastPathComponent == "clip.mp4")
        try Data().write(to: dir.appendingPathComponent("clip.mp4"))
        #expect(store.uniqueDestination(for: "clip.mp4").lastPathComponent == "clip (2).mp4")
        try Data().write(to: dir.appendingPathComponent("clip (2).mp4"))
        #expect(store.uniqueDestination(for: "clip.mp4").lastPathComponent == "clip (3).mp4")
    }

    @Test func uniqueDestinationSanitizesPathSeparatorsInTitles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A title like "AC/DC – Live.mp4" must not be treated as a subdirectory path.
        let dest = DownloadStore(directory: dir).uniqueDestination(for: "AC/DC – Live.mp4")
        #expect(!dest.lastPathComponent.contains("/"))
        #expect(dest.deletingLastPathComponent().path == dir.path)   // stays in the store dir
    }

    @Test func uniqueDestinationNeutralizesPathTraversal() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = DownloadStore(directory: dir).uniqueDestination(for: "../../evil.mp4")
        #expect(dest.deletingLastPathComponent().path == dir.path)   // can't escape upward
        #expect(!dest.lastPathComponent.contains("/"))
    }

    @Test func uniqueDestinationFallsBackForEmptyOrDotNames() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = DownloadStore(directory: dir)
        #expect(!store.uniqueDestination(for: "   ").lastPathComponent.isEmpty)
        #expect(store.uniqueDestination(for: "..").deletingLastPathComponent().path == dir.path)
    }

    @Test func deleteIsIdempotentForMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Deleting an already-absent file must not throw — the list stays the source of
        // truth and a stale row should clear cleanly rather than surface an error.
        try DownloadStore(directory: dir).delete(dir.appendingPathComponent("ghost.mp4"))
    }
}
