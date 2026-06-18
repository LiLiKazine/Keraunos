# 2026-06-18-01: Restore Python.xcframework on Xcode Cloud via ci_post_clone.sh

**Status:** Implemented

## Context

Xcode Cloud build #4 on `main` (commit `8a579c2`) failed in ~1m38s at link time:

```
There is no XCFramework found at
'/Volumes/workspace/repository/app/Keraunos/PythonResources/Python.xcframework'.
```

`Python.xcframework` (~115 MB, BeeWare Python-Apple-support `3.13-b14`) is gitignored
(`.gitignore:22`). It exists on local machines (restored manually per
`PythonResources/README.md`) but is absent from Xcode Cloud's clean `git clone`, so
the Build/Archive/Analyze actions all fail on the missing framework. Not a code
regression — an environment gap.

## Options

| Approach | Pros | Cons |
|----------|------|------|
| Commit framework via **Git LFS** | exact bytes versioned in-repo; offline-reproducible | Xcode's checkout doesn't reliably run the LFS smudge hook → leaves pointer files, reproducing the same error unless a `git lfs pull` step is added anyway; +115 MB to every clone; reverses the intentional gitignore |
| **`ci_post_clone.sh` fetch** (chosen) | lean repo (nothing committed); plain `curl` of a public release asset — no LFS moving parts; preserves existing gitignore design; automates the README's documented manual restore | re-downloads each clean build (~31 MB compressed, ~7s); pinned to BeeWare release tag `3.13-b14` (breaks if they delete the release) |
| Vendor as SPM binary target | checksum-pinned; declarative | bigger refactor — current wiring is Embed & Sign + a run-script that sources the framework's `build/utils.sh`, not SPM |

## Decision

Add `app/Keraunos/ci_scripts/ci_post_clone.sh` that downloads and unpacks the
BeeWare release into `PythonResources/` after the clean checkout. Keep the framework
gitignored.

## Rationale

The framework is a *reproducible public release artifact*, not bespoke in-repo
content — so versioning the bytes buys little. The decisive factor against LFS:
Xcode Cloud's LFS hydration is unreliable, so even the LFS route needs a post-clone
script — making the fetch script the same amount of CI plumbing with fewer failure
modes and no repo bloat.

## What Changed

- **Added** `app/Keraunos/ci_scripts/ci_post_clone.sh` (executable): idempotent
  fetch + extract of `Python-3.13-iOS-support.b14.tar.gz` into `PythonResources/`,
  keyed off `CI_PRIMARY_REPOSITORY_PATH`.
- **Updated** `PythonResources/README.md`: note that Xcode Cloud restores the
  framework automatically via the new script.

## What Was Discovered

- `ci_scripts/` must sit **next to the `.xcodeproj`** (`app/Keraunos/ci_scripts/`),
  not the repo root — Xcode Cloud searches relative to the project/workspace.
- The release tarball has `Python.xcframework/` (incl. `build/utils.sh`, which the
  build phase sources) at its **top level**, so a plain `cp -R` after extract is
  enough — matches the README's manual steps.
- Verified end-to-end locally against a throwaway `CI_PRIMARY_REPOSITORY_PATH`:
  cold run downloads/extracts a complete framework (device-slice binary + utils.sh
  present); second run is correctly idempotent (skips).
- The download is ~31 MB compressed → ~115 MB on disk; the size figure in earlier
  notes referred to the extracted framework, not the transfer.
