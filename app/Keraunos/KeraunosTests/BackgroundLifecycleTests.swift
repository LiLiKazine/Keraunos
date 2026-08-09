import Testing
import Foundation
@testable import Keraunos

@MainActor
struct BackgroundLifecycleTests {
    @Test func installsCompletionBeforeStartingSessionAndFinishesExactlyOnce() {
        let lifecycle = BackgroundEventLifecycle()
        var completionCount = 0

        lifecycle.handleEvents(completion: { completionCount += 1 }) {
            // A synchronous delegate drain makes ordering directly observable: this only fires
            // when the handler was installed before session creation opened the event floodgate.
            lifecycle.eventsDidFinish()
        }

        #expect(completionCount == 1)
        lifecycle.eventsDidFinish()

        #expect(completionCount == 1)
    }

    @Test func aSecondHandleCallCoalescesRatherThanOverwritingThePendingHandler() {
        let lifecycle = BackgroundEventLifecycle()
        var firstCount = 0
        var secondCount = 0

        lifecycle.handleEvents(completion: { firstCount += 1 }, startSession: {})
        lifecycle.handleEvents(completion: { secondCount += 1 }) {
            lifecycle.eventsDidFinish()
        }

        #expect(firstCount == 1)
        #expect(secondCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func delegateDrainWaitsForAllSubmittedCoordinatorWorkAndSignalsOnce() async {
        let firstStarted = BackgroundLifecycleLatch()
        let releaseFirst = BackgroundLifecycleLatch()
        let secondStarted = BackgroundLifecycleLatch()
        let releaseSecond = BackgroundLifecycleLatch()
        let finished = BackgroundLifecycleLatch()
        let events = BackgroundLifecycleEventLog()

        await confirmation("events finished", expectedCount: 1) { confirmed in
            let tracker = BackgroundEventProcessingTracker {
                await events.append("finish")
                confirmed()
                await finished.signal()
            }
            tracker.submit {
                await events.append("first-started")
                await firstStarted.signal()
                await releaseFirst.wait()
                await events.append("first-completed")
            }
            tracker.submit {
                // Models `taskDidFail`: failure handling still has persistence work that must be
                // included in the drain even though no downloaded file is produced.
                await events.append("failure-started")
                await secondStarted.signal()
                await releaseSecond.wait()
                await events.append("failure-completed")
            }
            tracker.eventsDidDrain()

            await firstStarted.wait()
            #expect(!(await events.values()).contains("finish"))
            #expect(!(await events.values()).contains("failure-started"))
            await releaseFirst.signal()
            await secondStarted.wait()
            #expect(!(await events.values()).contains("finish"))
            await releaseSecond.signal()
            await finished.wait()
            #expect(await events.values() == [
                "first-started", "first-completed", "failure-started",
                "failure-completed", "finish"
            ])
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func highVolumeProgressIsBoundedAndLatestValueRunsBeforeDrain() async {
        let firstStarted = BackgroundLifecycleLatch()
        let releaseFirst = BackgroundLifecycleLatch()
        let finished = BackgroundLifecycleLatch()
        let values = BackgroundLifecycleValueLog()

        let tracker = BackgroundEventProcessingTracker {
            await values.finish()
            await finished.signal()
        }
        tracker.submitProgress(taskIdentifier: 7) {
            await values.append(0)
            await firstStarted.signal()
            await releaseFirst.wait()
        }
        await firstStarted.wait()

        for value in 1...10_000 {
            tracker.submitProgress(taskIdentifier: 7) {
                await values.append(value)
            }
        }
        tracker.eventsDidDrain()
        await releaseFirst.signal()
        await finished.wait()

        #expect(await values.progressValues() == [0, 10_000])
        #expect(await values.finishedAfterLatestProgress())
    }

    @Test func stagingOwnerReconcilesRegularAndSymlinkChildrenWithoutFollowingTarget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeraunosStagingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let owner = try TransferStagingStore(directory: staging)
        let stale = staging.appendingPathComponent("stale-body")
        try Data("stale".utf8).write(to: stale)
        let sentinel = root.appendingPathComponent("sentinel")
        let sentinelBytes = Data("preserve".utf8)
        try sentinelBytes.write(to: sentinel)
        let hostileLink = staging.appendingPathComponent("hostile-link")
        try FileManager.default.createSymbolicLink(at: hostileLink, withDestinationURL: sentinel)

        var failures: [String] = []
        let removed = try owner.reconcile { name, _ in failures.append(name) }

        #expect(removed == ["hostile-link", "stale-body"])
        #expect(failures.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(!FileManager.default.fileExists(atPath: hostileLink.path))
        #expect(try Data(contentsOf: sentinel) == sentinelBytes)
        let fixedID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        #expect(try owner.newFileURL(id: fixedID).lastPathComponent == fixedID.uuidString)
    }

    @Test func stagingOwnerRejectsSymlinkAndNonDirectoryRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeraunosStagingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let file = root.appendingPathComponent("plain-file")
        try Data().write(to: file)

        #expect(throws: (any Error).self) { _ = try TransferStagingStore(directory: link) }
        #expect(throws: (any Error).self) { _ = try TransferStagingStore(directory: file) }
        #expect(throws: (any Error).self) {
            _ = try BackgroundTransferService(stagingDirectory: link)
        }
    }

    @Test func serviceRevalidatesStagingBeforeOpeningDelegateDelivery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("KeraunosStagingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let service = try BackgroundTransferService(stagingDirectory: staging)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: staging)
        try FileManager.default.createSymbolicLink(at: staging, withDestinationURL: target)

        #expect(throws: (any Error).self) { try service.createSession() }
    }
}

private actor BackgroundLifecycleLatch {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isSignaled else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let waiters = waiters
        self.waiters = []
        for waiter in waiters { waiter.resume() }
    }
}

private actor BackgroundLifecycleEventLog {
    private var storage: [String] = []
    func append(_ value: String) { storage.append(value) }
    func values() -> [String] { storage }
}

private actor BackgroundLifecycleValueLog {
    private var values: [Int] = []
    private var didFinish = false

    func append(_ value: Int) { values.append(value) }
    func finish() { didFinish = true }
    func progressValues() -> [Int] { values }
    func finishedAfterLatestProgress() -> Bool { didFinish && values.last == 10_000 }
}
