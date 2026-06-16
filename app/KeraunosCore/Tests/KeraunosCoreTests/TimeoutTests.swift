import Testing
import Foundation
import KeraunosCore

struct TimeoutTests {
    @Test func returnsValueWhenOperationFinishesFirst() async throws {
        let value = try await withTimeout(.seconds(10)) { 42 }
        #expect(value == 42)
    }

    @Test func throwsTimedOutWhenOperationIsTooSlow() async {
        await #expect(throws: KeraunosError.timedOut) {
            try await withTimeout(.milliseconds(50)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
    }

    @Test func propagatesOperationError() async {
        await #expect(throws: KeraunosError.network) {
            try await withTimeout(.seconds(10)) {
                throw KeraunosError.network
            }
        }
    }

    @Test func timedOutHasUserFacingDescription() {
        #expect(KeraunosError.timedOut.errorDescription?.isEmpty == false)
    }
}
