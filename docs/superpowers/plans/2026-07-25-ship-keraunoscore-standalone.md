# Ship KeraunosCore as a Standalone Package — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `app/KeraunosCore` a publishable, MIT-licensed Swift package and publish it to a new public `KeraunosCore` repo via git subtree, keeping the monorepo the source of truth.

**Architecture:** All publish artifacts (LICENSE, README, .gitignore, CI workflow) are committed *inside* `app/KeraunosCore/` so they travel with the subtree and never diverge. A monorepo-root script (`scripts/publish-core.sh`) tests then subtree-pushes the package to the public repo. No source or manifest changes — ship the current public API as-is at `v0.1.0`.

**Tech Stack:** Swift 6 / Swift Package Manager, git subtree, GitHub Actions (macOS runner), Bash.

## Global Constraints

- Publish artifacts live **inside `app/KeraunosCore/`** (travel with the subtree). Exception: `publish-core.sh` lives at the **monorepo root** (must not travel).
- Library license: **MIT**, `Copyright (c) 2026 Leo`. Monorepo root stays **GPLv3** — do not touch the root `LICENSE`.
- **Ship as-is:** no changes to `Package.swift`, no `public`→`internal` changes, no source edits.
- Public repo name: **`KeraunosCore`**; first tag: **`v0.1.0`**; owner: `LiLiKazine` (`https://github.com/LiLiKazine/KeraunosCore.git`).
- Platform/tooling floor (unchanged, from `Package.swift`): iOS 26 / macOS 15, `swift-tools-version: 6.2`, Swift 6 language mode.
- No silent failures: shell script must `set -euo pipefail` and abort loudly on any failed step (project no-silent-failure rule).
- Test command of record: `swift test --package-path app/KeraunosCore` (simulator-free).

---

### Task 1: Publishable package metadata (LICENSE, README, .gitignore)

Adds the human-facing + housekeeping files that make the subtree a good standalone repo. No source changes, so the "test" is that the package still builds/tests clean and no user-specific cruft is tracked.

**Files:**
- Create: `app/KeraunosCore/LICENSE`
- Create: `app/KeraunosCore/README.md`
- Create: `app/KeraunosCore/.gitignore`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by later code tasks. Task 3's script and Task 4's publish rely on these files existing at these paths.

- [ ] **Step 1: Create the MIT license file**

Create `app/KeraunosCore/LICENSE` with exactly:

```
MIT License

Copyright (c) 2026 Leo

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 2: Create the package .gitignore**

Create `app/KeraunosCore/.gitignore` with exactly:

```
.build/
.swiftpm/xcode/xcuserdata/
.DS_Store
```

- [ ] **Step 3: Create the README**

Create `app/KeraunosCore/README.md` with exactly:

````markdown
# KeraunosCore

The platform-agnostic core of [Keraunos](https://github.com/LiLiKazine/Keraunos),
a video downloader for iOS/macOS. KeraunosCore does the **downloading**: URL
normalization, format selection, native `URLSession` transfer (including
ranged/chunked downloads for hosts that throttle full-file GETs), `AVFoundation`
DASH muxing (separate video+audio → one file), download stores, cookies, and a
typed error model.

It is protocol-seamed (`MediaExtracting`, `MediaMerging`, `FileDownloading`) so it
can be exercised without a simulator.

> **Extraction is not included.** Resolving a page URL to a direct media URL (in
> Keraunos, embedded CPython + yt-dlp) lives in the app, not here. You bring your
> own `MediaExtracting` implementation; KeraunosCore takes it from there.

> **Stability: 0.x.** The public API may change between minor versions.

## Requirements

- iOS 26 / macOS 15
- Swift 6 (language mode), Swift tools 6.2+

## Installation

Swift Package Manager:

```swift
.package(url: "https://github.com/LiLiKazine/KeraunosCore.git", from: "0.1.0")
```

Then add `"KeraunosCore"` to your target's dependencies.

## Quick start

```swift
import KeraunosCore

// 1. You resolve the page URL to media (bring your own MediaExtracting).
let media: ResolvedMedia = try await myExtractor.resolve(pageURL, option: nil)

// 2. KeraunosCore downloads it — muxing automatically if it's adaptive DASH.
let assembler = MediaAssembler(downloader: Downloader(), merger: AVFoundationMerger())
let store = DownloadStore()   // defaults to a per-user Downloads directory

let fileURL = try await assembler.assemble(media, into: store) { progress in
    print("progress: \(Int(progress * 100))%")
}
print("saved to \(fileURL.path)")
```

For a progressive (single-file) source, `assemble` downloads straight to the
store. For an adaptive source (`.adaptive(video:audio:)`), it downloads both
tracks and muxes them with `AVFoundationMerger`.

## License

MIT — see [LICENSE](LICENSE). Note: the full Keraunos **app** is licensed GPLv3;
only this core library is MIT.
````

- [ ] **Step 4: Verify the package still builds and tests clean**

Run: `swift test --package-path app/KeraunosCore`
Expected: build succeeds and all tests pass (no source changed, so this is a regression guard).

- [ ] **Step 5: Verify no user-specific cruft is staged**

Run: `git -C /Users/lili/Developer/Keraunos status --porcelain app/KeraunosCore`
Expected: only the three new files (`LICENSE`, `README.md`, `.gitignore`) appear as untracked/added — **no** `.swiftpm/xcode/xcuserdata/...` path. If an `xcuserdata` path appears, it must not be staged (the new `.gitignore` should already exclude it).

- [ ] **Step 6: Commit**

```bash
git add app/KeraunosCore/LICENSE app/KeraunosCore/README.md app/KeraunosCore/.gitignore
git commit -m "docs(core): add MIT license, README, and .gitignore for standalone publish

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: CI workflow inside the subtree

Gives the public repo a green-checkmark CI with zero extra maintenance. Lives inside `app/KeraunosCore/.github/` so it travels with the subtree and runs in the *public* repo (it will not trigger in the monorepo, whose workflows live at the monorepo root `.github/`).

**Files:**
- Create: `app/KeraunosCore/.github/workflows/ci.yml`

**Interfaces:**
- Consumes: the package at the subtree root (once published, `Package.swift` is at repo root).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Create the workflow**

Create `app/KeraunosCore/.github/workflows/ci.yml` with exactly:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    name: swift test (macOS)
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_26.app
      - name: Swift version
        run: swift --version
      - name: Test
        run: swift test
```

Note: paths in this file are relative to the **published repo root**, where
`Package.swift` sits at the top level — so a bare `swift test` is correct there.

- [ ] **Step 2: Validate the YAML parses**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('app/KeraunosCore/.github/workflows/ci.yml')); print('yaml ok')"`
Expected: prints `yaml ok` (no exception).

- [ ] **Step 3: Commit**

```bash
git add app/KeraunosCore/.github/workflows/ci.yml
git commit -m "ci(core): add swift test workflow for the standalone repo

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: The publish script

A monorepo-root script that gate-checks (clean tree + passing tests) then subtree-pushes `app/KeraunosCore` to the public repo, and reminds about tagging. Lives at the monorepo root so it does **not** travel into the public repo.

**Files:**
- Create: `scripts/publish-core.sh`

**Interfaces:**
- Consumes: the files from Tasks 1–2 at `app/KeraunosCore/`.
- Produces: the publish workflow used by Task 4. Reads one env var, `CORE_REMOTE` (default `core-public`), and pushes its `main`.

- [ ] **Step 1: Create the script**

Create `scripts/publish-core.sh` with exactly:

```bash
#!/usr/bin/env bash
#
# Publish app/KeraunosCore to the standalone public repo via git subtree.
#
# One-time setup (run once, by hand):
#   git remote add core-public git@github.com:LiLiKazine/KeraunosCore.git
#
# Usage:
#   scripts/publish-core.sh
#
# Override the remote name with CORE_REMOTE=... if you named it differently.

set -euo pipefail

PREFIX="app/KeraunosCore"
REMOTE="${CORE_REMOTE:-core-public}"
BRANCH="main"

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root"

# 1. Require a clean working tree — subtree push publishes committed state only.
if [ -n "$(git status --porcelain)" ]; then
  echo "error: working tree is dirty; commit or stash before publishing." >&2
  exit 1
fi

# 2. Require the remote to exist.
if ! git remote get-url "$REMOTE" >/dev/null 2>&1; then
  echo "error: git remote '$REMOTE' not found." >&2
  echo "       add it once with:" >&2
  echo "       git remote add $REMOTE git@github.com:LiLiKazine/KeraunosCore.git" >&2
  exit 1
fi

# 3. Tests must pass before anything is published.
echo "==> Running package tests..."
swift test --package-path "$PREFIX"

# 4. Publish the subtree.
echo "==> Pushing '$PREFIX' subtree to '$REMOTE' ($BRANCH)..."
git subtree push --prefix="$PREFIX" "$REMOTE" "$BRANCH"

echo
echo "==> Done. Now tag the release on the public repo, e.g.:"
echo "    git ls-remote --tags $REMOTE   # check existing tags"
echo "    Then create v0.1.0 in the KeraunosCore repo (via GitHub Releases or a tagged push)."
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x scripts/publish-core.sh`

- [ ] **Step 3: Verify the script is syntactically valid**

Run: `bash -n scripts/publish-core.sh && echo "syntax ok"`
Expected: prints `syntax ok`.

- [ ] **Step 4: Verify the dirty-tree / missing-remote guards fire**

Run: `CORE_REMOTE=definitely-not-a-remote bash scripts/publish-core.sh; echo "exit=$?"`
Expected: it aborts **before** running tests — either with the dirty-tree error (if the tree has uncommitted changes at this point) or the missing-remote error — and `exit=1`. It must NOT reach `Running package tests`.

- [ ] **Step 5: Commit**

```bash
git add scripts/publish-core.sh
git commit -m "chore: add publish-core.sh to subtree-push KeraunosCore to its public repo

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: First publish + tag + consumer smoke test

The one-time bring-up: create the public repo, run the script, tag `v0.1.0`, then prove an external package can actually resolve and import it. Several steps here are performed by the human operator (GitHub repo creation, auth); the plan calls those out explicitly.

**Files:**
- No repo files created. Produces the published `KeraunosCore` repo at `v0.1.0` and a throwaway consumer under the scratchpad.

**Interfaces:**
- Consumes: `scripts/publish-core.sh` (Task 3) and the committed subtree contents (Tasks 1–2).
- Produces: a public, resolvable package.

- [ ] **Step 1: Create the empty public repo (operator action)**

Create an **empty** public GitHub repo named `KeraunosCore` under `LiLiKazine`
(no README/license/gitignore — the subtree provides them). Either:
- Web UI: New repo → name `KeraunosCore` → Public → create with no files, **or**
- `gh repo create LiLiKazine/KeraunosCore --public --description "The download core of Keraunos (MIT)."`

- [ ] **Step 2: Add the remote (one-time)**

Run: `git remote add core-public git@github.com:LiLiKazine/KeraunosCore.git`
Then verify: `git remote get-url core-public`
Expected: prints the URL.

- [ ] **Step 3: Publish**

Run: `scripts/publish-core.sh`
Expected: tests run and pass, then `git subtree push` completes and prints the tag reminder. The push may take a moment (subtree computes the split history).

- [ ] **Step 4: Verify the public repo root looks right**

Run: `git ls-remote --heads core-public`
Expected: shows `refs/heads/main`.

Then confirm the root layout (web UI or a fresh clone into the scratchpad):

```bash
git clone --depth 1 git@github.com:LiLiKazine/KeraunosCore.git \
  /private/tmp/claude-501/-Users-lili-Developer-Keraunos/8223156d-23c6-41b7-b4c3-e592a8a860ef/scratchpad/KeraunosCore-verify
ls /private/tmp/claude-501/-Users-lili-Developer-Keraunos/8223156d-23c6-41b7-b4c3-e592a8a860ef/scratchpad/KeraunosCore-verify
```

Expected top-level entries: `Package.swift`, `Sources/`, `Tests/`, `LICENSE`,
`README.md`, `.github/`, `.gitignore` — and **no** `app/` nesting and **no**
`.swiftpm/xcode/xcuserdata/`.

- [ ] **Step 5: Tag v0.1.0 (operator action)**

In the cloned verify checkout (or via GitHub Releases):

```bash
cd /private/tmp/claude-501/-Users-lili-Developer-Keraunos/8223156d-23c6-41b7-b4c3-e592a8a860ef/scratchpad/KeraunosCore-verify
git tag v0.1.0
git push origin v0.1.0
```

Expected: `git ls-remote --tags git@github.com:LiLiKazine/KeraunosCore.git` shows `refs/tags/v0.1.0`.

- [ ] **Step 6: Consumer smoke test (write the failing check first)**

Create a throwaway consumer package:

```bash
mkdir -p /private/tmp/claude-501/-Users-lili-Developer-Keraunos/8223156d-23c6-41b7-b4c3-e592a8a860ef/scratchpad/consumer && cd $_
cat > Package.swift <<'EOF'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "consumer",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/LiLiKazine/KeraunosCore.git", from: "0.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "consumer",
            dependencies: [.product(name: "KeraunosCore", package: "KeraunosCore")]
        ),
    ]
)
EOF
mkdir -p Sources/consumer
cat > Sources/consumer/main.swift <<'EOF'
import KeraunosCore

// Touch a headline public type to prove the module resolves and imports.
let store = DownloadStore()
print("KeraunosCore resolved; downloads dir = \(store.directory.path)")
EOF
```

- [ ] **Step 7: Run the consumer build to verify resolution + import**

Run:
```bash
cd /private/tmp/claude-501/-Users-lili-Developer-Keraunos/8223156d-23c6-41b7-b4c3-e592a8a860ef/scratchpad/consumer && swift run
```
Expected: SPM resolves `KeraunosCore` at `0.1.0`, builds, and prints the
`KeraunosCore resolved; downloads dir = ...` line. A resolution failure or an
`import KeraunosCore` error means the publish/tag is wrong — fix before claiming done.

- [ ] **Step 8: Clean up scratch checkouts**

Run:
```bash
rm -rf \
  /private/tmp/claude-501/-Users-lili-Developer-Keraunos/8223156d-23c6-41b7-b4c3-e592a8a860ef/scratchpad/KeraunosCore-verify \
  /private/tmp/claude-501/-Users-lili-Developer-Keraunos/8223156d-23c6-41b7-b4c3-e592a8a860ef/scratchpad/consumer
```

There is nothing to commit in the monorepo for this task (all changes are in the public repo / scratch).

---

## Notes for the executor

- **Tasks 1–3 are fully autonomous** (create files, verify, commit).
- **Task 4 needs the operator** for GitHub repo creation, SSH/`gh` auth, and pushing a tag — pause and hand off at Step 1 if those aren't available in-session.
- If `swift test --package-path app/KeraunosCore` fails in Task 1 Step 4, that is a pre-existing regression, not caused by this plan — stop and report; do not proceed to publish.
