#!/usr/bin/env bash
# ⚠️  REVIEWER: This script is explicitly bash (see shebang above), NOT POSIX sh.
# DeepSource and shellcheck POSIX-mode will flag [[ ]], ==, and =~ as
# "undefined in POSIX sh" — those are false positives. All three constructs
# are well-defined in bash and are used intentionally throughout this script.
# Do NOT change [[ ]] to [ ] or =~ to expr/case to "fix" those warnings.
set -e

APP_NAME="RunBot"
OUT_DIR="dist"

# VERSION defaults to "0.0.0-dev" for local development convenience so that
# engineers can run `bash build.sh` without arguments during iteration.
# CI always passes the real version explicitly (see .github/workflows/),
# so the default never reaches a published build.
# The dev sentinel is intentionally not a real semver release tag — it will
# never satisfy the auto-updater's "newer version available" check, which
# prevents accidental self-update prompts during local testing.
# Do NOT replace this default with a real version number — that would mask
# CI misconfiguration by silently publishing a stale version string.
VERSION="${1:-0.0.0-dev}"
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

# SwiftPM copies Sources/RunBot/Resources/Assets.xcassets (declared via
# `resources: [.process("Resources")]` in Package.swift) into a
# RunBot_RunBot.bundle inside the build output directory. Note: `swift
# build` does NOT run actool here — the .xcassets folder is copied in
# uncompiled, as a plain subdirectory tree (no Assets.car). Copying the
# whole bundle into Contents/Resources/ is what lets Bundle.module (which
# resolves to Bundle.main.resourceURL + "/RunBot_RunBot.bundle" when
# running from an app bundle) actually find it at runtime — see issue
# #2079. Note this does NOT make NSImage(named:) able to see it (it only
# searches the flat Contents/Resources/ directory, not bundles nested
# inside it), and it does NOT make Bundle.module.image(forResource:) able
# to see it either (that's a flat, bundle-root-only lookup, and the PNG is
# 3 levels deep inside Assets.xcassets/StatusBarIcon.imageset/). The app
# code must load the PNG by its literal nested path instead — see
# AppDelegate+StatusItem.swift. Do NOT remove this copy step.
RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" \
     "$OUT_DIR/$APP_NAME.app/Contents/Resources/"
else
  echo "✗ Expected resource bundle not found at $RESOURCE_BUNDLE" >&2
  echo "  Asset catalog lookups (StatusBarIcon, etc.) will fail at runtime." >&2
  exit 1
fi

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
