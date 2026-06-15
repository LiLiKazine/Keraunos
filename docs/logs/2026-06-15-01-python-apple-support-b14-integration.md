# 2026-06-15-01: Adapt Milestone 1 Phase 4 to Python-Apple-support b14

**Status:** Implemented (Task 10); guides Tasks 11–13

## Context

The Milestone 1 plan's Phase 4 (embedded Python) was written against an older
Python-Apple-support layout: a top-level `python-stdlib/` directory copied into
the app bundle alongside a hand-vendored `site-packages/`, with a C bridge that
sets `PYTHONHOME = <resources>` and manually appends `module_search_paths` for
`python-stdlib`, `site-packages`, and the resources root.

The current release (`3.13-b14`, the only 3.13 line available) ships a different
artifact: **no `python-stdlib` directory**. The stdlib lives inside
`Python.xcframework` (`lib/python3.13` shared + per-arch `lib-arm64`/`lib-x86_64`),
and a build-time script copies it into the bundle. The plan explicitly anticipated
this ("take the run-script verbatim from the release," "if the support package
nests it differently, adjust").

## Options

| Approach | Pros | Cons |
|----------|------|------|
| Pin an older release matching the plan's `python-stdlib` layout | No plan rewrite | The modern single-xcframework layout predates b14; no such recent release exists. Dead end. |
| Stop Phase 4, hand all embedding to the user | Avoids guessing | Leaves the milestone's headline feature unimplemented; the model is well-documented by the release testbed. |
| Adapt Phase 4 to the b14 model (chosen) | Faithful to the release's own reference integration; keeps the plan's architecture intact | Requires rewriting the bundle layout, run-script args, and the C bridge init |

## Decision

Adapt Tasks 10–13 to the canonical b14 integration demonstrated by the release's
`testbed` Xcode project and `Python.xcframework/build/utils.sh`.

## Rationale

The b14 `testbed` *is* the authoritative integration reference. Following it
(rather than the plan's outdated hand-rolled bridge) is the lowest-risk path and
matches what BeeWare tooling (`install_python`) expects.

Key model differences adopted:
- **Bundle layout:** `Python.xcframework` (embedded) + `app/` (our `.py` +
  `cacert.pem`) + `app_packages/` (vendored yt-dlp) folder references — instead of
  `python-stdlib/` + `site-packages/`.
- **Run-script:** `source .../Python.xcframework/build/utils.sh; install_python
  Python.xcframework <app> <app_packages>` copies the stdlib into
  `<bundle>/python/lib/python3.13` and processes dylibs.
- **Bridge init:** `PyPreConfig` (utf8) → `PyConfig_SetString(home,
  <resources>/python)` → `PyConfig_Read` → `Py_InitializeFromConfig` →
  `site.addsitedir(<resources>/app_packages)` → append `<resources>/app` to
  `sys.path`. (Plan's manual `module_search_paths` + `home=<resources>` is dropped.)

## What Changed (Task 10)

- Vendored pure-Python yt-dlp 2025.10.14 into `PythonRuntime/app_packages/`
  (no compiled extensions; removed unused `bin/`, `share/`).
- Copied certifi `cacert.pem` into `PythonRuntime/app/`.
- Moved `keraunos_extract.py` from `Resources/` to `app/` (b14 source dir);
  removed the now-empty `Resources/`.
- Updated `python-dev/test_extract.py` sys.path to the new `app/` location
  (2 tests still green).
- Placed `Python.xcframework` (3.13-b14) into `PythonRuntime/` (gitignored).
- Rewrote `PythonRuntime/README.md` for the b14 layout.

## What Was Discovered

- b14 `Python.xcframework` bundles `build/utils.sh` providing `install_python
  <framework> <app> <app_packages...>`, which selects the slice by
  `EFFECTIVE_PLATFORM_NAME` and processes `lib-dynload` + each package dir.
- Min iOS for b14 is 13.0 (well under our 26.5 target).
- yt-dlp is pure Python once the optional Crypto/brotli/curl_cffi extras are
  excluded, so `app_packages` contains no `.so` — `process_dylibs` is a no-op.
- Python version reported: 3.13.14.

## Follow-up: resource relocation (PythonRuntime → PythonResources)

The app target uses Xcode file-system-synchronized groups (`Keraunos/` is a
synchronized root). Placing `app/`/`app_packages/` under `Keraunos/PythonRuntime/`
would auto-include the `.py`/`.pem` files as target resources via the synchronized
group, with no reliable guarantee the `app/` and `app_packages/` directory
structure is preserved at the bundle root (the runtime requires `<bundle>/app/…`
and `<bundle>/app_packages/…` intact).

To match the BeeWare testbed's explicit folder-reference model and remove the
synchronized-group variable, the **resources** were moved to
`app/Keraunos/PythonResources/` (a sibling of `Keraunos.xcodeproj`, outside any
synchronized root); the **bridge source** (`PythonBridge.{h,m}`,
`PythonExtractor.swift`) stays under `Keraunos/PythonRuntime/` so it is still
auto-compiled. The run-script + folder-reference paths in Task 11 were updated
accordingly. The runtime bundle paths the Swift/C bridge computes are unchanged
(they derive from `Bundle.main.resourceURL`).
