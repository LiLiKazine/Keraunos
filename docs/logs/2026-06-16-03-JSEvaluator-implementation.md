# 2026-06-16-03: JSEvaluator — JavaScriptCore in-process evaluator

**Status:** Implemented

## Context

Phase B (Task 3) requires an in-process JavaScript evaluator so yt-dlp can run
YouTube's nsig function without a subprocess. The embedded CPython runtime has no
`fork`/`subprocess` support, so any JS evaluation that shells out is a non-starter.
The evaluator must expose a C-callable entry point (`keraunos_js_eval`) for the Python
bridge added in Task 4.

## Options

| Approach | Pros | Cons |
|----------|------|------|
| JavaScriptCore (chosen) | System framework, zero extra size, well-tested, Obj-C API callable from Swift | `JSContext` carries `@MainActor` annotation in iOS 26 SDK; requires actor isolation workarounds |
| WKWebView / WKUserScript | Can run arbitrary JS, supports full DOM | Async-only (`evaluateJavaScript` completion handler), heavyweight, adds WebKit dependency |
| Embedded QuickJS | No SDK dependency, truly synchronous, no actor overhead | ~300 KB binary size, manual maintenance, cross-compile for arm64 simulator is non-trivial |

JavaScriptCore was chosen — it's the right size/complexity for nsig evaluation, and the
actor isolation issues are solvable.

## Decision

Use `JavaScriptCore` (`JSContext`) with a `console.log` shim to capture yt-dlp's output,
wrapped in a `final class` singleton serialised by `NSLock`.

## Rationale

- yt-dlp's nsig snippet ends with `console.log(result)` — intercepting that call is
  simpler than trying to extract a return value from JSCore's type system.
- A long-lived `JSContext` singleton lets Phase C install network/timer shims once.
- `NSLock` + `@unchecked Sendable` is the right trade-off over an actor here: the
  evaluator is called from the Python bridge (off-main thread), and making `evaluate`
  async would require the bridge to spin a Swift concurrency runtime.

## What Changed

- **Added** `app/Keraunos/Keraunos/PythonRuntime/JSEvaluator.swift`
  - `JSEvaluator` singleton: `JSContext`, `NSLock`, `console.log` shim, `evaluate(_:timeoutMs:) -> String`
  - `applyExecutionTimeLimit` no-op (see discoveries below)
  - `@_cdecl("keraunos_js_eval")` C entry point returning `strdup`'d UTF-8
- **Added** `app/Keraunos/KeraunosTests/JSEvaluatorTests.swift`
  - 3 Swift Testing `@Test` functions: console.log capture, function execution, syntax error sentinel
- **Modified** `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h`
  - Added `keraunos_js_eval(const char *script, double timeoutMs)` declaration so ObjC `.m` can call the Swift `@_cdecl` symbol
- **Modified** `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m`
  - Added `keraunos_native` Python C extension module with `eval_js` method that calls `keraunos_js_eval`
  - Registered it via `PyImport_AppendInittab("keraunos_native", PyInit_keraunos_native)` immediately before `Py_PreInitialize`

## What Was Discovered

### `JSContextGroupSetExecutionTimeLimit` absent from iOS SDK

The C function `JSContextGroupSetExecutionTimeLimit` — which the original design
referenced — is not in any public iOS SDK header. It exists in WebKit's private
headers on macOS but is not exported for iOS. `applyExecutionTimeLimit` is therefore
a documented no-op; the outer Phase A `withTimeout` is the real execution bound.
Attempted: grepping `JSContextRef.h` in the SDK — confirmed only `JSContextGetGroup`
is present.

### `-default-isolation=MainActor` project flag propagates `@MainActor` everywhere

The Keraunos app target sets `-default-isolation=MainActor` (a Swift 6 flag that makes
all declarations `@MainActor` unless explicitly opted out). This caused multiple cascade
errors:

1. **`JSContext` stored property** → inferred `@MainActor` on `init` and all methods.
   Fix: `nonisolated(unsafe) private let context: JSContext`.

2. **Static stored properties (`_shared`, `sharedLock`)** → inferred `@MainActor` on
   the class-level storage, making them unreachable from `nonisolated shared`.
   Fix: `nonisolated(unsafe)` on both.

3. **`static let shared = JSEvaluator()`** (original design) → compiler rejected calling
   `@MainActor`-inferred `init` in a `nonisolated(unsafe)` context.
   Fix: replaced with a lazy `static var shared` computed property backed by `_shared`
   and a lock, with a `nonisolated private init()`.

4. **`nonisolated(unsafe)` on `sharedLock: NSLock`** generates a warning ("unnecessary
   for a constant with Sendable type") but **cannot be removed** — without it the
   `-default-isolation=MainActor` flag makes `sharedLock` `@MainActor`, causing a
   compile error when accessed from the `nonisolated shared` computed property.
   The warning is a Swift compiler over-eagerness; the annotation is load-bearing here.

### Tests compile under Swift 6 without `@MainActor`

`JSEvaluatorTests.swift` accesses `JSEvaluator.shared` from `nonisolated` `@Test`
functions. This works because `shared` is declared `nonisolated` on the type. The
test target also sets `-default-isolation=MainActor`, but since `shared` is explicitly
`nonisolated`, no cross-actor call is generated.

### `PyImport_AppendInittab` placement is stricter than the docs imply

The CPython docs say AppendInittab must be called "before `Py_Initialize`", but the
stricter requirement is **before `Py_PreInitialize`**. The pre-init phase configures
memory allocators that affect how the interpreter loads built-in modules; registering
after pre-init is silently ignored. The correct placement in `keraunos_python_init`
is between `setenv("SSL_CERT_FILE", …)` and `PyPreConfig_InitIsolatedConfig(…)`.

### `keraunos_js_eval` is a bare C symbol — no import needed in ObjC

Because `keraunos_js_eval` is declared `@_cdecl` in Swift, it emits a C-linkage
symbol directly into the app binary. The ObjC `.m` file only needs a forward
declaration in the shared header — no `@import`, no bridging header, no extra linker
flags. The declaration in `PythonBridge.h` is sufficient.

## Commits

| SHA | Description |
|-----|-------------|
| (see HEAD~1) | feat(app): add JavaScriptCore-backed JSEvaluator with console.log capture |
| (see HEAD) | feat(app): expose keraunos_native.eval_js to the embedded interpreter |
