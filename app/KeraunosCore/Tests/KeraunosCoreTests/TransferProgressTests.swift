import Testing
import Foundation
@testable import KeraunosCore

@Suite struct TransferProgressTests {
    private func snap(_ received: Int64, _ total: Int64?, _ state: JobState = .downloading) -> ProgressSnapshot {
        ProgressSnapshot(state: state, receivedBytes: received, totalBytes: total)
    }

    @Test func fractionIsReceivedOverTotal() {
        #expect(snap(50, 200).fraction == 0.25)
    }

    @Test func fractionIsNilWhenTotalUnknownOrZero() {
        #expect(snap(50, nil).fraction == nil)
        #expect(snap(50, 0).fraction == nil)
    }

    @Test func setAndReadBack() async {
        let bus = TransferProgress()
        let id = UUID()
        await bus.set(snap(10, 100), for: id)
        #expect(await bus.snapshot(for: id) == snap(10, 100))
        #expect(await bus.current()[id]?.receivedBytes == 10)
    }

    @Test func removeDropsTheEntry() async {
        let bus = TransferProgress()
        let id = UUID()
        await bus.set(snap(10, 100), for: id)
        await bus.remove(id)
        #expect(await bus.snapshot(for: id) == nil)
    }

    @Test func updatesEmitsCurrentThenOnEachChange() async {
        let bus = TransferProgress()
        let id = UUID()
        await bus.set(snap(10, 100), for: id)   // pre-existing entry

        var iterator = (await bus.updates()).makeAsyncIterator()
        let first = await iterator.next()        // immediate current snapshot
        #expect(first?[id]?.receivedBytes == 10)

        await bus.set(snap(60, 100), for: id)
        let second = await iterator.next()
        #expect(second?[id]?.receivedBytes == 60)

        await bus.remove(id)
        let third = await iterator.next()
        #expect(third?[id] == nil)
    }
}
