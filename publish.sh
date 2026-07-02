#!/usr/bin/env bash
# ⚠️  REVIEWER: This script is explicitly bash (see shebang above), NOT POSIX sh.
# DeepSource and shellcheck POSIX-mode will flag [[ ]], ==, and =~ as
# "undefined in POSIX sh" — those are false positives. All three constructs
# are well-defined in bash and are used intentionally throughout this script.
# Do NOT change [[ ]] to [ ] or == to = to "fix" those warnings.
#
# publish.sh — local release orchestrator for RunBot.
#
# Usage:
#   ./publish.sh          # stable release  → force-pushes main → release branch
#   ./publish.sh -beta    # pre-release     → force-pushes main → beta branch
#
# CI (.github/workflows/publish.yml) triggers on push to `beta` or `release`
# and handles tagging, building, zipping, and creating the GitHub Release.
# This script is intentionally thin — all version computation lives in CI.
#
# Prerequisites:
#   - Working tree must be clean (no uncommitted changes or untracked files).
#   - Must be run from the repo root on the `main` branch.
#     This script intentionally publishes `main` only; the routing branch
#     (`beta` / `release`) is just a CI trigger target, not the source of truth.
set -euo pipefail

# ────────────────────────────────────────────────────────────────────
# Parse arguments
# ────────────────────────────────────────────────────────────────────
BETA=false
for arg in "$@"; do
    case "$arg" in
        -beta) BETA=true ;;
        *)
            echo "error: unknown argument: $arg" >&2
            echo "usage: ./publish.sh [-beta]" >&2
            exit 1
            ;;
    esac
done

# ────────────────────────────────────────────────────────────────────
# Dirty-tree guard
# A dirty working tree means uncommitted or untracked changes would be silently
# excluded from the release build. Abort early and let the user decide what to do.
# ────────────────────────────────────────────────────────────────────
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree is dirty. Commit, stash, or remove all changes before publishing." >&2
    git status --short >&2
    exit 1
fi

CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$CURRENT_BRANCH" != "main" ]]; then
    echo "error: publish.sh must be run from 'main' (current: '$CURRENT_BRANCH')." >&2
    echo "error: switch to main first so the release source is explicit and reproducible." >&2
    exit 1
fi

# ────────────────────────────────────────────────────────────────────
# Determine target branch
# ────────────────────────────────────────────────────────────────────
if [[ "$BETA" = true ]]; then
    BRANCH="beta"
else
    BRANCH="release"
fi

echo "➜ Publishing from branch '${CURRENT_BRANCH}' → '${BRANCH}'"

# ────────────────────────────────────────────────────────────────────
# Force-push main to the routing branch
# --force is intentional: these branches are ephemeral CI trigger targets,
# not long-lived history branches. Every push here is a deliberate "start a
# new release build from main at this exact commit".
#
# HEAD is guaranteed to be main here because of the branch guard above, but we
# still push main explicitly to make the source branch obvious in both the code
# and the git command itself.
# ────────────────────────────────────────────────────────────────────
git push --force origin "main:${BRANCH}"

echo ""
echo "✅ Pushed to '${BRANCH}'. CI will now tag, build, and publish the release."
echo "   Watch progress at: https://github.com/runbot-hq/run-bot/actions"
