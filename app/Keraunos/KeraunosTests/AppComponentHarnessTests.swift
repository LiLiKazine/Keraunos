import Foundation
import KeraunosCore
import Testing
@testable import Keraunos

@MainActor
struct AppComponentHarnessTests {
    @Test func storageLifetimeRemovesOwnedDirectoryAndPreferences() throws {
        var storage: AppHarnessStorage? = AppHarnessStorage()
        let directory = try #require(storage?.directory)
        let defaults = try #require(storage?.defaults)
        let suite = try #require(storage?.defaultsSuiteName)
        defaults.set(true, forKey: "cleanup-marker")

        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(defaults.persistentDomain(forName: suite) != nil)

        storage = nil

        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(defaults.persistentDomain(forName: suite) == nil)
    }

    @Test func adaptiveFixtureDerivesAnAdaptiveFormatSelection() {
        let adaptive = AppTestTransfer.job(
            state: .queued,
            kind: .adaptive(
                video: AppTestTransfer.track("v.part"),
                audio: AppTestTransfer.track("a.part")))

        #expect(adaptive.formatSelection.isAdaptive)
    }
}
