# Keraunos — Authenticated Extraction (cookies via in-app login) Design

**Status:** Designed (awaiting review)
**Date:** 2026-06-16
**Builds on:** `2026-06-15-keraunos-dash-merge-design.md` (Milestone 2). Milestones 1–2
resolve and download/merge *unauthenticated* sources only.

## Goal

Let the user act as a **logged-in user** so extraction can reach content that a
signed-out request can't: account-gated, age-restricted, followers-only, and
rate-limited sources. The user signs into a site **inside the app** (a web view);
the captured session cookies are replayed to yt-dlp on every extraction.

This unlocks both ends of the "requires sign-in" wall we hit in practice
(Instagram reels returning *"rate-limit reached or login required"*, age-restricted
YouTube, etc.).

## Scope

**In scope**
- An in-app `WKWebView` login, triggered **on demand** when extraction fails with
  `.requiresAuth`, that captures the site's session cookies.
- Replaying those cookies to yt-dlp via its `cookiefile` option on **every**
  extraction, so a once-signed-in site downloads directly afterward.
- A small **manage view** to see signed-in hosts and sign out (per host / all).
- Cookie persistence across app launches for the cookies that matter (see below).

**Out of scope (deferred / non-goals)**
- **`cookiesfrombrowser`** — infeasible on iOS: the app sandbox cannot read a
  desktop browser's cookie database. The only viable on-device mechanisms are an
  in-app web-view login (chosen) or importing a `cookies.txt` file (rejected, see
  Approach).
- **YouTube anti-bot beyond cookies** — YouTube often also requires PO tokens / a
  JS-player runtime the embedded interpreter can't provide. Cookies help but are
  not always sufficient; **YouTube is best-effort, not an acceptance gate.**
- Persisting **session-only cookies** (no expiry) across full app termination —
  WebKit keeps those in memory only; we accept that and re-prompt when needed
  (see Persistence).
- Multiple accounts per site, account labels/avatars, per-download account
  selection, automatic login-success detection, cookie editing, encrypted
  Keychain cookie storage. (YAGNI.)

## Key constraints

- **No `cookiesfrombrowser` on iOS** (sandbox) → cookies must be captured in-app.
- **Embedded Python has no subprocess** (unchanged) — irrelevant here; yt-dlp's
  `cookiefile` is pure-Python file reading.
- **yt-dlp needs a file path** for cookies (`cookiefile`), so cookies must be
  materialized as a Netscape `cookies.txt` on disk for the duration of a call.

## Approach (chosen)

**In-app `WKWebView` login + WebKit-owned persistence + per-extraction cookie
export.** Cookies live in a persistent `WKWebsiteDataStore` (the same store the
login web view writes to). Before every extraction, the current cookies are
serialized to a short-lived, file-protected `cookies.txt` and handed to yt-dlp as
`cookiefile`; the temp file is deleted right after.

Rejected alternatives:
- **Import a `cookies.txt` file** (export from a desktop browser extension,
  transfer in) — minimal code and site-agnostic, but clunky UX, requires a desktop,
  and cookies must be re-exported when they expire. Poor fit for a mobile app.
- **Our own long-lived cookie jar** (protected file or Keychain) as the source of
  truth — guarantees persistence of even session-only cookies, but reintroduces a
  long-lived credential file we'd have to manage (merge/expiry/sign-out) and can
  replay stale session cookies. Not worth it: real login cookies are persistent and
  WebKit already protects its store.

The chosen shape leans on WebKit for the hard parts (persistence, at-rest
protection), keeps our on-disk footprint to a transient temp file, and is strictly
**additive** — any failure in the cookie layer degrades to "behave like the
no-cookies app," so it can't regress Milestone 1/2 behavior.

## Components

### `KeraunosCore` (pure, `swift test`-able)

| Component | Responsibility |
|-----------|----------------|
| `Cookie` | Neutral value type: `name, value, domain, path, isSecure, expires: Date?, includeSubdomains`. No WebKit dependency. |
| `NetscapeCookieWriter` | `write(_ cookies: [Cookie]) -> String` — serialize to the Netscape `cookies.txt` format yt-dlp expects. The highest-risk piece (tab layout, subdomain/secure flags, session vs. expiring), isolated and unit-tested. |

### App target (main-actor, SwiftUI / WebKit)

| Component | Responsibility |
|-----------|----------------|
| `CookieStore` (`@MainActor`) | Wraps one **persistent `WKWebsiteDataStore`**. `cookieFile() async -> URL?` reads `httpCookieStore.getAllCookies()`, maps to `[Cookie]`, serializes via `NetscapeCookieWriter`, writes a file-protected temp `cookies.txt`, returns its path (`nil` if no cookies). `signedInHosts() async -> [String]` returns the **distinct cookie domains, leading dot stripped, deduplicated** (no semantic filtering in this milestone). Also `signOut(host:) async`, `signOutAll() async`. Clears its temp subdir on init. |
| `CookieProviding` | Protocol `func cookieFile() async -> URL?`; `CookieStore` conforms. Lets `PythonExtractor` depend on an abstraction and tests inject a mock. |
| `LoginWebView` | `UIViewRepresentable` over `WKWebView` configured with the shared data store; presented as a sheet, loads the URL being downloaded (site bounces to its own login). Toolbar: **Cancel** / **Done**. |
| `AccountsView` | Manage view: lists signed-in hosts (registrable domains, light-filtered), per-row **Sign out**, footer **Sign out of everything**, empty state. |
| `PythonExtractor` (existing) | Gains an optional `any CookieProviding`. In `resolve`, `await`s `cookieFile()` (hops to main actor for WebKit), passes the path to the bridge, **`defer`-deletes** it. Cookies attached on **every** extraction. |
| `PythonBridge` (existing) | `keraunos_python_extract(url, cookieFilePath)` — passes the path to Python's `extract` as the **`cookiefile` keyword argument** (so `socket_timeout` keeps its default); a `NULL`/empty path means "no cookiefile". |
| `DownloadViewModel` (existing) | New state: `loginURL: URL?` (drives the sheet, `Identifiable`), a sign-in-needed flag derived from a caught `.requiresAuth`, and `retry()` = re-run `startDownload()` with current `urlText`. |

### Python

`extract(url, socket_timeout=…, cookiefile=None)` — adds `"cookiefile"` to the
yt-dlp opts **only when the path is non-nil and the file exists**; still total
(never raises). yt-dlp sends only request-host-matching cookies per request, so the
single shared jar never leaks one site's cookies to another host.

## Data flow

The motivating "sign in once, then download directly" scenario:

```
① First gated URL, no session yet
   DownloadViewModel.startDownload() → PythonExtractor.resolve(url)
     → cookieProvider.cookieFile() ⇒ nil (store empty)
     → bridge extract(url, cookieFilePath: nil) → yt-dlp ⇒ login required
   → throws .requiresAuth
   ViewModel: keep error text, set loginURL = url, show "Sign in to <host>"

② User taps "Sign in to <host>"
   ContentView presents LoginWebView(url) over the shared WKWebsiteDataStore
   User logs in → WebKit persists the site's session cookies to that store
   User taps Done → sheet dismisses → ViewModel.retry()

③ retry() == startDownload() again (same urlText) → resolve(url)
     → cookieFile() ⇒ writes /tmp/<uuid>/cookies.txt (now non-empty), returns path
     → bridge extract(url, cookieFilePath) → yt-dlp loads cookiefile ⇒ resolves
     → defer: delete temp cookies.txt
   → ResolvedMedia → MediaAssembler → file saved ✓

④–⑤ Second URL, same site (same run OR a later launch)
   startDownload() → resolve(url)
     → cookieFile() ⇒ cookies already present ⇒ returns path
     → yt-dlp sends cookies on the FIRST attempt ⇒ resolves directly
     → no .requiresAuth, no web view ✓
```

**Pivotal mechanic:** `cookieFile()` runs before *every* extraction, so an existing
session is always attached up front — step 5 never re-prompts. The login sheet
appears only when extraction actually returns `.requiresAuth`.

**Isolation / threading (consistent with the project model):**
- `PythonExtractor` is an `actor` on its own serial queue; the blocking Python call
  stays off the main thread.
- `CookieStore` is `@MainActor` (WebKit's cookie store is main-actor-friendly).
  `resolve` does `await cookieProvider?.cookieFile()` — suspends, hops to the main
  actor to read cookies + write the temp file, returns with just a `Sendable` `URL`.
  No shared WebKit state crosses actors.
- The temp `cookies.txt` lives under `FileManager.temporaryDirectory/<uuid>/` with
  `.completeFileProtection` and is `defer`-deleted after the bridge call (success or
  throw) — credentials never linger between downloads.

## Persistence

`CookieStore` uses a **persistent** `WKWebsiteDataStore` (disk-backed in the app
container):
- **Persistent cookies survive launches and full termination.** Real "stay logged
  in" cookies (Instagram `sessionid`, Google/YouTube auth cookies) carry long
  expiries and are written to disk by WebKit; on next launch `cookieFile()` reads
  them back and downloads go through directly.
- **Session-only cookies (no expiry) do not survive a full kill** — WebKit keeps
  them in memory only. Rare for auth; when it bites, the next download returns
  `.requiresAuth` and the self-healing re-login covers it.

## Error handling

The cookie layer **fails open** — every failure degrades to the no-cookies app.

| Situation | Where | Result |
|-----------|-------|--------|
| No session, gated site | yt-dlp → `.requiresAuth` | existing message **+** a "Sign in to *host*" button |
| Logged in, resolves | — | normal download |
| Session expired / invalidated | yt-dlp → `.requiresAuth` again | "Sign in" button reappears; user re-auths once (self-healing — no separate expiry state) |
| Logged in but rate-limited | yt-dlp → `.requiresAuth` ("rate-limit/login") | same affordance; retry later. We don't distinguish rate-limit from login |
| YouTube anti-bot even when logged in | yt-dlp → `.requiresAuth`/`.unsupported` | surfaced as-is; **not an acceptance gate** |
| Store empty / no cookies | `cookieFile()` → `nil` | extraction runs with no `cookiefile`; first-run & progressive (X) paths unchanged |
| Temp-file write fails | `cookieFile()` → `nil` (logged) | proceed without cookies; never turns a working download into an error |
| Bad/empty cookiefile path | Python guard | `"cookiefile"` added only if path exists; a malformed line at worst yields `.requiresAuth`, never a crash |
| Login web view cancelled | — | sheet dismisses, no retry, original error remains |
| Login succeeds but no usable cookies | retry → `.requiresAuth` | button reappears; bounded (user-driven), not a loop |
| Sign out (manage view) | `signOut`/`signOutAll` | removes host/all records; next extraction for that host returns `.requiresAuth` |

## UI changes

- **`DownloadScreen`**: when the shown error is `.requiresAuth`, render a **"Sign in
  to *host*"** button beneath it (host from `urlText`); tapping sets `loginURL`.
  Non-auth errors look exactly as today. A toolbar `person.circle` item →
  `AccountsView`.
- **`LoginWebView`** presented via `.sheet(item: $model.loginURL)`; **Done** triggers
  `retry()`, **Cancel** dismisses with no change. No success-detection heuristics.
- **`AccountsView`**: the distinct signed-in hosts (from `signedInHosts()`) with
  per-host and global sign-out; empty state "Not signed in to any sites."
- **`ContentView`**: build one `CookieStore`, inject it as the `PythonExtractor`'s
  `CookieProviding`, and pass it to the login sheet / `AccountsView`. Preview keeps
  mocks (no WebKit/interpreter).

## Testing

- **`KeraunosCore` (`swift test`, pure, TDD):** `NetscapeCookieWriter` — header line;
  7-field tab layout; `includeSubdomains` (leading `.` + `TRUE`) vs `FALSE`;
  `isSecure` column; persistent → epoch expiry vs **session → `0`**; path default
  `/`; multiple cookies keep order; odd values don't break columns. `Cookie` equality.
- **App (`xcodebuild test`, mocks/non-persistent store, no UI automation):**
  - `CookieStore` against a **non-persistent `WKWebsiteDataStore`**: `setCookie` two
    hosts → `cookieFile()` writes a file decoding to both; `signedInHosts()` returns
    both; `signOut(host:)` drops one; `signOutAll()` empties.
  - `HTTPCookie → Cookie` mapping (pure): domain/secure/expiry/subdomain map.
  - `DownloadViewModel` auth-retry with a **stateful `MockExtractor`** (`.requiresAuth`
    then success) + `MockCookieProviding`: first call sets `loginURL`/sign-in state
    with the right host; `retry()` succeeds and clears it; cancel leaves state intact.
  - **Fail-open:** `MockCookieProviding` returning `nil` → progressive success
    unaffected.
- **Python (`pytest`):** `extract(url, cookiefile=<temp>)` adds `cookiefile` and
  returns valid JSON (localhost progressive server + header-only `cookies.txt`);
  `extract(url, cookiefile="/does/not/exist")` does not crash (path-exists guard).
- **Manual acceptance (device + a real gated item):** first gated URL →
  `.requiresAuth` + "Sign in" → login sheet → Done → downloads; second URL same site
  → direct (no sheet); relaunch → still direct (persistent reuse); `AccountsView`
  sign-out → that host prompts login again.
- **Not automated (and why):** the live `WKWebView` login round-trip and real
  gated-site behavior — same rationale as M2's merge happy-path (real auth UI +
  nondeterministic gating don't belong in CI).

## Done criteria

1. A gated source that returns "requires sign-in" shows a **"Sign in to *host*"**
   action; completing the in-app login and retrying downloads it.
2. After signing into a site, a subsequent URL for that site downloads **directly**
   (no prompt), including after an app relaunch (persistent cookies).
3. `AccountsView` lists signed-in hosts and signs out per host / all; after sign-out
   that host prompts login again.
4. The cookie layer **fails open**: with no/failed cookies, Milestone 1/2 behavior
   (progressive X, DASH merge, error mapping) is unchanged.
5. Cookies are replayed via yt-dlp `cookiefile`, scoped per request host; no
   long-lived plaintext cookie file persists between downloads.
6. All tiers green: `KeraunosCore` `swift test`, Python `pytest`, app `xcodebuild
   test`. YouTube remains best-effort (not a gate).

## Future (not this milestone)

- A `cookies.txt` **import** path for users who already have a desktop cookie export.
- YouTube PO-token / JS-player support if/when broad YouTube coverage becomes a goal.
- Multiple accounts per site and per-download account selection.
