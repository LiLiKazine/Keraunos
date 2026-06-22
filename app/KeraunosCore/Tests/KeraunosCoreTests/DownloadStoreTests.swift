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

    @Test func deleteIsIdempotentForMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Deleting an already-absent file must not throw — the list stays the source of
        // truth and a stale row should clear cleanly rather than surface an error.
        try DownloadStore(directory: dir).delete(dir.appendingPathComponent("ghost.mp4"))
    }
}
