import Testing
import Foundation
@testable import Keraunos

struct JSEvaluatorTests {
    @Test func capturesConsoleLogOutput() {
        let out = JSEvaluator.shared.evaluate("console.log(1 + 2);", timeoutMs: 1000)
        #expect(out == "3")
    }

    @Test func runsAFunctionAndReturnsItsLoggedResult() {
        let out = JSEvaluator.shared.evaluate(
            "console.log(function(a){ return a.split('').reverse().join(''); }('abc'));",
            timeoutMs: 1000)
        #expect(out == "cba")
    }

    @Test func returnsErrorSentinelOnSyntaxError() {
        let out = JSEvaluator.shared.evaluate("this is not valid js", timeoutMs: 1000)
        #expect(out.hasPrefix("__KERAUNOS_JS_ERROR__"))
    }

    @Test func environmentShimsAreAvailable() {
        let out = JSEvaluator.shared.evaluate("console.log(typeof atob, typeof navigator.userAgent, typeof setTimeout);", timeoutMs: 1000)
        #expect(out == "function string function")
    }
}
