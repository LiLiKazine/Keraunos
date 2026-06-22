# Plan: redact secrets in the failure log

Date: 2026-06-22 (cycle 3) · Roadmap item: BACKLOG #6 (FailureLog hardening), thin slice.

## Problem

`FailureLog` writes each failure as `timestamp \t kind \t url \t detail`. Two of those
fields can carry secrets:
- **detail** = `str(e)` from yt-dlp, whose error messages frequently embed the failing
  *signed media URL* (e.g. `...videoplayback?...&sig=...&pot=...`, CloudFront
  `?Policy=&Signature=&Key-Pair-Id=`, AWS `?X-Amz-Signature=`).
- **url** = the pasted page URL (usually clean, but share links can carry tokens).

The VM exposes `failureLogURL` for diagnostics export/share, so these persist and can
leave the device. Rotation/clear/flatten already exist; redaction does not.

## Change

Add `FailureLog.redact(_ text: String) -> String` that masks the *values* of
query parameters whose names are credential-bearing, anywhere in a string (works on
both a bare URL and free-text that embeds URLs). Apply it to BOTH `url` and `detail`
inside `line(...)` so every persisted line is already redacted.

- Match a param name only at a boundary (`?`, `&`, `;`, or whitespace) so `monkey=` is
  not mistaken for `key=`. Replace the value up to the next `&`, whitespace, or end with
  `REDACTED`.
- Sensitive names (case-insensitive): `token`, `access_token`, `sig`, `signature`,
  `key`, `key-pair-id`, `keyid`, `secret`, `password`, `pwd`, `passwd`, `auth`,
  `authorization`, `hmac`, `policy`, `x-amz-signature`, `x-amz-credential`,
  `x-amz-security-token`, `pot`.
- Leave non-sensitive params (`v`, `t`, `list`, `expires`, timestamps) untouched so the
  log stays diagnostic.

## Tests (TDD, write first) — `FailureLogTests.swift`

- `redactsSignedMediaURLParamsInDetail`: a detail string containing
  `https://r.googlevideo.com/videoplayback?id=abc&sig=SECRET123&pot=TOKEN` →
  `sig=REDACTED`, `pot=REDACTED`, but `id=abc` preserved.
- `redactsCloudFrontAndAwsParams`: `?Policy=P&Signature=S&Key-Pair-Id=K` and
  `?X-Amz-Signature=...&X-Amz-Credential=...` all → REDACTED (case-insensitive).
- `doesNotRedactNonSecretParams`: `youtube.com/watch?v=abc123&t=42&list=PL1` unchanged.
- `doesNotMatchParamNameSubstrings`: `?monkey=ok&lowkey=ok` unchanged ("key" boundary).
- `recordedLineIsRedacted`: `record(url:..., detail: "...sig=X...")` → `contents()`
  contains `REDACTED`, not `X`.
- Keep existing tests green (line shape, rotation, clear).

## Verify gate

Build + Swift Testing suite on iPhone 17 simulator. (Pure Swift — no Python change.)
