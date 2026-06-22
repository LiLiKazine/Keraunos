# Plan: content-state error kinds (`unavailable`, `rateLimited`)

Date: 2026-06-22 · Roadmap item: BACKLOG #2 (error-mapping completeness), thin slice.

## Problem

Today the Python extraction boundary collapses two distinct, common content-state
failures into misleading buckets:

- **Removed / private / geo-blocked video** → falls through to the generic
  `unsupported` ("This link isn't supported."). The owner can't tell a *gone* video
  from a *tool bug*.
- **Rate-limit (HTTP 429 / "too many requests")** → matches `"unable to download"`
  and lands in `extract_network` ("check your connection", auto-retried). Wrong advice
  and wrong remedy — hammering a rate-limited host immediately is exactly backwards.

For a hand-run, no-telemetry 7-site tool, the failure message is the only diagnostic,
so a precise kind is the whole value.

## Change

Add two `error_kind`s end-to-end. No new behavior beyond classification + message.

### Python (`keraunos_extract.py`, `_extract_impl` `except (DownloadError, ExtractorError)`)

Insert two checks, ordered AFTER the existing auth checks (auth hints + 401/403/412)
so private-with-"sign in" videos and bot-gates still route to `requires_auth`, and
BEFORE the `unable to download / connection` network check and the final `unsupported`:

1. `rate_limited`: message contains `"http error 429"` or `"too many requests"`.
2. `unavailable`: message contains any of a focused hint set —
   `video unavailable`, `this video is unavailable`, `no longer available`,
   `has been removed`, `removed by`, `has been terminated`, `this video is private`,
   `private video`, `content isn't available`, `content is not available`,
   `not available in your country`, `not available from your location`,
   `geo restrict`, `geo-restrict`, `blocked it in your country`.

### Swift (`KeraunosError.swift`)

- Add `case unavailable` and `case rateLimited`.
- `init(errorKind:)`: map `"unavailable"` and `"rate_limited"`.
- `kind`: `"unavailable"` / `"rate_limited"`.
- `isRetryable`: `unavailable → false`, `rateLimited → true`.
- `errorDescription`:
  - unavailable: "This video is unavailable — it may be private, removed, or geo-blocked."
  - rateLimited: "The site is limiting requests right now — wait a bit and try again."

### Auto-retry guard

Do NOT add `rateLimited` to `DownloadViewModel`'s auto-retry condition
(`error == .extractNetwork || error == .timedOut`). Rate-limit is *manually* retryable
(`canRetry == true`) after the user waits — never auto-hammered.

## Tests (TDD, write first)

- **Python** (`python-dev/test_extract.py`, monkeypatch `extract_info` to throw):
  - `HTTP Error 429: Too Many Requests` → `rate_limited`.
  - `Video unavailable` / `This video is no longer available` / geo message
    (`not made this video available in your country`) → `unavailable`.
  - Regression: a private-video message containing "Sign in" still → `requires_auth`
    (auth check wins, ordering guard).
  - Regression: plain connection failure still → `extract_network`.
- **Swift** (`KeraunosErrorTests.swift`): round-trip kind↔init for both new kinds;
  `isRetryable` (unavailable false, rateLimited true); non-nil `errorDescription`.

## Verify gate

Build + Swift Testing suite on iPhone 17 simulator must pass. Run the Python suite
(`python3 -m pytest app/Keraunos/python-dev/test_extract.py`) too, since the mapping
contract lives there.
