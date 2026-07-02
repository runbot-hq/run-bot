#!/usr/bin/env bash
# ⚠️  REVIEWER: This script is explicitly bash (see shebang above), NOT POSIX sh.
# DeepSource and shellcheck POSIX-mode will flag [[ ]], ==, and =~ as
# "undefined in POSIX sh" — those are false positives. All three constructs
# are well-defined in bash and are used intentionally throughout this script.
# Do NOT change [[ ]] to [ ] or =~ to expr/case to "fix" those warnings.
set -e

APP_NAME="RunBot"
OUT_DIR="dist"

# VERSION must be supplied explicitly — no default is intentional.
# A silent fallback (e.g. ${1:-0.7.0}) would let CI publish a stale
# version if the workflow forgets to pass the input. Fail loudly instead.
if [[ -z "${1:-}" ]]; then
  echo "✗ Usage: bash build.sh <version>  e.g. bash build.sh 0.8.0" >&2
  exit 1
fi
VERSION="$1"
if ! printf '%s\n' "$VERSION" | grep -E -q '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$'; then
  echo "✗ Invalid version '${VERSION}'. Expected semver (e.g. 1.2.3 or 1.2.3-beta.1)" >&2
  exit 1
fi

# ── ⚠️  DO NOT CHANGE THE ARCH OR BUILD PATH BELOW ────────────────────────
# This project targets Apple Silicon (arm64) ONLY.
# The explicit --arch arm64 flag and the .build/arm64-apple-macosx/release/
# output path are INTENTIONAL. The previous arch-neutral path
# (.build/apple/Products/Release/) caused stale build artefacts that led to
# hours of wasted debugging. Do not revert to the generic path.
# ───────────────────────────────────────────────────────────────────────────
echo "→ Compiling arm64 binary..."
swift build -c release --arch arm64

echo "→ Assembling .app bundle..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/Resources"

cp ".build/arm64-apple-macosx/release/$APP_NAME" \
   "$OUT_DIR/$APP_NAME.app/Contents/MacOS/"
cp "Resources/Info.plist" \
   "$OUT_DIR/$APP_NAME.app/Contents/"

echo "→ Ad-hoc signing..."
codesign --force --deep --sign - "$OUT_DIR/$APP_NAME.app"

echo "→ Zipping..."
ditto -c -k --keepParent \
    "$OUT_DIR/$APP_NAME.app" \
    "$OUT_DIR/RunBot.zip"

echo "$VERSION" > "$OUT_DIR/version.txt"

echo "✓ Done — dist/RunBot.zip is ready"

# ── Launch via `open` (not direct binary) ───────────────────────────────────
# IMPORTANT: The OAuth callback URL scheme (runbot://) is registered with
# macOS Launch Services only when the .app bundle is launched via `open` or
# Finder. Running the binary directly (./dist/RunBot.app/Contents/MacOS/RunBot)
# skips LS registration, so Safari cannot route runbot://oauth/callback
# back to the app and shows "address is invalid" instead.
#
# Always use `open dist/RunBot.app` for development — this script does it
# automatically. The pkill ensures a clean restart without a stale process.
# ────────────────────────────────────────────────────────────────────────────
# Only kill/relaunch the running app when building locally, not in CI.
if [[ -z "${CI:-}" ]]; then
    echo "→ Restarting app via open (registers runbot:// URL scheme)..."
    pkill -x RunBot 2>/dev/null || true
    sleep 0.5
    open "$OUT_DIR/$APP_NAME.app"
    echo "✓ RunBot launched"
fi
