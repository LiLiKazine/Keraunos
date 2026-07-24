# Ship KeraunosCore as a standalone, shareable package

**Date:** 2026-07-25
**Status:** Approved (design), pending implementation plan

## Goal

Publish `KeraunosCore` so that it is **both** a real, add-by-URL Swift Package
Manager dependency **and** a clean public reference others can read and file
issues against.

## Decisions (locked)

| Question | Decision |
| --- | --- |
| Primary goal | Both: a consumable dependency **and** a public reference. |
| Hosting model | Separate public repo populated via **git subtree**; the monorepo stays the source of truth. |
| License (library) | **MIT** for `KeraunosCore` (the Keraunos app repo stays GPLv3). |
| API scope for first release | **Ship as-is, tag `v0.1.0`.** No curation, no `public`→`internal` changes, no 1.0/semver commitment. |
| Public repo name | `KeraunosCore` |
| First tag | `v0.1.0` |
| Copyright holder | `Leo` |

## Distribution model

The monorepo (`github.com/LiLiKazine/Keraunos`) remains the single source of
truth. `app/KeraunosCore` stays where it is edited, built, and tested daily; the
Keraunos app keeps depending on it as a local path package. Nothing about the
day-to-day dev loop changes.

A new **public GitHub repo `KeraunosCore`** (whose root **is** the package) is
populated by pushing the `app/KeraunosCore` subtree out on each release.
Consumers add it by URL:

```swift
.package(url: "https://github.com/LiLiKazine/KeraunosCore.git", from: "0.1.0")
```

### Key principle: publish artifacts live inside the subtree

Every file that makes the public repo good — `LICENSE`, `README.md`,
`.gitignore`, CI workflow — is committed **inside `app/KeraunosCore/`** so it
travels with the subtree and can never diverge from the monorepo. Nothing that
matters lives only in the public repo. The public repo is a pure projection of
`app/KeraunosCore`.

### Why subtree over full migration

The app and core co-evolve rapidly (recent history is almost entirely
transfer/finalize work spanning both layers), and the design spec is still
evolving. Subtree gives consumers a real add-by-URL package today without taxing
the tight cross-layer loop. Graduating to a fully separate repo later is cheap
if/when the API stabilizes; jumping early is painful to reverse.

## Licensing note

The monorepo root stays **GPLv3**. Placing an **MIT** `LICENSE` inside
`app/KeraunosCore/` is compatible: MIT is permissive, so the combined Keraunos
app remains GPLv3, while the standalone `KeraunosCore` repo is MIT and usable by
closed- or open-source apps alike. The MIT file must live inside the subtree so
it becomes the license of the public repo's root.

## Work items

All paths are inside the monorepo.

### 1. `app/KeraunosCore/LICENSE`
- Standard MIT license text.
- `Copyright (c) 2026 Leo`.

### 2. `app/KeraunosCore/README.md`
Contents:
- **What it is:** the platform-agnostic core of Keraunos — URL normalization,
  format selection, native `URLSession` transfer (incl. ranged/chunked),
  `AVFoundation`-based DASH muxing, stores, cookies, and the `KeraunosError`
  model. Protocol-seamed (`MediaExtracting`, `MediaMerging`, `PhotoSaving`) so it
  is testable without a simulator.
- **Note that it does NOT include extraction:** yt-dlp/CPython lives in the app
  target, not here. Consumers bring their own `MediaExtracting` implementation.
- **Install** snippet (the `.package(url:)` line above).
- **Quick usage** example: resolve media → `Downloader` → merge (short, illustrative).
- **Requirements:** iOS 26 / macOS 15, Swift 6 language mode.
- **Stability banner:** explicit "**0.x — the public API may change between
  minor versions.**"
- **License:** MIT, with a one-line pointer that the full Keraunos app is GPLv3.
- **Link back** to the Keraunos app repo.

### 3. `app/KeraunosCore/.gitignore`
- `.build/`
- `.swiftpm/xcode/xcuserdata/`
- (The user-specific `xcschememanagement.plist` is currently **untracked**, so it
  will not leak via subtree; the ignore rule keeps it that way.)

### 4. `app/KeraunosCore/.github/workflows/ci.yml`
- Runs on a macOS GitHub runner.
- Single job: `swift test` (the suite is simulator-free per project convention).
- Triggers on push and pull_request.
- Gives the public repo a green-checkmark CI with no extra maintenance.

### 5. `scripts/publish-core.sh` (monorepo root, **not** inside the subtree)
Behavior:
1. Verify a clean working tree (abort otherwise).
2. Run `swift test --package-path app/KeraunosCore`; abort on failure.
3. `git subtree push --prefix=app/KeraunosCore <core-remote> main`
   (documents adding the remote once: `git remote add core-public <url>`).
4. Print a reminder to create/push the release tag (`v0.1.0`) on the public repo.

The script must fail loudly on any step (no silent `try?`-style swallowing of
errors), consistent with the project's no-silent-failure rule.

### 6. `Package.swift`
- **Unchanged.** Ship-as-is means no manifest edits.

## Out of scope (explicitly not doing)

- No API curation; no `public`→`internal` visibility changes.
- No 1.0 release or semver-stability commitment.
- No moving the package out of the monorepo.
- No per-file license headers.
- No changes to the Keraunos app's dependency on the local path package.

## Verification

- `swift test --package-path app/KeraunosCore` passes locally before the first
  publish.
- After the first `publish-core.sh` run, a scratch consumer package can resolve
  `https://github.com/LiLiKazine/KeraunosCore.git` at `0.1.0` and `import
  KeraunosCore`.
- The public repo root contains `Package.swift`, `Sources/`, `Tests/`,
  `LICENSE` (MIT), `README.md`, and a passing CI run — and no user-specific
  `.swiftpm` cruft.
