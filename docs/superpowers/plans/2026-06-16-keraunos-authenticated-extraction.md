# Keraunos Authenticated Extraction — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user sign into a site inside the app (a `WKWebView`) and replay the captured session cookies to yt-dlp on every extraction, so account-gated / rate-limited content downloads — and a once-signed-in site downloads directly afterward.

**Architecture:** A pure `NetscapeCookieWriter` (+ `Cookie` value type) in `KeraunosCore` serializes cookies to the `cookies.txt` yt-dlp wants. In the app, a `@MainActor CookieStore` wraps a persistent `WKWebsiteDataStore` (the login web view writes to the same store); before every extraction it exports the current cookies to a short-lived, file-protected temp file. `PythonExtractor` (depending on a `CookieProviding` abstraction) passes that path through the C bridge to Python's `extract(…, cookiefile=…)`. The login sheet is triggered on-demand when extraction returns `.requiresAuth`; an `AccountsView` manages sign-out. The cookie layer fails open — any failure degrades to the no-cookies app.

**Tech Stack:** Swift 6 language mode, SwiftUI, WebKit (`WKWebView`/`WKWebsiteDataStore`), Swift Testing, the `KeraunosCore` SwiftPM package, embedded CPython 3.13 + yt-dlp (`cookiefile` option).

**Design source of truth:** `docs/superpowers/specs/2026-06-16-keraunos-authenticated-extraction-design.md`.

---

## Conventions (read once)

- **Repo root:** `/Users/leo/Developer/Keraunos`. Run all commands from there.
- **Branch:** `feat/authenticated-extraction` (already cut off `main`, which has Milestone 2).
- **App project / scheme:** `app/Keraunos/Keraunos.xcodeproj`, scheme `Keraunos`.
- **Core package:** `app/KeraunosCore`.
- **Core test command** (fast — macOS, no simulator):
  ```bash
  swift test --package-path app/KeraunosCore
  ```
  Single suite: `swift test --package-path app/KeraunosCore --filter NetscapeCookieWriterTests`.
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
- **App-target compiles throughout:** `PythonExtractor`'s new `cookieProvider` is a **defaulted optional** (`= nil`), so `ContentView`'s existing `PythonExtractor()` keeps compiling until Task 7 wires the real store. No intentional red period.
- **Isolation rule (unchanged):** `KeraunosCore` is `nonisolated`-default. `PythonExtractor` is an `actor` on its own serial queue; `CookieStore` is `@MainActor`. `PythonExtractor.resolve` does `await cookieProvider?.cookieFile()`, which suspends and hops to the main actor for WebKit, returning only a `Sendable` `URL`. No shared WebKit state crosses actors.
- **Commits:** use the `structured-commit` skill. The `git commit` lines below give the summary; let the skill expand the body. End messages with the `Co-Authored-By` trailer.
- **TDD:** pure/logic tasks are test-first. WebKit/UI/bridge tasks (Tasks 3, 6, 7) have no unit tests — they are interpreter/UI-bound and verified by build + the Task 8 manual acceptance, per the spec's testing section.

---

## File Structure

```
app/KeraunosCore/Sources/KeraunosCore/
  Cookie.swift                 # Task 1 (NEW — Cookie value type)
  NetscapeCookieWriter.swift   # Task 1 (NEW — pure serializer)

app/KeraunosCore/Tests/KeraunosCoreTests/
  NetscapeCookieWriterTests.swift  # Task 1 (NEW)

app/Keraunos/PythonResources/app/
  keraunos_extract.py          # Task 2 (add cookiefile param)
app/Keraunos/python-dev/
  test_extract.py              # Task 2 (extend)

app/Keraunos/Keraunos/PythonRuntime/
  PythonBridge.h               # Task 3 (signature += cookieFilePath)
  PythonBridge.m               # Task 3 (pass cookiefile kwarg)
  PythonExtractor.swift        # Task 3 (CookieProviding plumbing)
app/Keraunos/Keraunos/
  Keraunos-Bridging-Header.h   # Task 3 (no change if it includes PythonBridge.h — verify)
  Auth/CookieProviding.swift   # Task 3 (NEW — protocol)
  Auth/CookieStore.swift       # Task 4 (NEW — @MainActor WKWebsiteDataStore wrapper)
  Auth/LoginWebView.swift      # Task 6 (NEW — WKWebView wrapper)
  Auth/AccountsView.swift      # Task 7 (NEW — manage view)
  UI/DownloadViewModel.swift   # Task 5 (auth-retry state)
  UI/DownloadScreen.swift      # Task 6 (sign-in button + login sheet) + Task 7 (Accounts entry)
  ContentView.swift            # Task 7 (construct + inject CookieStore)

app/Keraunos/KeraunosTests/
  CookieStoreTests.swift       # Task 4 (NEW)
  DownloadViewModelTests.swift # Task 5 (extend: auth-retry)
```

---

## Task 1: `Cookie` value type + `NetscapeCookieWriter` (Core, pure)

**Files:**
- Create: `app/KeraunosCore/Sources/KeraunosCore/Cookie.swift`
- Create: `app/KeraunosCore/Sources/KeraunosCore/NetscapeCookieWriter.swift`
- Test: `app/KeraunosCore/Tests/KeraunosCoreTests/NetscapeCookieWriterTests.swift`

- [ ] **Step 1: Write the failing tests** — create `NetscapeCookieWriterTests.swift`:

```swift
import Testing
import Foundation
import KeraunosCore

struct NetscapeCookieWriterTests {
    private func cookie(_ name: String, _ value: String, domain: String,
                        path: String = "/", secure: Bool = false,
                        expires: Date? = nil, includeSubdomains: Bool = false) -> Cookie {
        Cookie(name: name, value: value, domain: domain, path: path,
               isSecure: secure, expires: expires, includeSubdomains: includeSubdomains)
    }

    @Test func startsWithNetscapeHeader() {
        let out = NetscapeCookieWriter.write([cookie("a", "b", domain: "x.test")])
        #expect(out.hasPrefix("# Netscape HTTP Cookie File\n"))
    }

    @Test func writesSevenTabSeparatedFields() {
        let out = NetscapeCookieWriter.write([
            cookie("sessionid", "abc", domain: "x.test", path: "/", secure: true,
                   expires: Date(timeIntervalSince1970: 1_900_000_000), includeSubdomains: false)
        ])
        let line = out.split(separator: "\n").last.map(String.init) ?? ""
        let fields = line.components(separatedBy: "\t")
        #expect(fields.count == 7)
        #expect(fields == ["x.test", "FALSE", "/", "TRUE", "1900000000", "sessionid", "abc"])
    }

    @Test func includeSubdomainsFlagAndSecureFlag() {
        let out = NetscapeCookieWriter.write([
            cookie("k", "v", domain: ".x.test", secure: false, includeSubdomains: true)
        ])
        let fields = (out.split(separator: "\n").last.map(String.init) ?? "").components(separatedBy: "\t")
        #expect(fields[0] == ".x.test")
        #expect(fields[1] == "TRUE")    // includeSubdomains
        #expect(fields[3] == "FALSE")   // not secure
    }

    @Test func sessionCookieHasZeroExpiry() {
        let out = NetscapeCookieWriter.write([cookie("k", "v", domain: "x.test", expires: nil)])
        let fields = (out.split(separator: "\n").last.map(String.init) ?? "").components(separatedBy: "\t")
        #expect(fields[4] == "0")
    }

    @Test func preservesOrderOfMultipleCookies() {
        let out = NetscapeCookieWriter.write([
            cookie("first", "1", domain: "x.test"),
            cookie("second", "2", domain: "y.test"),
        ])
        let lines = out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("#") }
        #expect(lines.count == 2)
        #expect(lines[0].contains("first"))
        #expect(lines[1].contains("second"))
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
swift test --package-path app/KeraunosCore --filter NetscapeCookieWriterTests
```
Expected: FAIL — `cannot find 'Cookie'` / `cannot find 'NetscapeCookieWriter' in scope`.

- [ ] **Step 3: Create `Cookie.swift`**

```swift
import Foundation

/// One HTTP cookie, decoupled from WebKit so the serializer is testable in Core.
/// `expires == nil` means a session cookie. `includeSubdomains` is true when the
/// cookie applies to subdomains (its domain has a leading dot).
public struct Cookie: Equatable, Sendable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let isSecure: Bool
    public let expires: Date?
    public let includeSubdomains: Bool

    public init(name: String, value: String, domain: String, path: String,
                isSecure: Bool, expires: Date?, includeSubdomains: Bool) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.isSecure = isSecure
        self.expires = expires
        self.includeSubdomains = includeSubdomains
    }
}
```

- [ ] **Step 4: Create `NetscapeCookieWriter.swift`**

```swift
import Foundation

/// Serializes cookies to the Netscape `cookies.txt` format yt-dlp loads via its
/// `cookiefile` option (parsed by Python's `http.cookiejar.MozillaCookieJar`).
/// The header line is required or the parser rejects the file.
public enum NetscapeCookieWriter {
    public static func write(_ cookies: [Cookie]) -> String {
        var out = "# Netscape HTTP Cookie File\n"
        for c in cookies {
            let expiry = c.expires.map { String(Int($0.timeIntervalSince1970)) } ?? "0"
            let fields = [
                c.domain,
                c.includeSubdomains ? "TRUE" : "FALSE",
                c.path.isEmpty ? "/" : c.path,
                c.isSecure ? "TRUE" : "FALSE",
                expiry,
                c.name,
                c.value,
            ]
            out += fields.joined(separator: "\t") + "\n"
        }
        return out
    }
}
```

- [ ] **Step 5: Run it, expect pass** — same command as Step 2. Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/Sources/KeraunosCore/Cookie.swift \
        app/KeraunosCore/Sources/KeraunosCore/NetscapeCookieWriter.swift \
        app/KeraunosCore/Tests/KeraunosCoreTests/NetscapeCookieWriterTests.swift
git commit -m "feat(core): add Cookie value type and NetscapeCookieWriter"
```

---

## Task 2: Python `extract` accepts a `cookiefile`

**Files:**
- Modify: `app/Keraunos/PythonResources/app/keraunos_extract.py`
- Modify: `app/Keraunos/python-dev/test_extract.py`

- [ ] **Step 1: Write failing tests** — append to `test_extract.py`:

```python
def test_cookiefile_present_is_accepted(tmp_path):
    # A header-only cookies.txt is valid and must not break extraction.
    cookies = tmp_path / "cookies.txt"
    cookies.write_text("# Netscape HTTP Cookie File\n")
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True).start()
    while not ready:
        pass
    port = ready[0].server_address[1]
    out = json.loads(keraunos_extract.extract(
        f"http://127.0.0.1:{port}/sample.mp4", cookiefile=str(cookies)))
    ready[0].shutdown()
    assert out["ok"] is True
    assert out["kind"] == "progressive"


def test_missing_cookiefile_path_does_not_crash(tmp_path):
    (tmp_path / "sample.mp4").write_bytes(b"\x00\x00\x00\x18ftypmp42fakebytes")
    ready = []
    threading.Thread(target=_serve, args=(tmp_path, ready), daemon=True).start()
    while not ready:
        pass
    port = ready[0].server_address[1]
    out = json.loads(keraunos_extract.extract(
        f"http://127.0.0.1:{port}/sample.mp4", cookiefile="/no/such/cookies.txt"))
    ready[0].shutdown()
    assert out["ok"] is True   # extraction still works; bad path is ignored
```

- [ ] **Step 2: Run it, expect failure**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q -k cookiefile ; cd /Users/leo/Developer/Keraunos
```
Expected: FAIL — `extract() got an unexpected keyword argument 'cookiefile'`.

- [ ] **Step 3: Implement** — in `keraunos_extract.py`, add `import os` near the top imports (with `import json`), then change the `extract` signature and opts:

Change the signature line:
```python
def extract(url, socket_timeout=_SOCKET_TIMEOUT, cookiefile=None):
```
And, immediately after building `opts` (after the `}` that closes the opts dict), add:
```python
    if cookiefile and os.path.exists(cookiefile):
        opts["cookiefile"] = cookiefile
```

- [ ] **Step 4: Run it, expect pass**

```bash
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: all tests pass (the two new ones + the existing suite).

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/PythonResources/app/keraunos_extract.py app/Keraunos/python-dev/test_extract.py
git commit -m "feat(python): accept an optional cookiefile in extract()"
```

---

## Task 3: C bridge + `PythonExtractor` cookie plumbing + `CookieProviding`

**Files:**
- Create: `app/Keraunos/Keraunos/Auth/CookieProviding.swift`
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h`
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m`
- Modify: `app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift`

> Interpreter/bridge-bound — no unit test. Verified by app build now and by Task 8 manual acceptance. The `cookieProvider` is a **defaulted optional**, so `ContentView` keeps compiling.

- [ ] **Step 1: Create `Auth/CookieProviding.swift`**

```swift
import Foundation

/// Supplies a Netscape `cookies.txt` for the next extraction. The returned file
/// is a short-lived, caller-owned temp file (the caller deletes it). Returns nil
/// when there are no cookies. `Sendable` so the `PythonExtractor` actor can hold it.
public protocol CookieProviding: Sendable {
    func cookieFile() async -> URL?
}
```

- [ ] **Step 2: Update `PythonBridge.h`** — change the extract declaration to take a cookie-file path:

Replace:
```objc
char *keraunos_python_extract(const char *url);
```
with:
```objc
// cookieFilePath may be NULL or "" for "no cookies".
char *keraunos_python_extract(const char *url, const char *cookieFilePath);
```

- [ ] **Step 3: Update `PythonBridge.m`** — replace the body of `keraunos_python_extract` so it passes `cookiefile` as a keyword argument:

Replace the existing function definition:
```objc
char *keraunos_python_extract(const char *url) {
    PyGILState_STATE gil = PyGILState_Ensure();
    char *out = NULL;

    PyObject *module = PyImport_ImportModule("keraunos_extract");
    if (module) {
        PyObject *func = PyObject_GetAttrString(module, "extract");
        if (func && PyCallable_Check(func)) {
            PyObject *result = PyObject_CallFunction(func, "s", url);
            if (result) {
                const char *utf8 = PyUnicode_AsUTF8(result);
                if (utf8) out = strdup(utf8);
                Py_DECREF(result);
            }
        }
        Py_XDECREF(func);
        Py_DECREF(module);
    }
    if (!out && PyErr_Occurred()) PyErr_Clear();
    PyGILState_Release(gil);

    if (!out) out = strdup("{\"ok\":false,\"error_kind\":\"runtime\",\"detail\":\"python bridge failure\"}");
    return out;
}
```
with:
```objc
char *keraunos_python_extract(const char *url, const char *cookieFilePath) {
    PyGILState_STATE gil = PyGILState_Ensure();
    char *out = NULL;

    PyObject *module = PyImport_ImportModule("keraunos_extract");
    if (module) {
        PyObject *func = PyObject_GetAttrString(module, "extract");
        if (func && PyCallable_Check(func)) {
            PyObject *args = Py_BuildValue("(s)", url);                 // (url,)
            PyObject *kwargs = PyDict_New();
            if (cookieFilePath && cookieFilePath[0] != '\0') {
                PyObject *cf = PyUnicode_FromString(cookieFilePath);
                if (cf) { PyDict_SetItemString(kwargs, "cookiefile", cf); Py_DECREF(cf); }
            }
            if (args && kwargs) {
                PyObject *result = PyObject_Call(func, args, kwargs);   // extract(url, cookiefile=...)
                if (result) {
                    const char *utf8 = PyUnicode_AsUTF8(result);
                    if (utf8) out = strdup(utf8);
                    Py_DECREF(result);
                }
            }
            Py_XDECREF(args);
            Py_XDECREF(kwargs);
        }
        Py_XDECREF(func);
        Py_DECREF(module);
    }
    if (!out && PyErr_Occurred()) PyErr_Clear();
    PyGILState_Release(gil);

    if (!out) out = strdup("{\"ok\":false,\"error_kind\":\"runtime\",\"detail\":\"python bridge failure\"}");
    return out;
}
```

- [ ] **Step 4: Update `PythonExtractor.swift`** — inject an optional `CookieProviding`, export the cookie file before extraction, pass its path, and delete it after.

Replace the type's stored properties + `init` (add them; `PythonExtractor` currently has no explicit init) and the `resolve` method. Specifically, add a stored property and initializer at the top of the actor body (after `private var initialized = false`):
```swift
    private let cookieProvider: (any CookieProviding)?

    init(cookieProvider: (any CookieProviding)? = nil) {
        self.cookieProvider = cookieProvider
    }
```
and replace `resolve`:
```swift
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

- [ ] **Step 5: Build the app target, expect success**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD SUCCEEDED` (`CookieProviding.swift` and `Auth/` are picked up automatically by the folder-based target; `ContentView`'s `PythonExtractor()` still compiles via the defaulted `cookieProvider`).

> If the build fails because `Auth/CookieProviding.swift` is not in the target, the project uses a synchronized folder group (Xcode 16+) and new files under `Keraunos/` are included automatically — re-run; if it persists, add the file to the `Keraunos` target in Xcode.

- [ ] **Step 6: Commit**

```bash
git add app/Keraunos/Keraunos/Auth/CookieProviding.swift \
        app/Keraunos/Keraunos/PythonRuntime/PythonBridge.h \
        app/Keraunos/Keraunos/PythonRuntime/PythonBridge.m \
        app/Keraunos/Keraunos/PythonRuntime/PythonExtractor.swift
git commit -m "feat(app): thread an optional cookiefile through the bridge to yt-dlp"
```

---

## Task 4: `CookieStore` (WKWebsiteDataStore wrapper) + mapping

**Files:**
- Create: `app/Keraunos/Keraunos/Auth/CookieStore.swift`
- Test: `app/Keraunos/KeraunosTests/CookieStoreTests.swift`

- [ ] **Step 1: Write the failing tests** — create `CookieStoreTests.swift`:

```swift
import Testing
import Foundation
import WebKit
import KeraunosCore
@testable import Keraunos

@MainActor
struct CookieStoreTests {
    private func freshStore() -> (CookieStore, WKWebsiteDataStore) {
        let data = WKWebsiteDataStore.nonPersistent()   // no UI, deterministic
        return (CookieStore(dataStore: data), data)
    }
    private func setCookie(_ store: WKWebsiteDataStore, name: String, domain: String) async {
        let c = HTTPCookie(properties: [
            .name: name, .value: "v", .domain: domain, .path: "/",
            .expires: Date(timeIntervalSinceNow: 3600),
        ])!
        await store.httpCookieStore.setCookie(c)
    }

    @Test func emptyStoreReturnsNilCookieFile() async {
        let (store, _) = freshStore()
        #expect(await store.cookieFile() == nil)
    }

    @Test func exportsCookiesToNetscapeFile() async throws {
        let (store, data) = freshStore()
        await setCookie(data, name: "sessionid", domain: "x.test")
        await setCookie(data, name: "token", domain: "y.test")
        let url = try #require(await store.cookieFile())
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("# Netscape HTTP Cookie File"))
        #expect(text.contains("sessionid"))
        #expect(text.contains("token"))
        try? FileManager.default.removeItem(at: url)
    }

    @Test func signedInHostsAreDistinctAndDotStripped() async {
        let (store, data) = freshStore()
        await setCookie(data, name: "a", domain: "x.test")
        await setCookie(data, name: "b", domain: "x.test")
        let hosts = await store.signedInHosts()
        #expect(hosts == ["x.test"])
    }

    @Test func signOutRemovesOneHost() async {
        let (store, data) = freshStore()
        await setCookie(data, name: "a", domain: "x.test")
        await setCookie(data, name: "b", domain: "y.test")
        await store.signOut(host: "x.test")
        #expect(await store.signedInHosts() == ["y.test"])
    }

    @Test func signOutAllEmptiesTheStore() async {
        let (store, data) = freshStore()
        await setCookie(data, name: "a", domain: "x.test")
        await store.signOutAll()
        #expect(await store.signedInHosts().isEmpty)
        #expect(await store.cookieFile() == nil)
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/CookieStoreTests 2>&1 | grep -iE "cannot find|error:|\*\* TEST"
```
Expected: FAIL — `cannot find 'CookieStore' in scope`.

- [ ] **Step 3: Implement** — create `Auth/CookieStore.swift`:

```swift
import Foundation
import WebKit
import KeraunosCore

/// Owns the persistent cookie jar (a `WKWebsiteDataStore`, shared with the login
/// web view) and exports it to a short-lived, file-protected Netscape `cookies.txt`
/// for yt-dlp. `@MainActor` because WebKit's cookie store is main-actor-friendly.
@MainActor
final class CookieStore: CookieProviding {
    /// The store the login `WKWebView` must also use, so captured cookies are visible.
    let dataStore: WKWebsiteDataStore
    private let tempDir: URL

    init(dataStore: WKWebsiteDataStore = .default()) {
        self.dataStore = dataStore
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("keraunos-cookies", isDirectory: true)
        // Clear any cookie files orphaned by a prior crash.
        try? FileManager.default.removeItem(at: tempDir)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    func cookieFile() async -> URL? {
        let httpCookies = await allCookies()
        guard !httpCookies.isEmpty else { return nil }
        let cookies = httpCookies.map(Self.map)
        let text = NetscapeCookieWriter.write(cookies)
        let file = tempDir.appendingPathComponent("\(UUID().uuidString).txt")
        do {
            try text.data(using: .utf8)?.write(to: file, options: .completeFileProtection)
            return file
        } catch {
            return nil   // fail open: behave as no cookies
        }
    }

    func signedInHosts() async -> [String] {
        let domains = await allCookies().map { $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain }
        return Array(Set(domains)).sorted()
    }

    func signOut(host: String) async {
        let store = dataStore.httpCookieStore
        for cookie in await allCookies() where Self.matches(cookie, host: host) {
            await store.deleteCookie(cookie)
        }
    }

    func signOutAll() async {
        await dataStore.removeData(ofTypes: [WKWebsiteDataTypeCookies],
                                   modifiedSince: Date(timeIntervalSince1970: 0))
    }

    private func allCookies() async -> [HTTPCookie] {
        await dataStore.httpCookieStore.allCookies()
    }

    private static func matches(_ cookie: HTTPCookie, host: String) -> Bool {
        let d = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
        return d == host
    }

    private static func map(_ c: HTTPCookie) -> Cookie {
        Cookie(name: c.name, value: c.value, domain: c.domain,
               path: c.path.isEmpty ? "/" : c.path, isSecure: c.isSecure,
               expires: c.expiresDate, includeSubdomains: c.domain.hasPrefix("."))
    }
}
```

> `cookieFile()` stays `@MainActor` (the class default). An **async** protocol requirement can be witnessed by an actor-isolated async method, so the `CookieProviding` conformance holds and a caller on another actor (the `PythonExtractor`) just hops to the main actor when it `await`s. `WKHTTPCookieStore.allCookies()` / `deleteCookie(_:)` and `WKWebsiteDataStore.removeData(ofTypes:modifiedSince:)` are the async WebKit APIs (iOS 26 deployment target).

- [ ] **Step 4: Run it, expect pass** — same command as Step 2 (drop the `grep` to see results). Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/Auth/CookieStore.swift app/Keraunos/KeraunosTests/CookieStoreTests.swift
git commit -m "feat(app): add CookieStore exporting WKWebsiteDataStore cookies to cookies.txt"
```

---

## Task 5: `DownloadViewModel` auth-retry state

**Files:**
- Modify: `app/Keraunos/Keraunos/UI/DownloadViewModel.swift`
- Modify: `app/Keraunos/KeraunosTests/DownloadViewModelTests.swift`

- [ ] **Step 1: Write the failing tests** — append to `DownloadViewModelTests.swift` (inside the `DownloadViewModelTests` struct, after the existing tests), then add the stub class at file scope:

```swift
    @Test func requiresAuthShowsSignInForHost() async {
        let model = vm(extractor: MockExtractor(result: .failure(.requiresAuth)),
                       merger: MockMerger(), dir: tempDir())
        model.urlText = "https://www.instagram.com/reel/ABC/"
        await model.startDownload()
        #expect(model.requiresSignIn == true)
        #expect(model.signInURL?.host == "www.instagram.com")
        #expect(model.errorMessage == KeraunosError.requiresAuth.errorDescription)
    }

    @Test func retryAfterLoginSucceedsAndClearsSignIn() async {
        let dir = tempDir()
        let extractor = SequenceExtractor(results: [
            .failure(.requiresAuth),
            .success(progressive("clip.mp4")),
        ])
        let model = DownloadViewModel(
            extractor: extractor,
            assembler: MediaAssembler(downloader: SpyDownloader(), merger: MockMerger()),
            store: DownloadStore(directory: dir))
        model.urlText = "https://www.instagram.com/reel/ABC/"
        await model.startDownload()
        #expect(model.requiresSignIn == true)
        await model.retry()
        #expect(model.requiresSignIn == false)
        #expect(model.lastSavedName == "clip.mp4")
        #expect(model.errorMessage == nil)
    }
```

and at the bottom of the file (file scope, alongside `SpyDownloader`):

```swift
/// Returns a queued sequence of results across successive resolve() calls.
final class SequenceExtractor: MediaExtracting, @unchecked Sendable {
    private var results: [Result<ResolvedMedia, KeraunosError>]
    init(results: [Result<ResolvedMedia, KeraunosError>]) { self.results = results }
    func resolve(_ url: URL) async throws -> ResolvedMedia {
        try (results.isEmpty ? .failure(.runtime(detail: "no more results")) : results.removeFirst()).get()
    }
}
```

- [ ] **Step 2: Run it, expect failure**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests/DownloadViewModelTests 2>&1 | grep -iE "value of type|cannot find|error:|\*\* TEST"
```
Expected: FAIL — `value of type 'DownloadViewModel' has no member 'requiresSignIn'`.

- [ ] **Step 3: Implement** — in `DownloadViewModel.swift`, add two observed properties and a `retry()`, and set/reset them in `startDownload()`.

Add properties (next to `errorMessage`):
```swift
    private(set) var requiresSignIn = false
    private(set) var signInURL: URL?
```
At the top of `startDownload()`'s working section, reset them — replace:
```swift
        isWorking = true
        errorMessage = nil
        statusText = "Resolving…"
        defer { isWorking = false; statusText = nil }
```
with:
```swift
        isWorking = true
        errorMessage = nil
        requiresSignIn = false
        signInURL = nil
        statusText = "Resolving…"
        defer { isWorking = false; statusText = nil }
```
In the `catch let error as KeraunosError` block, flag the auth case — replace:
```swift
        } catch let error as KeraunosError {
            errorMessage = error.errorDescription
        }
```
with:
```swift
        } catch let error as KeraunosError {
            errorMessage = error.errorDescription
            if error == .requiresAuth {
                requiresSignIn = true
                signInURL = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
```
Add `retry()` after `startDownload()`:
```swift
    func retry() async { await startDownload() }
```

- [ ] **Step 4: Run it, expect pass** — same command as Step 2. Expected: PASS (existing view-model tests + the two new ones).

- [ ] **Step 5: Commit**

```bash
git add app/Keraunos/Keraunos/UI/DownloadViewModel.swift app/Keraunos/KeraunosTests/DownloadViewModelTests.swift
git commit -m "feat(ui): DownloadViewModel surfaces requiresSignIn + retry()"
```

---

## Task 6: `LoginWebView` + sign-in button & sheet

**Files:**
- Create: `app/Keraunos/Keraunos/Auth/LoginWebView.swift`
- Modify: `app/Keraunos/Keraunos/UI/DownloadScreen.swift`

> UI/WebKit — no unit test; verified by build + Task 8 manual acceptance.

- [ ] **Step 1: Create `Auth/LoginWebView.swift`**

```swift
import SwiftUI
import WebKit

/// A `WKWebView` on the shared cookie store, presented as a sheet so the user can
/// log into a site. Cookies the site sets land in `dataStore`, which CookieStore
/// later exports. Done/Cancel are owned by the presenting sheet's toolbar.
struct LoginWebView: UIViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}
}
```

- [ ] **Step 2: Add the sign-in button + sheet to `DownloadScreen.swift`** — the screen needs the `CookieStore` for the sheet's data store and a local presentation flag.

Add stored properties + init parameter. Replace the top of the struct:
```swift
struct DownloadScreen: View {
    @State private var model: DownloadViewModel

    init(model: DownloadViewModel) {
        _model = State(initialValue: model)
    }
```
with:
```swift
struct DownloadScreen: View {
    @State private var model: DownloadViewModel
    @State private var showLogin = false
    let cookieStore: CookieStore

    init(model: DownloadViewModel, cookieStore: CookieStore) {
        _model = State(initialValue: model)
        self.cookieStore = cookieStore
    }
```

Add the sign-in button: replace the error section:
```swift
                if let error = model.errorMessage {
                    Section { Text(error).foregroundStyle(.red) }
                }
```
with:
```swift
                if let error = model.errorMessage {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if model.requiresSignIn, let host = model.signInURL?.host {
                            Button("Sign in to \(host)") { showLogin = true }
                        }
                    }
                }
```

Add the sheet — attach to the `Form` (after the existing `.navigationTitle("Keraunos")` line, before the closing brace of `NavigationStack`'s content). Replace:
```swift
            .navigationTitle("Keraunos")
```
with:
```swift
            .navigationTitle("Keraunos")
            .sheet(isPresented: $showLogin) {
                NavigationStack {
                    if let url = model.signInURL {
                        LoginWebView(url: url, dataStore: cookieStore.dataStore)
                            .ignoresSafeArea()
                            .navigationTitle(url.host ?? "Sign in")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { showLogin = false }
                                }
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Done") {
                                        showLogin = false
                                        Task { await model.retry() }
                                    }
                                }
                            }
                    }
                }
            }
```

- [ ] **Step 3: Build, expect failure** — `ContentView` still calls `DownloadScreen(model:)` without `cookieStore`:

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild build -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" 2>&1 | grep -iE "error:|BUILD SUCCEEDED|BUILD FAILED"
```
Expected: `BUILD FAILED` — `missing argument for parameter 'cookieStore'` in `ContentView`. (Fixed in Task 7.)

- [ ] **Step 4: Commit**

```bash
git add app/Keraunos/Keraunos/Auth/LoginWebView.swift app/Keraunos/Keraunos/UI/DownloadScreen.swift
git commit -m "feat(ui): add LoginWebView sheet and Sign in button on requiresAuth"
```

---

## Task 7: `AccountsView` + `ContentView` wiring

**Files:**
- Create: `app/Keraunos/Keraunos/Auth/AccountsView.swift`
- Modify: `app/Keraunos/Keraunos/UI/DownloadScreen.swift` (toolbar entry)
- Modify: `app/Keraunos/Keraunos/ContentView.swift`

- [ ] **Step 1: Create `Auth/AccountsView.swift`**

```swift
import SwiftUI

/// Lists the sites the user is signed into and lets them sign out.
struct AccountsView: View {
    let cookieStore: CookieStore
    @State private var hosts: [String] = []

    var body: some View {
        List {
            if hosts.isEmpty {
                Text("Not signed in to any sites.").foregroundStyle(.secondary)
            } else {
                Section {
                    ForEach(hosts, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Sign out", role: .destructive) {
                                Task { await cookieStore.signOut(host: host); await reload() }
                            }
                        }
                    }
                }
                Section {
                    Button("Sign out of everything", role: .destructive) {
                        Task { await cookieStore.signOutAll(); await reload() }
                    }
                }
            }
        }
        .navigationTitle("Accounts")
        .task { await reload() }
    }

    private func reload() async {
        hosts = await cookieStore.signedInHosts()
    }
}
```

- [ ] **Step 2: Add the Accounts toolbar entry to `DownloadScreen.swift`** — add a toolbar after the `.sheet(...)` modifier from Task 6:

```swift
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AccountsView(cookieStore: cookieStore)
                    } label: {
                        Image(systemName: "person.circle")
                    }
                }
            }
```

- [ ] **Step 3: Wire `ContentView.swift`** — construct one `CookieStore`, inject it into `PythonExtractor` and `DownloadScreen`. Replace the file contents:

```swift
import SwiftUI
import KeraunosCore

struct ContentView: View {
    private let cookieStore = CookieStore()

    var body: some View {
        DownloadScreen(
            model: DownloadViewModel(
                extractor: PythonExtractor(cookieProvider: cookieStore),
                assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
                store: DownloadStore()),
            cookieStore: cookieStore)
    }
}

#Preview {
    let cookieStore = CookieStore()
    DownloadScreen(
        model: DownloadViewModel(
            extractor: MockExtractor(),
            assembler: MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger()),
            store: DownloadStore()),
        cookieStore: cookieStore)
}
```

- [ ] **Step 4: Build + run the whole app test suite, expect success**

```bash
DEST='platform=iOS Simulator,name=iPhone 17 Pro Max'
xcodebuild test -project app/Keraunos/Keraunos.xcodeproj -scheme Keraunos -destination "$DEST" -only-testing:KeraunosTests 2>&1 | grep -iE "error:|\*\* TEST"
```
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Run the whole Core suite + Python tests (nothing regressed)**

```bash
swift test --package-path app/KeraunosCore 2>&1 | grep -E "Test run with"
cd app/Keraunos/python-dev && .venv/bin/pytest -q ; cd /Users/leo/Developer/Keraunos
```
Expected: Core all pass; pytest all pass.

- [ ] **Step 6: Commit**

```bash
git add app/Keraunos/Keraunos/Auth/AccountsView.swift \
        app/Keraunos/Keraunos/UI/DownloadScreen.swift \
        app/Keraunos/Keraunos/ContentView.swift
git commit -m "feat(ui): add AccountsView and wire CookieStore through ContentView"
```

---

## Task 8: Manual acceptance

**Files:** none (manual; capture results in a log)

- [ ] **Step 1: First gated download triggers sign-in** — run the app (Xcode ▶, iPhone 17 Pro Max). Paste a URL for content that requires login (a private/age-restricted item, or a site that returns "login required"). Expected: the `.requiresAuth` message appears with a **"Sign in to *host*"** button.

- [ ] **Step 2: Log in and download** — tap the button; the login sheet opens the site; sign in; tap **Done**. Expected: the download retries and the `.mp4` appears in the list.

- [ ] **Step 3: Reuse the session** — paste another URL for the **same site**. Expected: it downloads **directly** — no `.requiresAuth`, no login sheet.

- [ ] **Step 4: Persist across launch** — quit and relaunch the app; paste a same-site URL again. Expected: still downloads directly (persistent cookies survived).

- [ ] **Step 5: Sign out** — open the Accounts screen (person icon), sign out of the host. Paste a same-site gated URL again. Expected: `.requiresAuth` + "Sign in" returns.

- [ ] **Step 6: Fail-open regression check** — with no sessions, confirm a public progressive download (an X video) still works exactly as before.

- [ ] **Step 7: Record results** — create `docs/logs/<today>-NN-authenticated-extraction-acceptance.md` (next free `NN` for the day): device/iOS, URLs tried, outcomes, whether sign-in/reuse/persist/sign-out behaved, built `.app` size (`du -sh`). Commit:

```bash
git add docs/logs/
git commit -m "docs(log): record authenticated extraction acceptance results"
```

- [ ] **Step 8: Done-check** — confirm the spec's done criteria:
  1. A gated source shows "Sign in to *host*"; completing the in-app login and retrying downloads it.
  2. After signing in, a later same-site URL downloads directly (incl. after relaunch).
  3. `AccountsView` lists hosts and signs out per host / all; signed-out host re-prompts.
  4. Cookie layer fails open: progressive X + DASH merge + error mapping unchanged with no/failed cookies.
  5. Cookies replayed via yt-dlp `cookiefile`, scoped per host; no long-lived plaintext cookie file persists between downloads.
  6. All tiers green: Core `swift test`, Python `pytest`, app `xcodebuild test`. YouTube best-effort (not a gate).

---

## Self-Review notes (for the executor)

- **Spec coverage:** Core `Cookie`+`NetscapeCookieWriter` (Task 1) · Python `cookiefile` (Task 2) · bridge + `PythonExtractor` + `CookieProviding` (Task 3) · `CookieStore` + mapping + sign-out (Task 4) · view-model auth-retry (Task 5) · `LoginWebView` + sign-in button/sheet (Task 6) · `AccountsView` + wiring (Task 7) · manual acceptance + done-check (Task 8). Fail-open is enforced in `CookieStore.cookieFile()` (returns nil on error) and the Python path-exists guard.
- **Type consistency:** `Cookie(name:value:domain:path:isSecure:expires:includeSubdomains:)`, `NetscapeCookieWriter.write(_:) -> String`, `CookieProviding.cookieFile() async -> URL?`, `CookieStore(dataStore:)` with `dataStore`/`signedInHosts()`/`signOut(host:)`/`signOutAll()`, `PythonExtractor(cookieProvider:)`, `keraunos_python_extract(url, cookieFilePath)`, Python `extract(url, socket_timeout, cookiefile)`, `DownloadViewModel.requiresSignIn`/`signInURL`/`retry()`, `DownloadScreen(model:cookieStore:)` — used identically across tasks.
- **Build sequencing:** Task 3's `cookieProvider` is a defaulted optional so the app keeps compiling; Task 6 intentionally breaks `ContentView` (missing `cookieStore:` arg) and Task 7 fixes it — the only red window, mirroring M2's documented pattern.
- **Deferred (NOT this milestone):** `cookies.txt` import, YouTube PO tokens / JS player, multiple accounts per site, per-download account selection, Keychain cookie storage, automatic login-success detection.
```
