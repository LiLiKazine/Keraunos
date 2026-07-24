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
