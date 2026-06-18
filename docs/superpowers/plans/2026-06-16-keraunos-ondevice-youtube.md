# Keraunos On-Device YouTube Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make YouTube downloads work on-device (signed-in) and guarantee no extraction can ever hang, by giving the embedded Python an in-process JavaScript runtime via iOS `JavaScriptCore`.

**Architecture:** Three layered phases on one new capability — a `JSContext`-backed evaluator exposed to the embedded CPython. **Phase A** wraps extraction in a wall-clock timeout (`withTimeout` + `KeraunosError.timedOut`). **Phase B** adds the native JS-eval bridge and routes YouTube's `nsig` challenge through it (off the pathological pure-Python path). **Phase C** (research spike) runs BotGuard attestation JS in the same bridge to mint PO tokens, with explicit graceful degradation to A+B if it proves infeasible.

**Tech Stack:** Swift 6 / SwiftUI, Swift Testing, `JavaScriptCore.framework` (ObjC + Swift), embedded CPython 3.13 + yt-dlp (`2025.10.14`, pinned), the `KeraunosCore` SwiftPM package, vendored `bgutils-js` (Phase C).

**Design source of truth:** `docs/superpowers/specs/2026-06-16-keraunos-ondevice-youtube-design.md`.

---

## Conventions (read once)

- **Repo root:** `/Users/leo/Developer/Keraunos`. Run all commands from there.
- **Branch:** `feat/ondevice-youtube` (already cut off `main`, which now includes the auth milestone).
- **App project / scheme:** `app/Keraunos/Keraunos.xcodeproj`, scheme `Keraunos`.
- **Core test command** (fast — macOS, no simulator):
  ```bash
  swift test --package-path app/KeraunosCore
  ```
  Single suite: `swift test --package-path app/KeraunosCore --filter TimeoutTests`.
- **App test command** (define `DEST` once):
  ```bash
  DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
  xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests
  ```
  If unavailable, pick one from `xcrun simctl list devices available | grep iPhone`.
- **Python dev tests:**
  ```bash
  cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
  ```
- **App-target compiles throughout:** every Swift API added is either new or has a defaulted parameter, so `ContentView`'s `PythonExtractor(cookieProvider:)` keeps compiling. No intentional red period in Phases A/B.
- **Isolation rule (unchanged):** `KeraunosCore` is `nonisolated`-default and pure. `PythonExtractor` is an `actor` on its own serial executor; the blocking Python C call MUST run on that executor. `withTimeout`'s operation closure therefore calls back into an actor-isolated method (`await self.blockingExtract(...)`) so the C call hops to the serial executor while the timeout's `Task.sleep` runs on the cooperative pool. The orphaned C call (on timeout) keeps running on the serial executor until it returns — documented, acceptable.
- **JS runtime constraint:** the embedded interpreter has no `subprocess`/`fork`. `JavaScriptCore` runs JS in-process and is the only viable JS runtime. nsig JS itself is fast (milliseconds); the prior hang was the pure-Python *interpreter*, not the JS.
- **Commits:** use the `structured-commit` skill. The `git commit` lines below give the summary; let the skill expand the body. End messages with the `Co-Authored-By` trailer.
- **TDD:** pure/logic tasks (Phase A; Phase B Python glue) are test-first. Interpreter/bridge/UI/JSC-integration tasks are verified by build + Swift `JSEvaluator` tests + device acceptance, per the spec's testing section.

---

## File Structure

```
app/KeraunosCore/Sources/KeraunosCore/
  Timeout.swift                 # Task 1 (NEW — withTimeout helper)
  KeraunosError.swift           # Task 1 (add .timedOut)

app/KeraunosCore/Tests/KeraunosCoreTests/
  TimeoutTests.swift            # Task 1 (NEW)

app/Keraunos/Keraunos/PythonRuntime/
  PythonExtractor.swift         # Task 2 (wrap resolve in withTimeout)
  JSEvaluator.swift             # Task 3 (NEW — Swift JavaScriptCore evaluator + @_cdecl shim)
  PythonBridge.h                # Task 4 (declare keraunos_js_eval; register keraunos_native)
  PythonBridge.m                # Task 4 (PyInit_keraunos_native + AppendInittab)

app/Keraunos/KeraunosTests/
  JSEvaluatorTests.swift        # Task 3 (NEW)

app/Keraunos/PythonResources/app/
  keraunos_extract.py           # Task 5 (JavaScriptCoreWrapper + nsig monkeypatch)
  keraunos_youtube_pot.py       # Task 8 (NEW — KeraunosPoTokenProvider)
  bgutils/                      # Task 7 (NEW — vendored bgutils-js bundle)
app/Keraunos/python-dev/
  test_jscwrapper.py            # Task 5 (NEW — fake-backend tests + drift guard)
  test_pot_provider.py          # Task 8 (NEW)
  requirements.txt              # Task 6 (pin yt-dlp==2025.10.14)
```

---

# PHASE A — Bounded extraction (no infinite "Resolving…")

## Task 1: `withTimeout` helper + `KeraunosError.timedOut` (Core, pure)

**Files:**
- Modify: `app/KeraunosCore/Sources/KeraunosCore/KeraunosError.swift`
- Create: `app/KeraunosCore/Sources/KeraunosCore/Timeout.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/TimeoutTests.swift`

- [ ] **Step 1: Write the failing tests** — create `TimeoutTests.swift`:

```swift
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
```

- [ ] **Step 2: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter TimeoutTests
```
Expected: FAIL — `cannot find 'withTimeout' in scope` / `type 'KeraunosError' has no member 'timedOut'`.

- [ ] **Step 3: Add the `.timedOut` case** — in `KeraunosError.swift`, add the case to the enum (after `case mergeFailed`):

```swift
    case timedOut
```
and add its description in the `errorDescription` switch (after the `.mergeFailed` case):
```swift
        case .timedOut:           return "Extraction took too long and was stopped."
```

- [ ] **Step 4: Create `Timeout.swift`**

```swift
import Foundation

/// Runs `operation` with an overall wall-clock bound. Returns its value if it
/// finishes within `duration`; otherwise throws `KeraunosError.timedOut`. The
/// operation and a sleeping timer race in a task group — whichever finishes first
/// wins and the loser is cancelled.
///
/// Note: cancelling the operation does not interrupt a synchronous blocking call
/// that has no cancellation point (e.g. a CPython C call); such work keeps running
/// until it returns. Callers that wrap blocking work must run it on a dedicated
/// executor so an orphaned call does not occupy a shared thread — see PythonExtractor.
public func withTimeout<T: Sendable>(
    _ duration: Duration,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: duration)
            throw KeraunosError.timedOut
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw KeraunosError.timedOut
        }
        return result
    }
}
```

- [ ] **Step 5: Run it, expect pass** — same command as Step 2. Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/Timeout.swift \
        app/KeraunosCore/Sources/KeraunosCore/KeraunosError.swift \
        app/KeraunosCore/Tests/KeraunosCoreTests/TimeoutTests.swift
git commit -m "feat(core): add withTimeout helper and KeraunosError.timedOut"
```

---

## Task 2: Wrap `PythonExtractor.resolve` in `withTimeout`

**Files:**
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`

> Interpreter-bound — no unit test (the timeout mechanism itself is covered by Task 1). Verified by app build + Task 11 acceptance.

- [ ] **Step 1: Add an injectable timeout + split out the blocking call** — replace the stored properties / init / `resolve` block. Replace:

```swift
    private let cookieProvider: (any CookieProviding)?

    init(cookieProvider: (any CookieProviding)? = nil) {
        self.cookieProvider = cookieProvider
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try ensureInitialized()
        let cookieURL = await cookieProvider?.cookieFile()
        defer { if let cookieURL { try? FileManager.default.removeItem(at: cookieURL) } }
        guard let cString = keraunos_python_extract(url.absoluteString, cookieURL?.path) else {
            throw KeraunosError.runtime(detail: "null extraction result")
        }
        defer { free(cString) }
        return try ExtractionDecoder.decode(Data(String(cString: cString).utf8))
    }
```
with:
```swift
    private let cookieProvider: (any CookieProviding)?
    private let timeout: Duration

    init(cookieProvider: (any CookieProviding)? = nil, timeout: Duration = .seconds(45)) {
        self.cookieProvider = cookieProvider
        self.timeout = timeout
    }

    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try ensureInitialized()
        let cookieURL = await cookieProvider?.cookieFile()
        defer { if let cookieURL { try? FileManager.default.removeItem(at: cookieURL) } }
        let cookiePath = cookieURL?.path
        // The blocking C call runs on this actor's serial executor (via the
        // actor-isolated blockingExtract); the timeout's timer runs on the
        // cooperative pool. On timeout the C call is orphaned on the serial
        // executor until it returns — the next resolve queues behind it.
        return try await withTimeout(timeout) { [self] in
            try await blockingExtract(url, cookiePath: cookiePath)
        }
    }

    private func blockingExtract(_ url: URL, cookiePath: String?) throws -> ResolvedMedia {
        guard let cString = keraunos_python_extract(url.absoluteString, cookiePath) else {
            throw KeraunosError.runtime(detail: "null extraction result")
        }
        defer { free(cString) }
        return try ExtractionDecoder.decode(Data(String(cString: cString).utf8))
    }
```

> `blockingExtract` is actor-isolated (synchronous). Calling it as `await blockingExtract(...)` from the non-isolated task-group closure hops onto the actor's serial executor, preserving the single-interpreter serialization the custom executor guarantees.

- [ ] **Step 2: Build the app target, expect success**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED` (`ContentView`'s `PythonExtractor(cookieProvider:)` still compiles via the defaulted `timeout`).

- [ ] **Step 3: Run the app test suite (nothing regressed)**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests 2>&1 | grep -iE "error:|\*\* TEST"
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift
git commit -m "feat(app): bound extraction with an overall wall-clock timeout"
```

> **Phase A is shippable here:** a pathological extraction now fails with `.timedOut` after 45s instead of hanging — including the YouTube nsig case, until Phase B fixes it properly.

---

# PHASE B — JavaScriptCore eval bridge + nsig

## Task 3: Swift `JSEvaluator` (JavaScriptCore) + C-callable shim

**Files:**
- Create: `app/Keraunos/Keraunos/PythonRuntime/JSEvaluator.swift`
- Test: `app/Keraunos/KeraunosTests/JSEvaluatorTests.swift`

> The evaluator is a plain Swift type using `import JavaScriptCore`, so it is unit-testable directly. A `@_cdecl` shim makes it callable from the C/Python bridge (Task 4).

- [ ] **Step 1: Write the failing tests** — create `JSEvaluatorTests.swift`:

```swift
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
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/JSEvaluatorTests 2>&1 | grep -iE "cannot find|error:|\*\* TEST"
```
Expected: FAIL — `cannot find 'JSEvaluator' in scope`.

- [ ] **Step 3: Implement `JSEvaluator.swift`**

```swift
import Foundation
import JavaScriptCore

/// In-process JavaScript evaluator backed by JavaScriptCore. yt-dlp builds a
/// self-contained snippet that prints its result via `console.log(...)`; we install
/// a console.log shim that captures that output and return it. Used to run YouTube's
/// nsig function (and, in Phase C, BotGuard) without a subprocess.
///
/// A single shared, long-lived context is reused so Phase C can install network /
/// timer / global shims once.
final class JSEvaluator: @unchecked Sendable {
    static let shared = JSEvaluator()

    private let context: JSContext
    private var buffer = ""
    private let lock = NSLock()

    private init() {
        context = JSContext()
        installConsole()
    }

    /// Evaluates `script`, returning whatever it printed via console.log (trimmed),
    /// or a string prefixed "__KERAUNOS_JS_ERROR__" on a JS exception.
    func evaluate(_ script: String, timeoutMs: Double) -> String {
        lock.lock()
        defer { lock.unlock() }
        buffer = ""
        context.exception = nil
        // Best-effort hard backstop; the outer Phase A timeout is the real guarantee.
        applyExecutionTimeLimit(seconds: timeoutMs / 1000.0)
        context.evaluateScript(script)
        if let exception = context.exception {
            return "__KERAUNOS_JS_ERROR__\(exception.toString() ?? "unknown")"
        }
        return buffer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installConsole() {
        let console = JSValue(newObjectIn: context)
        let log: @convention(block) (JSValue) -> Void = { [weak self] value in
            self?.buffer += (value.toString() ?? "") + "\n"
        }
        console?.setValue(log, forProperty: "log")
        context.setObject(console, forKeyedSubscript: "console" as NSString)
    }

    private func applyExecutionTimeLimit(seconds: Double) {
        // JSContextGroupSetExecutionTimeLimit is a JSContextRef C API. If it is
        // unavailable in this SDK, the outer withTimeout (Phase A) still bounds us,
        // so a no-op here is acceptable.
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        JSContextGroupSetExecutionTimeLimit(group, seconds, nil, nil)
    }
}

/// C-callable entry point for the Python bridge (Task 4). Returns a malloc'd UTF-8
/// string the caller must free().
@_cdecl("keraunos_js_eval")
public func keraunos_js_eval(_ script: UnsafePointer<CChar>?, _ timeoutMs: Double) -> UnsafeMutablePointer<CChar>? {
    let source = script.map { String(cString: $0) } ?? ""
    let result = JSEvaluator.shared.evaluate(source, timeoutMs: timeoutMs)
    return strdup(result)
}
```

> If `JSContextGetGroup` / `JSContextGroupSetExecutionTimeLimit` fail to resolve (private/unavailable in the iOS SDK headers), delete the two lines in `applyExecutionTimeLimit` and leave it empty — Phase A's `withTimeout` is the real bound. Note this in the commit if so.

- [ ] **Step 4: Run it, expect pass** — same command as Step 2 (drop `grep` to see results). Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/JSEvaluator.swift \
        app/Keraunos/KeraunosTests/JSEvaluatorTests.swift
git commit -m "feat(app): add JavaScriptCore-backed JSEvaluator with console.log capture"
```

---

## Task 4: Expose `keraunos_native.eval_js` to the embedded Python

**Files:**
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h`
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m`

> Bridge-bound — no unit test. Verified by app build now and by Task 5/11.

- [ ] **Step 1: Declare the Swift shim in `PythonBridge.h`** — add after the existing `keraunos_python_extract` declaration:

```objc
// Implemented in Swift (@_cdecl). Evaluates JS via JavaScriptCore and returns a
// malloc'd UTF-8 string the caller must free(). On JS error the string is prefixed
// "__KERAUNOS_JS_ERROR__".
char *keraunos_js_eval(const char *script, double timeoutMs);
```

- [ ] **Step 2: Add the `keraunos_native` module in `PythonBridge.m`** — add the module definition near the top (after the `#import`s and `static int gInitialized`):

```objc
// keraunos_native.eval_js(script: str, timeout_ms: float) -> str
static PyObject *keraunos_native_eval_js(PyObject *self, PyObject *args) {
    const char *script = NULL;
    double timeout_ms = 5000.0;
    if (!PyArg_ParseTuple(args, "s|d", &script, &timeout_ms)) return NULL;
    char *out = keraunos_js_eval(script, timeout_ms);
    PyObject *result = PyUnicode_FromString(out ? out : "__KERAUNOS_JS_ERROR__null");
    if (out) free(out);
    return result;
}

static PyMethodDef keraunos_native_methods[] = {
    {"eval_js", keraunos_native_eval_js, METH_VARARGS, "Evaluate JS via JavaScriptCore."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef keraunos_native_module = {
    PyModuleDef_HEAD_INIT, "keraunos_native", NULL, -1, keraunos_native_methods,
    NULL, NULL, NULL, NULL,
};

static PyObject *PyInit_keraunos_native(void) {
    return PyModule_Create(&keraunos_native_module);
}
```

- [ ] **Step 3: Register the module before interpreter init** — in `keraunos_python_init`, add this line **before** the `Py_PreInitialize(&preconfig)` call (PyImport_AppendInittab must run before the interpreter starts):

```objc
    PyImport_AppendInittab("keraunos_native", PyInit_keraunos_native);
```

- [ ] **Step 4: Build the app target, expect success**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h \
        app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m
git commit -m "feat(app): expose keraunos_native.eval_js to the embedded interpreter"
```

---

## Task 5: `JavaScriptCoreWrapper` + nsig monkeypatch (Python)

**Files:**
- Modify: `app/Keraunos/PythonResources/app/keraunos_extract.py`
- Create: `app/Keraunos/python-dev/test_jscwrapper.py`

> The wrapper's eval backend is injectable so pytest can run it without the native `keraunos_native` module. Device behavior is verified in Task 11.

- [ ] **Step 1: Write the failing tests** — create `test_jscwrapper.py`:

```python
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "PythonResources" / "app"
sys.path.insert(0, str(APP))
import keraunos_extract  # noqa: E402


def test_wrapper_calls_eval_backend_and_returns_output():
    calls = []
    keraunos_extract.set_js_evaluator(lambda script, timeout_ms: calls.append(script) or "  4321  ")
    w = keraunos_extract.JavaScriptCoreWrapper(extractor=None)
    out = w.execute("console.log(1234);", video_id="vid")
    assert out == "4321"          # stripped
    assert calls and "console.log" in calls[0]


def test_nsig_monkeypatch_targets_still_exist():
    # Drift guard: the symbols our monkeypatch reaches into must exist in the pinned
    # yt-dlp. If this fails after a yt-dlp bump, the nsig patch needs revisiting.
    from yt_dlp.extractor.youtube._video import YoutubeIE
    assert hasattr(YoutubeIE, "_decrypt_nsig")
    assert hasattr(YoutubeIE, "_extract_n_function_code")


def test_install_youtube_js_runtime_patches_decrypt_nsig():
    from yt_dlp.extractor.youtube._video import YoutubeIE
    original = YoutubeIE._decrypt_nsig
    keraunos_extract.install_youtube_js_runtime()
    assert YoutubeIE._decrypt_nsig is not original  # patched
```

- [ ] **Step 2: Run it, expect failure**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q test_jscwrapper.py ; cd /Users/leo/Developer/Keraunos
```
Expected: FAIL — `module 'keraunos_extract' has no attribute 'set_js_evaluator'`.

- [ ] **Step 3: Implement** — in `keraunos_extract.py`, add near the top imports:

```python
from yt_dlp.jsinterp import JSInterpreter
```
Then add, after the existing module-level constants (e.g. after `_AUTH_HINTS`):

```python
# --- JavaScript runtime (JavaScriptCore) -----------------------------------------
# yt-dlp solves YouTube's nsig challenge with a JS runtime. The embedded interpreter
# has no subprocess, so we route nsig through the app's in-process JavaScriptCore via
# keraunos_native.eval_js. The pure-Python JSInterpreter path is skipped entirely —
# on-device it is pathologically slow (the original "stuck on Resolving…" hang).

_JS_EVALUATOR = None   # test seam; when None, the real keraunos_native is used.


def set_js_evaluator(fn):
    """Inject a fake eval backend `fn(script, timeout_ms) -> str` for tests."""
    global _JS_EVALUATOR
    _JS_EVALUATOR = fn


def _eval_js(script, timeout_ms=5000):
    if _JS_EVALUATOR is not None:
        return _JS_EVALUATOR(script, timeout_ms)
    import keraunos_native
    return keraunos_native.eval_js(script, timeout_ms)


class JavaScriptCoreWrapper:
    """Drop-in for yt-dlp's PhantomJSwrapper: runs a self-contained JS snippet that
    prints its result via console.log and returns that output."""

    def __init__(self, extractor, required_version=None, timeout=5000):
        self.extractor = extractor
        self.timeout = timeout

    def execute(self, jscode, video_id=None, *, note='Executing JS'):
        out = _eval_js(jscode, self.timeout)
        if out.startswith("__KERAUNOS_JS_ERROR__"):
            raise RuntimeError(f"JavaScriptCore eval failed: {out[len('__KERAUNOS_JS_ERROR__'):]}")
        return out.strip()


def install_youtube_js_runtime():
    """Patch YoutubeIE so nsig is computed via JavaScriptCore, never pure-Python."""
    from yt_dlp.extractor.youtube import _video
    from yt_dlp.utils import urljoin

    def _decrypt_nsig_via_jsc(self, s, video_id, player_url):
        if player_url is None:
            from yt_dlp.utils import ExtractorError
            raise ExtractorError('Cannot decrypt nsig without player_url')
        player_url = urljoin('https://www.youtube.com', player_url)
        _jsi, _name, func_code = self._extract_n_function_code(video_id, player_url)
        args, func_body = func_code
        snippet = 'console.log(function(%s) { %s }(%r));' % (", ".join(args), func_body, s)
        ret = JavaScriptCoreWrapper(self).execute(snippet, video_id=video_id)
        self._store_player_data_to_cache('nsig', player_url, func_code)
        return ret

    _video.YoutubeIE._decrypt_nsig = _decrypt_nsig_via_jsc
```

Finally, call `install_youtube_js_runtime()` once at import time — add at the very bottom of the module:
```python
try:
    install_youtube_js_runtime()
except Exception:
    pass   # fail open: fall back to yt-dlp's default nsig path
```

- [ ] **Step 4: Run it, expect pass**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: all tests pass (new `test_jscwrapper.py` + the existing suites).

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/PythonResources/app/keraunos_extract.py \
        app/Keraunos/python-dev/test_jscwrapper.py
git commit -m "feat(python): route YouTube nsig through JavaScriptCore, skip pure-Python"
```

---

## Task 6: Pin yt-dlp + Phase B integration verification

**Files:**
- Create/Modify: `app/Keraunos/python-dev/requirements.txt`

> The nsig monkeypatch reaches into yt-dlp internals; pinning prevents a silent break on upgrade. The drift-guard test (Task 5) flags breakage on the next bump.

- [ ] **Step 1: Pin the version** — ensure `requirements.txt` contains exactly:

```
yt-dlp==2025.10.14
```
(If the file lists other dev deps, keep them; just pin yt-dlp.)

- [ ] **Step 2: Record the bundled-package version** — confirm the version vendored into the app matches:

```bash
.venv/bin/python -c "import yt_dlp; print(yt_dlp.version.__version__)" 2>/dev/null || \
  app/Keraunos/python-dev/.venv/bin/python -c "import yt_dlp; print(yt_dlp.version.__version__)"
ls app/Keraunos/PythonResources/app_packages/yt_dlp/version.py
```
Expected: `2025.10.14`. If the app's vendored `app_packages/yt_dlp` differs, note the mismatch in the commit (the device runs the vendored copy; tests run the venv copy — they must match for the drift guard to be meaningful).

- [ ] **Step 3: Build + full app test suite, expect success**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests 2>&1 | grep -iE "error:|\*\* TEST"
swift test --package-path app/KeraunosCore 2>&1 | grep -E "Test run with"
```
Expected: `TEST SUCCEEDED`; Core all pass.

- [ ] **Step 4: Commit**

```bash
git add app/Keraunos/python-dev/requirements.txt
git commit -m "chore(python): pin yt-dlp==2025.10.14 for the nsig monkeypatch"
```

> **Phase B is shippable here.** Manual check during Task 11: a signed-in YouTube video that needs only nsig (no PO token) now resolves instead of hanging. Videos that additionally require a PO token still fail — cleanly, bounded by Phase A — until Phase C.

---

# PHASE C — PO tokens via BotGuard (research spike)

> **Spike framing.** Phase C is uncertain: BotGuard is heavily obfuscated and its
> endpoints change. Each task has an explicit observe/decision step. **Decision gate
> at the end of Task 9:** if a PO token cannot be minted on-device after the spike,
> STOP, keep the graceful-degradation wiring (Task 10), and ship A+B. Do not sink
> unbounded effort here.

## Task 7: Vendor `bgutils-js` + JSC environment shims

**Files:**
- Create: `app/Keraunos/PythonResources/app/bgutils/` (vendored JS bundle)
- Modify: `app/Keraunos/Keraunos/PythonRuntime/JSEvaluator.swift` (environment shims)

- [ ] **Step 1: Vendor the BotGuard runner JS** — build a browser-free bundle of `bgutils-js` (the library the reference `bgutil-ytdlp-pot-provider` uses) and place the single bundled file at `app/Keraunos/PythonResources/app/bgutils/bgutils.bundle.js`. From a scratch dir with Node available:

```bash
mkdir -p /tmp/bgutils && cd /tmp/bgutils
npm init -y >/dev/null 2>&1
npm install bgutils-js esbuild >/dev/null 2>&1
echo "import * as bg from 'bgutils-js'; globalThis.BG = bg;" > entry.js
npx esbuild entry.js --bundle --format=iife --global-name=BGBundle \
  --outfile=bgutils.bundle.js
cp bgutils.bundle.js /Users/leo/Developer/Keraunos/app/Keraunos/PythonResources/app/bgutils/bgutils.bundle.js
cd /Users/leo/Developer/Keraunos
```
> Record the resolved `bgutils-js` version (`/tmp/bgutils/package-lock.json`) in the commit message.

- [ ] **Step 2: Add environment shims to the shared JSContext** — `bgutils-js` needs a few browser globals. In `JSEvaluator.swift`, extend `installConsole()` into an `installEnvironment()` called from `init`, adding `atob`/`btoa`, a minimal `navigator`, a `window`/`self`/`globalThis` alias, and a synchronous `setTimeout` (BotGuard schedules microtasks):

```swift
    private func installEnvironment() {
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
```
Replace the `installConsole()` call in `init` with `installEnvironment()`.

- [ ] **Step 3: Add a JSEvaluator test for the shims** — append to `JSEvaluatorTests.swift`:

```swift
    @Test func environmentShimsAreAvailable() {
        let out = JSEvaluator.shared.evaluate("console.log(typeof atob, typeof navigator.userAgent, typeof setTimeout);", timeoutMs: 1000)
        #expect(out == "function string function")
    }
```

- [ ] **Step 4: Build + run the JSEvaluator tests, expect pass**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/JSEvaluatorTests 2>&1 | grep -iE "error:|\*\* TEST"
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/PythonResources/app/bgutils/ \
        app/Keraunos/Keraunos/PythonRuntime/JSEvaluator.swift \
        app/Keraunos/KeraunosTests/JSEvaluatorTests.swift
git commit -m "feat(app): vendor bgutils-js and add JSContext browser shims"
```

---

## Task 8: `KeraunosPoTokenProvider` skeleton + registration

**Files:**
- Create: `app/Keraunos/PythonResources/app/keraunos_youtube_pot.py`
- Modify: `app/Keraunos/PythonResources/app/keraunos_extract.py` (import to register)
- Create: `app/Keraunos/python-dev/test_pot_provider.py`

> This task wires the provider into yt-dlp's pot framework and proves registration. The actual token-minting JS flow is the Task 9 spike; here `_real_request_pot` raises `PoTokenProviderRejectedRequest` so behavior degrades cleanly until Task 9 fills it in.

- [ ] **Step 1: Write the failing test** — create `test_pot_provider.py`:

```python
import sys
from pathlib import Path

APP = Path(__file__).resolve().parents[1] / "PythonResources" / "app"
sys.path.insert(0, str(APP))


def test_provider_class_is_well_formed():
    import keraunos_youtube_pot as m
    from yt_dlp.extractor.youtube.pot.provider import PoTokenProvider
    assert issubclass(m.KeraunosPoTokenProviderPTP, PoTokenProvider)
    assert m.KeraunosPoTokenProviderPTP.__name__.endswith("PTP")


def test_provider_registers_with_pot_framework():
    import keraunos_youtube_pot as m
    from yt_dlp.extractor.youtube.pot._registry import _pot_providers
    assert any(cls is m.KeraunosPoTokenProviderPTP for cls in _pot_providers.value.values())
```

- [ ] **Step 2: Run it, expect failure**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q test_pot_provider.py ; cd /Users/leo/Developer/Keraunos
```
Expected: FAIL — `No module named 'keraunos_youtube_pot'`.

- [ ] **Step 3: Implement `keraunos_youtube_pot.py`**

```python
"""On-device PO token provider for yt-dlp, backed by BotGuard run in JavaScriptCore.

Registered with yt-dlp's youtube.pot framework. The token-minting flow (BotGuard VM
-> integrity token -> mint) is implemented in _real_request_pot; on any failure it
raises PoTokenProviderRejectedRequest so extraction degrades to "no PO token" rather
than erroring hard.
"""
from yt_dlp.extractor.youtube.pot.provider import (
    PoTokenProvider,
    PoTokenProviderRejectedRequest,
    PoTokenResponse,
    register_provider,
)


@register_provider
class KeraunosPoTokenProviderPTP(PoTokenProvider):
    PROVIDER_NAME = "keraunos-jsc"
    PROVIDER_VERSION = "0.1.0"
    BUG_REPORT_LOCATION = "https://github.com/lilikazine/Keraunos/issues"
    _SUPPORTED_CLIENTS = ("web", "web_safari", "mweb", "tv", "web_embedded")

    def is_available(self) -> bool:
        return True

    def _real_request_pot(self, request) -> PoTokenResponse:
        # Filled in by Task 9. Until then, reject so yt-dlp proceeds without a PO token.
        raise PoTokenProviderRejectedRequest("Keraunos PO token minting not yet implemented")
```

- [ ] **Step 4: Register it at extraction time** — in `keraunos_extract.py`, add near the bottom (next to the `install_youtube_js_runtime()` call):

```python
try:
    import keraunos_youtube_pot  # noqa: F401  (registers the PO token provider on import)
except Exception:
    pass   # fail open: extraction proceeds without an on-device PO token provider
```

- [ ] **Step 5: Run it, expect pass**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: all tests pass.

> If `_pot_providers.value` is not the right registry accessor in this yt-dlp build, inspect `yt_dlp/extractor/youtube/pot/_registry.py` and adjust the assertion in Step 1 to match the actual registry container, then re-run.

- [ ] **Step 6: Commit**

```bash
git add app/Keraunos/PythonResources/app/keraunos_youtube_pot.py \
        app/Keraunos/PythonResources/app/keraunos_extract.py \
        app/Keraunos/python-dev/test_pot_provider.py
git commit -m "feat(python): register a (stub) on-device PO token provider"
```

---

## Task 9: SPIKE — mint a PO token via the full BotGuard flow (approach A)

> **On-device outcome (2026-06-18): the PO token was NOT the blocker.** Device debugging
> showed YouTube downloads fail because the **web** client is SABR-only (yt-dlp #12482) and
> its leftover progressive `itag 18` URL is HTTP 403 — the PO provider was never even
> invoked. **Fix:** restrict YouTube to non-web, no-PO clients
> (`player_client=['tv','tv_embedded','android_vr']`) + point yt-dlp `cachedir` at `tmp`;
> signed-in YouTube now downloads on a real device. The approach-A BotGuard flow below is
> implemented + unit-tested and kept as graceful scaffolding (full → cold-start → reject),
> but is off-path for the `tv`-family clients. See the spec's "On-device outcome" section.
> The steps below remain the record of the BotGuard spike.

**Files:**
- Modify: `app/Keraunos/PythonResources/app/keraunos_youtube_pot.py`
- Modify (only if a probe demands a shim): `app/Keraunos/Keraunos/PythonRuntime/JSEvaluator.swift`
- Modify: `app/Keraunos/python-dev/test_pot_provider.py`
- Reference: `app/Keraunos/PythonResources/app/bgutils/bgutils.bundle.js` (bgutils-js **3.2.0**)

> **Approach decided in the 2026-06-18 spec addendum: A (decompose + Python HTTP +
> `snapshotSynchronous`), as a de-risking spike; reassess C afterward.** Python does the
> two HTTP calls (urllib) *between* two short JS evals; `webPoSignalOutput` is stashed in
> a global across them. Because `snapshotSynchronous` is a direct call (no `setTimeout`,
> no `Promise.race`), each eval is microtask-only and JSC drains it before
> `evaluateScript` returns — **no event-loop pump, and likely zero native changes**.
>
> The `BG.*` names below are confirmed against the vendored bundle (not guesses): the
> real API is `BG.Challenge.parseChallengeData`, `BG.BotGuardClient.create` +
> `snapshotSynchronous`, `BG.WebPoMinter.create` + `mintAsWebsafeString`. There is **no**
> `BotGuardClient.run` and **no** two-arg `PoToken.generate(token, binding)` — the prior
> sketch was wrong. Mirror the bundle's own `generate()` (lines 331–354), split across
> the Python/JS boundary.

### Step 1: Write the failing test — extend `test_pot_provider.py`

Inject a fake `_eval_js` (returns a canned `botguardResponse` then a canned token) and a
fake HTTP poster, then assert the flow builds the right payloads and walks the
degradation ladder. Add to `test_pot_provider.py`:

```python
def test_full_flow_builds_payloads_and_returns_token(monkeypatch):
    import keraunos_youtube_pot as m
    import keraunos_extract

    posts = []
    monkeypatch.setattr(m, "_waa_post", lambda endpoint, payload: posts.append((endpoint, payload)) or (
        ["RAW_CHALLENGE"] if endpoint.endswith("Create") else ["INTEGRITY_TOKEN", 3600, 0, "fallback"]))
    evals = []
    keraunos_extract.set_js_evaluator(
        lambda script, t: evals.append(script) or ("BOTGUARD_RESPONSE" if "snapshotSynchronous" in script else "PO_TOKEN_123"))

    provider = m.KeraunosPoTokenProviderPTP(...)   # construct per the framework's signature
    resp = provider._real_request_pot(_FakeRequest(visitor_data="VISITOR"))

    assert resp.po_token == "PO_TOKEN_123"
    assert posts[0][0].endswith("Create")     and posts[0][1] == ["O43z0dpjhgX20SCx4KAo"]
    assert posts[1][0].endswith("GenerateIT") and posts[1][1] == ["O43z0dpjhgX20SCx4KAo", "BOTGUARD_RESPONSE"]
    assert "snapshotSynchronous" in evals[0] and "mintAsWebsafeString" in evals[1]
```

(Keep the existing registration + well-formedness tests. `_FakeRequest` is a tiny stub
exposing `visitor_data`/`data_sync_id`. Adjust the provider construction to the
framework's required ctor args — inspect `PoTokenProvider.__init__` in the pinned
yt-dlp.) Run, expect failure (`_waa_post` / new flow missing):

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q test_pot_provider.py ; cd /Users/leo/Developer/Keraunos
```

### Step 2: Implement the A flow in `keraunos_youtube_pot.py`

Replace `_real_request_pot` and add the module-scope helpers. Keep the existing
`_cold_start_snippet`/cold-start logic as the fallback rung.

```python
import json
import urllib.request

_REQUESTKEY = "O43z0dpjhgX20SCx4KAo"
_GOOG = "https://jnn-pa.googleapis.com/$rpc/google.internal.waa.v1.Waa"
_GOOG_API_KEY = "AIzaSyDyT5W0Jh49F30Pqqtyfdf7pDLFKLJoAnw"
_USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36(KHTML, like Gecko)"


def _waa_post(endpoint, payload):
    """POST a protobuf-JSON array to a WAA endpoint; return the parsed JSON array.
    These endpoints authenticate via x-goog-api-key only (no YouTube cookies)."""
    data = json.dumps(payload).encode()
    req = urllib.request.Request(f"{_GOOG}/{endpoint}", data=data, headers={
        "content-type": "application/json+protobuf",
        "x-goog-api-key": _GOOG_API_KEY,
        "x-user-agent": "grpc-web-javascript/0.1",
        "user-agent": _USER_AGENT,
    })
    with urllib.request.urlopen(req, timeout=10) as resp:   # tight, stays under the 30s watchdog
        return json.loads(resp.read().decode())


def _snapshot_snippet(raw_challenge):
    # J1: parse challenge -> install VM -> create client -> SYNCHRONOUS snapshot.
    # Stash webPoSignalOutput (holds the VM minter-factory closure) in a global for J2;
    # the shared JSContext is long-lived so it survives to the next eval. Errors are
    # caught and printed as the sentinel (async-IIFE rejections don't set context.exception).
    return _bundle_js() + ("""
(async () => {
  const ch = globalThis.BG.Challenge.parseChallengeData(%s);
  (0, eval)(ch.interpreterJavascript.privateDoNotAccessOrElseSafeScriptWrappedValue);
  const bg = await globalThis.BG.BotGuardClient.create(
      { program: ch.program, globalName: ch.globalName, globalObj: globalThis });
  const sig = [];
  const botguardResponse = await bg.snapshotSynchronous({ webPoSignalOutput: sig });
  globalThis.__keraunos_sig = sig;
  console.log(botguardResponse);
})().catch(e => console.log("__KERAUNOS_JS_ERROR__" + (e && e.stack || e)));
""" % json.dumps(raw_challenge))


def _mint_snippet(integrity_response, identifier):
    # J2: rebuild integrityTokenData from the GenerateIT array, mint against the stashed
    # webPoSignalOutput. Positional order per bundle line 344.
    integrity_data = {
        "integrityToken": integrity_response[0],
        "estimatedTtlSecs": integrity_response[1] if len(integrity_response) > 1 else None,
        "mintRefreshThreshold": integrity_response[2] if len(integrity_response) > 2 else None,
        "websafeFallbackToken": integrity_response[3] if len(integrity_response) > 3 else None,
    }
    return _bundle_js() + ("""
(async () => {
  const minter = await globalThis.BG.WebPoMinter.create(%s, globalThis.__keraunos_sig);
  console.log(await minter.mintAsWebsafeString(%s));
})().catch(e => console.log("__KERAUNOS_JS_ERROR__" + (e && e.stack || e)));
""" % (json.dumps(integrity_data), json.dumps(identifier)))


def _full_botguard_token(self, identifier):
    import keraunos_extract  # lazy: reuse the JS eval seam
    raw = _waa_post("Create", [_REQUESTKEY])                                  # P1
    botguard_response = keraunos_extract._eval_js(_snapshot_snippet(raw), 10000)  # J1
    if not botguard_response or botguard_response.startswith("__KERAUNOS_JS_ERROR__"):
        raise RuntimeError(f"snapshot failed: {botguard_response!r}")
    integrity = _waa_post("GenerateIT", [_REQUESTKEY, botguard_response])     # P2
    token = keraunos_extract._eval_js(_mint_snippet(integrity, identifier), 10000)  # J2
    if not token or token.startswith("__KERAUNOS_JS_ERROR__"):
        raise RuntimeError(f"mint failed: {token!r}")
    return token
```

Rewrite `_real_request_pot` to walk the ladder (full → cold-start → reject):

```python
    def _real_request_pot(self, request) -> PoTokenResponse:
        identifier = request.visitor_data or request.data_sync_id
        if not identifier:
            _spike_log("rejected: no visitor_data/data_sync_id")
            raise PoTokenProviderRejectedRequest("no visitor_data/data_sync_id to bind a PO token")
        # Tier 2: full BotGuard flow.
        try:
            token = _full_botguard_token(self, identifier)
            _spike_log(f"minted full BotGuard PO token (len={len(token)})")
            return PoTokenResponse(po_token=token)
        except Exception as e:
            _spike_log(f"full BotGuard flow failed, falling back to cold-start: {e}")
        # Tier 1: cold-start fallback (preserves prior behavior).
        import keraunos_extract
        token = keraunos_extract._eval_js(_cold_start_snippet(identifier), 5000)
        if token and not token.startswith("__KERAUNOS_JS_ERROR__"):
            _spike_log(f"minted cold-start PO token (len={len(token)})")
            return PoTokenResponse(po_token=token)
        _spike_log(f"rejected: cold-start also failed: {token!r}")
        raise PoTokenProviderRejectedRequest(f"PO token minting failed: {token!r}")
```

Run the test, expect pass:

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```

### Step 3: Build + run on a physical device

The simulator shares the Mac's bot-flagged IP; the spike's probes are only meaningful on
a real device signed into YouTube. **Clean-build (⇧⌘K)** first — PythonResources changes
re-sync, but suspect a stale binary if device behavior contradicts source.

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'   # build check only
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"
```

Then ▶ on a connected device from Xcode.

### Step 4: OBSERVE — answer the spike's probes

Sign into YouTube in-app, download a video that previously failed PO-token-required, and
read the `[keraunos-pot]` stderr lines in the Xcode console. Record, in order:

1. **Does `Create` return** (P1)? If not → endpoint/headers/device-IP issue.
2. **Does J1 print a `botguardResponse`**, or a `__KERAUNOS_JS_ERROR__`? Key probes:
   - `"Synchronous snapshot function not found"` → `syncSnapshotFunction` absent → A must
     fall back to async `snapshot()` (see Step 5b).
   - `ReferenceError: <X> is not defined` → the VM needs a browser-global shim.
   - empty output → JSC did not drain the await chain (pump needed).
3. **Does `GenerateIT` return** (P2)?
4. **Does J2 print a token**, or a `BGError` (`PMD:Undefined` = `webPoSignalOutput[0]`
   missing; `INTEGRITY_ERROR`; `APF:/YNJ:/ODM:` = mint internals)?

### Step 5: ADAPT — at most 3 rounds

- **5a (shim):** add any missing global to `JSEvaluator.installEnvironment()` (and a
  `JSEvaluatorTests` assertion), rebuild, re-observe.
- **5b (sync→async fallback):** if `syncSnapshotFunction` is absent, switch J1 to async
  `snapshot()` **and** change the `setTimeout` shim to *defer* (e.g. `queueMicrotask`)
  instead of firing immediately — otherwise `snapshot()`'s `Promise.race(real,
  setTimeout(reject))` self-rejects. If the chain still won't settle in one
  `evaluateScript`, the pump is unavoidable → this is the signal to escalate to the C
  design rather than spend more rounds here.

### Step 6: DECISION GATE

- **Token mints + video downloads:** commit. Then revisit C (port the now-understood,
  working flow onto `BG.PoToken.generate()` + a real event-loop pump for the long-term,
  reusable shape) as a separate, optional follow-up.
  ```bash
  git add app/Keraunos/PythonResources/app/keraunos_youtube_pot.py \
          app/Keraunos/python-dev/test_pot_provider.py \
          app/Keraunos/Keraunos/PythonRuntime/JSEvaluator.swift   # only if a shim was added
  git commit -m "feat(python): mint YouTube PO tokens via the full BotGuard flow in JavaScriptCore"
  ```
- **No token after 3 rounds:** STOP. The ladder already degrades cleanly (full →
  cold-start → reject → `requires_auth`, never a hang). Record the blocker in the Task 11
  acceptance log; Phase C Tier 2 is deferred.
  ```bash
  git add app/Keraunos/PythonResources/app/keraunos_youtube_pot.py app/Keraunos/python-dev/test_pot_provider.py
  git commit -m "wip(python): full BotGuard PO token spike — blocked, degrades to cold-start/no-PO-token"
  ```

---

## Task 10: Graceful-degradation safety net

**Files:**
- Modify: `app/Keraunos/PythonResources/app/keraunos_extract.py`

> Ensures a PO-token-required video that the provider can't satisfy surfaces a clear
> message (never a hang, never a raw stack trace), whether or not Task 9 succeeded.

- [ ] **Step 1: Map the "PO token required" failure** — in `keraunos_extract.py`'s `extract()` exception handling, the `_AUTH_HINTS` tuple already catches "sign in". Add PO-token phrasing so it maps to a clear error. Change:

```python
_AUTH_HINTS = ("log in", "sign in", "logged in", "cookies", "nsfw",
               "age-restricted", "age restricted", "confirm your age", "sensitive")
```
to:
```python
_AUTH_HINTS = ("log in", "sign in", "logged in", "cookies", "nsfw",
               "age-restricted", "age restricted", "confirm your age", "sensitive",
               "po token", "po_token", "missing a gvs po token")
```

- [ ] **Step 2: Run the Python suite, expect pass**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: all tests pass.

- [ ] **Step 3: Commit**

```bash
git add app/Keraunos/PythonResources/app/keraunos_extract.py
git commit -m "feat(python): map PO-token-required failures to a clear auth error"
```

---

## Task 11: Manual acceptance

**Files:** none (manual; capture results in a log)

- [ ] **Step 1: No-hang regression (Phase A)** — paste a known-pathological URL (the YouTube Shorts URL `https://www.youtube.com/shorts/nDHj2xYVCAs` if still hanging pre-fix, or any slow source). Expected: it either resolves or fails with "Extraction took too long and was stopped." within ~45s — **never an infinite spinner**.

- [ ] **Step 2: nsig path (Phase B)** — sign into YouTube in-app, then download a video/Short that needs only nsig. Expected: resolves and the `.mp4` appears (no hang). Note resolve time.

- [ ] **Step 3: PO-token path (Phase C)** — download a YouTube video that requires a GVS PO token. Expected (if Task 9 succeeded): downloads. Expected (if deferred): fails with the clear auth/PO-token message, no hang.

- [ ] **Step 4: Fail-open regressions** — confirm a public progressive X video and a DASH-merge case still work exactly as before (cookie layer + new timeout unaffected).

- [ ] **Step 5: Record results** — create `docs/logs/<today>-NN-ondevice-youtube-acceptance.md` (next free `NN`): device/iOS, URLs tried, per-phase outcomes, nsig resolve times, whether PO-token minting worked or was deferred (with the blocker), and built `.app` size (`du -sh`). Commit:

```bash
git add docs/logs/
git commit -m "docs(log): record on-device YouTube acceptance results"
```

- [ ] **Step 6: Done-check** — confirm the spec's goals:
  1. No extraction hangs — every path resolves or fails within the bound (Phase A).
  2. Signed-in nsig-only YouTube videos download (Phase B).
  3. PO-token videos download (Phase C) **or** degrade cleanly with a clear message and the blocker is logged.
  4. All tiers green: Core `swift test`, Python `pytest`, app `xcodebuild test`.
  5. Fail-open unchanged: X progressive + DASH merge + error mapping work with no/failed cookies and no JS runtime needed.

---

## Self-Review notes (for the executor)

- **Spec coverage:** Phase A `withTimeout`+`timedOut` (Tasks 1–2) · JSC eval bridge native+exposure (Tasks 3–4) · nsig routing + pin (Tasks 5–6) · BotGuard shims/vendoring (Task 7) · PO token provider registration (Task 8) · mint spike (Task 9) · graceful degradation (Task 10) · acceptance + done-check (Task 11). Fail-open is enforced by the import-time `try/except` around `install_youtube_js_runtime()` and the PO-token provider, the `PoTokenProviderRejectedRequest` fallback, and Phase A's bound.
- **Type consistency:** `withTimeout(_:_:)` throws `.timedOut`; `PythonExtractor(cookieProvider:timeout:)` with `blockingExtract`; `JSEvaluator.shared.evaluate(_:timeoutMs:)` + `@_cdecl keraunos_js_eval(script, timeoutMs)`; ObjC `keraunos_js_eval(const char*, double)` + `keraunos_native.eval_js(script, timeout_ms)`; Python `set_js_evaluator`, `_eval_js`, `JavaScriptCoreWrapper.execute(jscode, video_id=, note=)`, `install_youtube_js_runtime()`; `KeraunosPoTokenProviderPTP(PoTokenProvider)` with `is_available`/`_real_request_pot` — used identically across tasks.
- **Build sequencing:** every Swift addition is defaulted/new, so the app target compiles after every task — no intentional red window. Phases A and B are each independently shippable; Phase C degrades gracefully.
- **Spike honesty:** Task 9 is explicitly bounded (≤3 adapt rounds, decision gate). The genuinely-unknown parts (BotGuard `BG.*` symbol names, endpoint payload shapes, missing shims) are observe-and-adapt steps against the `bgutils-js` README, not guessed code presented as final.
- **Deferred (NOT this milestone):** non-YouTube JS-runtime sites, multiple YouTube accounts, per-download account selection, PO-token disk caching across sessions, HLS/ffmpeg merging.
```
