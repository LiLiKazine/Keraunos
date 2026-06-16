# 2026-06-16-04: PO Token Provider — stub registration with yt-dlp's pot framework

**Status:** Implemented (Tier 1 cold-start minting live; full BotGuard attestation deferred to Tier 2)

## Context

yt-dlp's YouTube extractor (2025.10.14+) uses a PO token (po_token) framework to
satisfy YouTube's bot-detection layer. Without a registered provider, yt-dlp proceeds
with no token — which may cause throttled or rejected requests for certain content.

Phase C (Task 8) registers an on-device stub provider so the framework is in place.
The actual minting flow (BotGuard VM → integrity token → mint via JavaScriptCore) is
Task 9.

## Options

| Approach | Pros | Cons |
|----------|------|------|
| Register provider at import time via @register_provider (chosen) | Idiomatic: mirrors how all yt-dlp built-in providers work; registration is automatic on import | Must ensure the module is imported early in the bridge lifecycle |
| Lazy registration (call register_provider() from extract()) | Avoids top-level side-effect | Non-standard, more code, risks double-registration if extract() is called repeatedly |
| Skip registration until Task 9 | No stub needed | Leaves the pot framework unwired; harder to test the registration path separately |

## Decision

Register `KeraunosPoTokenProviderPTP` at module import time via the `@register_provider`
decorator, and trigger that import from `keraunos_extract.py` at module load inside a
`try/except` (fail-open).

## Rationale

`@register_provider` is the canonical pattern used by all yt-dlp pot providers.
Registering from `keraunos_extract` at module load ensures the provider is available
for any `YoutubeIE.initialize_pot_director()` call that happens during extraction.
The `try/except` around the import means a broken provider file never breaks extraction
— yt-dlp degrades to no PO token rather than raising.

## What Changed

- **Added** `app/Keraunos/PythonResources/app/keraunos_youtube_pot.py` — defines
  `KeraunosPoTokenProviderPTP` (registered via `@register_provider`). `is_available()`
  returns `True`; `_real_request_pot` raises `PoTokenProviderRejectedRequest` until
  Task 9 fills in the minting flow.
- **Modified** `app/Keraunos/PythonResources/app/keraunos_extract.py` — added
  `import keraunos_youtube_pot` inside a `try/except` block at the bottom (alongside
  the existing `install_youtube_js_runtime()` try/except).
- **Added** `app/Keraunos/python-dev/test_pot_provider.py` — two tests: class
  structure (subclass of `PoTokenProvider`, name ends with `PTP`) and registry
  presence (`_pot_providers.value.values()`).

## Task 10: Graceful-degradation safety net (added 2026-06-16)

If Task 9 (BotGuard minting) ultimately can't supply a PO token, yt-dlp raises
`DownloadError` with a message like "… missing a GVS PO Token for video …". Without
the mapping, that falls through to `error_kind: unsupported` — confusing to the user.
The fix adds three PO-token hint strings to `_AUTH_HINTS` so the existing lowercase-match
handler maps the failure to `requires_auth` (user sees the Sign-in button).

### What changed (Task 10)

- **Modified** `app/Keraunos/PythonResources/app/keraunos_extract.py` — appended
  `"po token"`, `"po_token"`, `"missing a gvs po token"` to `_AUTH_HINTS`.
- **Modified** `app/Keraunos/python-dev/test_extract.py` — added
  `test_po_token_error_maps_to_requires_auth`: monkeypatches `extract_info` to raise
  `DownloadError("Sign in to confirm you're not a bot: missing a GVS PO Token for
  video abc123")` and asserts `error_kind == "requires_auth"`. 13/13 tests pass.

### What was discovered (Task 10)

- **The lowercase-match path was already correct.** `extract()` does
  `msg = str(e).lower()` before the hint check (line 146); only the hint strings were
  missing. No structural change to the exception handler needed.
- **Monkeypatching `YoutubeDL.extract_info` is the cleanest behavioral test.** The
  pure-helper path (`_payload_for_info`) doesn't exercise the exception handler, so
  testing at the `extract()` level via monkeypatch is the right layer. No network
  required; test is deterministic.
- **Generator-throw idiom for lambda raise.** CPython lambdas can't contain `raise`
  statements; used `(_ for _ in ()).throw(exc)` — a standard workaround that raises
  inline without a named helper.

## What Was Discovered

- **`PROVIDER_NAME` is a `classproperty`, not an overridable attribute.** The task
  stub specified `PROVIDER_NAME = "keraunos-jsc"` as a plain class attribute. In
  `_provider.py`, `PROVIDER_NAME` is defined as `@classproperty` on `IEContentProvider`
  and returns `cls.__name__[:-len(cls._PROVIDER_KEY_SUFFIX)]`. Setting it as a plain
  class attribute would shadow the classproperty (Python MRO allows this), but it is
  not the framework's intent and would make `PROVIDER_KEY` (used as the registry key)
  diverge. Removed the override — the computed name `KeraunosPoTokenProvider` is used.

- **Registry is `Indirect({})` — `.value` is the inner dict.** `_pot_providers` in
  `_registry.py` is an `Indirect` wrapper (from `yt_dlp.globals`). `Indirect.value` is
  set in `__init__` and is the unwrapped object. `register_provider_generic` mutates
  `_pot_providers.value` (the inner dict) directly. So `_pot_providers.value.values()`
  is the correct way to enumerate registered providers — the test assertion is correct
  as written.

- **`_SUPPORTED_CLIENTS` is typed as `tuple[str] | None`.** The stub used a Python
  tuple literal, which is correct. A list would also work at runtime but mismatches
  the type annotation; kept as tuple.

- **`_real_request_pot` signature uses `PoTokenRequest`, not a plain `request`.** The
  abstract method in `provider.py` is typed as `_real_request_pot(self, request:
  PoTokenRequest) -> PoTokenResponse`. The stub's untyped `request` parameter is
  fine (Python doesn't enforce parameter type annotations), but noted for Task 9 when
  the implementation will need the typed fields.

## Task 9: Tier 1 cold-start PO token minting (added 2026-06-16)

`_real_request_pot` is now implemented: it generates a cold-start PO token
synchronously via bgutils-js 3.2.0 evaluated in JavaScriptCore (no BotGuard VM,
no network). The token is bound to `visitor_data` or `data_sync_id` from the
`PoTokenRequest`. Full BotGuard attestation (Tier 2) is deferred.

### What changed (Task 9)

- **Modified** `app/Keraunos/PythonResources/app/keraunos_youtube_pot.py` — replaced
  stub `_real_request_pot` with Tier 1 implementation; added `_bundle_js()` (lazy-cached
  bundle reader) and `_cold_start_snippet(identifier)` module-level helpers; added
  `import json` and `from pathlib import Path`.
- **Modified** `app/Keraunos/python-dev/test_pot_provider.py` — added two tests:
  `test_cold_start_snippet_includes_bundle_and_identifier` (pure snippet, no provider
  construction) and `test_cold_start_returns_po_token_response` (wiring test using
  `object.__new__` + monkeypatched `_eval_js`). 15/15 pass.

### What was discovered (Task 9)

- **`PoTokenRequest` required fields are `context` and `innertube_context`** (positional);
  `visitor_data` and `data_sync_id` are optional `str | None`. `PoTokenResponse` only
  requires `po_token: str`; `expires_at` is optional.
- **`IEContentProviderLogger` is abstract with 5 required methods** (`trace`, `debug`,
  `info`, `warning`, `error`). Constructing the provider in tests would require either a
  full concrete implementation or a `MagicMock`. Used `object.__new__` to bypass
  `__init__` entirely — cleaner and no dependency on `unittest.mock`.
- **Circular import must be broken lazily.** `keraunos_extract` imports
  `keraunos_youtube_pot` at its bottom (line 165); importing `keraunos_extract` at
  module-top in `keraunos_youtube_pot` causes a circular import at import time. Resolved
  by importing `keraunos_extract` inside `_real_request_pot` (deferred to first call).
- **Cold-start validity.** The cold-start token works while YouTube's
  `StreamProtectionStatus` is 2. It does not require BotGuard attestation and is
  generated entirely offline. This is expected to work for most public content but may
  be rejected for content requiring a full attested token (StreamProtectionStatus ≥ 3).

## Task 9 polish: observability + clarity (added 2026-06-16)

Code-review pass on `keraunos_youtube_pot.py` to close observability and clarity gaps
identified after Task 9 landed.

### What changed (Task 9 polish)

- **Modified** `app/Keraunos/PythonResources/app/keraunos_youtube_pot.py`:
  - Both `PoTokenProviderRejectedRequest` raise sites now call `self.logger.warning()`
    first, so failures appear in the yt-dlp/Xcode console (previously silent).
  - Split the combined `not token or token.startswith(…)` guard into two separate
    branches: JS-error path (extracts the detail string) and empty-token path. Makes
    each failure mode individually diagnosable.
  - Added comment documenting why `video_id` is not a valid cold-start identifier and
    what happens when `StreamProtectionStatus != 2` (token rejected, degrades to
    no-token — Tier 2 attestation is not implemented).
  - Added comment in `_cold_start_snippet` noting bundle re-evaluation is safe because
    defining `globalThis.BG` is idempotent.

### What was discovered (Task 9 polish)

- **`token` from `_eval_js` is always a `str`** (console.log output, possibly `""`).
  This means `.startswith()` before the `not token` emptiness check is safe — an empty
  string returns `False` for `.startswith` and falls through to the `if not token` branch
  correctly. Order matters: check for JS-error prefix first, then empty.
- **Existing tests stay green without modification.** The success-path test uses
  `object.__new__` to bypass `__init__` (so `self.logger` is never set on the mock
  object) but never reaches either rejection branch — `_eval_js` is monkeypatched to
  return a valid token. No test exercises the rejection paths, so `self.logger` being
  absent on the test object is not a problem.

## Commits

| SHA | Description |
|-----|-------------|
| 27c0ef9 | feat(python): register a (stub) on-device PO token provider |
| b2ce449 | feat(python): map PO-token-required failures to a clear auth error |
| df747cb | feat(python): mint cold-start YouTube PO tokens via bgutils in JavaScriptCore |
| TBD     | refactor(python): log cold-start PO token rejections and clarify identifier/SPS limits |
