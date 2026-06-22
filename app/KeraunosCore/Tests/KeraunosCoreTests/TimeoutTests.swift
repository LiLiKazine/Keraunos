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
            try await withTimeout(.milliseconds(200)) {
                try await Task.sleep(for: .seconds(10))
                return 1
            }
        }
    }

    @Test func propagatesOperationError() async {
        await #expect(throws: KeraunosError.downloadNetwork) {
            try await withTimeout(.seconds(10)) {
                throw KeraunosError.downloadNetwork
            }
        }
    }

    @Test func timedOutHasUserFacingDescription() {
        #expect(KeraunosError.timedOut.errorDescription?.isEmpty == false)
    }
}
