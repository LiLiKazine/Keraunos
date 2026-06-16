# 2026-06-16-04: PO Token Provider — stub registration with yt-dlp's pot framework

**Status:** Implemented (stub; minting deferred to Task 9)

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

## Commits

| SHA | Description |
|-----|-------------|
| (see below) | feat(python): register a (stub) on-device PO token provider |
