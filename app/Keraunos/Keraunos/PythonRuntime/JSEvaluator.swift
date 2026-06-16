import Foundation
import JavaScriptCore

/// In-process JavaScript evaluator backed by JavaScriptCore. yt-dlp builds a
/// self-contained snippet that prints its result via `console.log(...)`; we install
/// a console.log shim that captures that output and return it. Used to run YouTube's
/// nsig function (and, in Phase C, BotGuard) without a subprocess.
///
/// A single shared, long-lived context is reused so Phase C can install network /
/// timer / global shims once. This means global JS state (and any globals a script
/// defines) persists across `evaluate` calls — only the console.log capture buffer is
/// reset each call — so callers must not rely on a clean slate; Phase C shims live for
/// the context's lifetime.
///
/// The app target sets `-default-isolation=MainActor`, which would normally infer
/// `@MainActor` on this type. We explicitly opt out with `nonisolated` throughout
/// and serialise all access through `NSLock`, making the type safe to call from any
/// actor or queue. The `@unchecked Sendable` conformance documents that invariant.
final class JSEvaluator: @unchecked Sendable {

    // Lazy initialisation avoids running `init` at MainActor-default call sites:
    // the singleton is created on first access, which can happen from any context
    // because `_shared` is nonisolated(unsafe) and `makeShared()` is nonisolated.
    nonisolated(unsafe) private static var _shared: JSEvaluator?
    // nonisolated(unsafe) is required here: even though NSLock is Sendable, the
    // -default-isolation=MainActor project flag would otherwise infer @MainActor on
    // this static stored property, making it unreachable from `nonisolated shared`.
    nonisolated private static let sharedLock = NSLock()

    nonisolated static var shared: JSEvaluator {
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let existing = _shared { return existing }
        let instance = JSEvaluator()
        _shared = instance
        return instance
    }

    // `nonisolated(unsafe)` suppresses @MainActor propagation from JSContext in
    // the presence of -default-isolation=MainActor. Access is serialised by `lock`.
    nonisolated(unsafe) private let context: JSContext
    nonisolated(unsafe) private var buffer = ""
    private let lock = NSLock()

    nonisolated private init() {
        context = JSContext()!
        installEnvironment()
    }

    /// Evaluates `script`, returning whatever it printed via console.log (trimmed),
    /// or a string prefixed "__KERAUNOS_JS_ERROR__" on a JS exception.
    nonisolated func evaluate(_ script: String, timeoutMs: Double) -> String {
        lock.lock()
        defer { lock.unlock() }
        buffer = ""
        context.exception = nil
        // timeout is advisory — enforced by the caller (Phase A withTimeout), not by JavaScriptCore.
        applyExecutionTimeLimit(seconds: timeoutMs / 1000.0)
        context.evaluateScript(script)
        if let exception = context.exception {
            return "__KERAUNOS_JS_ERROR__\(exception.toString() ?? "unknown")"
        }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private func installEnvironment() {
        installConsole()
        // globalThis / self / window aliases
        context.evaluateScript("var self = this; var window = this; var globalThis = this;")
        // atob / btoa
        let atob: @convention(block) (String) -> String = { Data(base64Encoded: $0).flatMap { String(data: $0, encoding: .isoLatin1) } ?? "" }
        let btoa: @convention(block) (String) -> String = { ($0.data(using: .isoLatin1) ?? Data()).base64EncodedString() }
        context.setObject(atob, forKeyedSubscript: "atob" as NSString)
        context.setObject(btoa, forKeyedSubscript: "btoa" as NSString)
        // minimal navigator
        context.evaluateScript("var navigator = { userAgent: 'Mozilla/5.0', languages: ['en-US'] };")
        // setTimeout: run the callback immediately (no real timers in this context)
        let setTimeout: @convention(block) (JSValue, Double) -> Void = { fn, _ in fn.call(withArguments: []) }
        context.setObject(setTimeout, forKeyedSubscript: "setTimeout" as NSString)
    }

    nonisolated private func installConsole() {
        // Use a JS wrapper so `arguments` captures all variadic args, then
        // calls back into a Swift block with a pre-joined string.
        let logImpl: @convention(block) (String) -> Void = { [weak self] joined in
            self?.buffer += joined + "\n"
        }
        context.setObject(logImpl, forKeyedSubscript: "__keraunos_log_impl" as NSString)
        context.evaluateScript("""
            var console = {
              log: function() {
                var parts = Array.prototype.slice.call(arguments).map(function(a){ return String(a); });
                __keraunos_log_impl(parts.join(' '));
              }
            };
            """)
    }

    /// No-op: `JSContextGroupSetExecutionTimeLimit` is not exported in the iOS SDK
    /// headers (it is a WebKit-internal API on iOS). The outer Phase A `withTimeout`
    /// is the real execution bound; this method exists as a hook for future use.
    nonisolated private func applyExecutionTimeLimit(seconds: Double) {}
}

/// C-callable entry point for the Python bridge (Task 4). Returns a malloc'd UTF-8
/// string the caller must free().
@_cdecl("keraunos_js_eval")
public func keraunos_js_eval(_ script: UnsafePointer<CChar>?, _ timeoutMs: Double) -> UnsafeMutablePointer<CChar>? {
    let source = script.map { String(cString: $0) } ?? ""
    let result = JSEvaluator.shared.evaluate(source, timeoutMs: timeoutMs)
    return strdup(result)
}
