#!/usr/bin/env bash
# ⚠️  REVIEWER: This script is explicitly bash (see shebang above), NOT POSIX sh.
# DeepSource and shellcheck POSIX-mode will flag [[ ]], ==, and =~ as
# "undefined in POSIX sh" — those are false positives. All three constructs
# are well-defined in bash and are used intentionally throughout this script.
# Do NOT change [[ ]] to [ ] or =~ to expr/case to "fix" those warnings.

# ⚠️  set -e is intentional without -u or -o pipefail:
# • -u (treat unset vars as errors) is intentionally omitted — NOT because
#   ${var:-default} is unsafe under -u (it is safe; that construct is defined
#   precisely to handle the unset case), but because this script has not been
#   fully audited for unset variable references beyond the VERSION expansion.
#   Adding -u requires confirming every variable reference either has a value
#   or a default guard. That audit is deferred — tracked in issue #2131.
# • -o pipefail is intentionally omitted pending a full pipeline audit.
#   The version validation step already uses a printf | grep pipeline, and
#   further pipelines may be added in future. Until every pipeline in this
#   script is confirmed safe under pipefail, the flag stays off.
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
# rm -rf is intentional and safe: OUT_DIR is always the hardcoded string
# "dist" — a local subdirectory relative to the project root, never an
# absolute or system path. It is never set from user input or environment
# variables. A full wipe before each build prevents stale files from a
# previous run being silently included in the zip (e.g. a leftover binary
# from a different arch).
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/Resources"

cp ".build/arm64-apple-macosx/release/$APP_NAME" \
   "$OUT_DIR/$APP_NAME.app/Contents/MacOS/"
cp "Resources/Info.plist" \
   "$OUT_DIR/$APP_NAME.app/Contents/"

# ── Resource bundle ──────────────────────────────────────────────────────────
# SwiftPM's auto-generated resource_bundle_accessor.swift resolves
# Bundle.module via Bundle.main.bundleURL, which inside a .app is the app
# root (RunBot.app/). codesign rejects any directory at the app root other
# than Contents/ as "unsealed contents" — this is a hard platform constraint.
#
# The fix (issue #2138): flatten the SwiftPM-generated bundle's CONTENTS
# directly into Contents/Resources/ using ditto. This places:
#   Assets.xcassets/StatusBarIcon.imageset/...
# at:
#   Contents/Resources/Assets.xcassets/StatusBarIcon.imageset/...
#
# RunBotResources.swift then resolves the bundle via Bundle.main.resourceURL
# (which correctly points to Contents/Resources/ for a packaged .app) rather
# than via Bundle.module (which probes the app root).
#
# Do NOT copy the .bundle directory itself — that would place the wrapper at
# Contents/Resources/RunBot_RunBot.bundle and RunBotResources.bundle would
# not find Assets.xcassets at the expected path.
#
# Do NOT copy to the app root — codesign rejects it.
#
# ditto "$SRC/" "$DST/" (trailing slash on source) copies the CONTENTS of
# $SRC into $DST, not $SRC itself. This is intentional.
#
# NAMING: ${APP_NAME}_${APP_NAME}.bundle (doubled name) is NOT a typo.
# SwiftPM's bundle naming convention is <TargetName>_<ModuleName>.bundle.
# Because this package has a single target where the target name and module
# name are both "RunBot", the result is RunBot_RunBot.bundle.
RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"
RESOURCES_DIR="$OUT_DIR/$APP_NAME.app/Contents/Resources"

if [[ -d "$RESOURCE_BUNDLE" ]]; then
  # ditto preserves macOS extended attributes, symlinks, and resource forks.
  # Trailing slash on source copies contents, not the directory itself.
  ditto "$RESOURCE_BUNDLE/" "$RESOURCES_DIR/"
else
  echo "✗ Expected resource bundle not found at $RESOURCE_BUNDLE" >&2
  echo "  All RunBotResources.bundle access will fail at runtime (icons, assets, and all other resources)." >&2
  exit 1
fi

# ── Structural assertions ─────────────────────────────────────────────────────
# These run after assembly and before signing. They catch placement regressions
# immediately in CI rather than after a broken release is published.
APP="$OUT_DIR/$APP_NAME.app"

# 1. Confirm resources landed correctly (spot-check one file)
if [[ ! -f "$RESOURCES_DIR/Assets.xcassets/StatusBarIcon.imageset/StatusBarIcon.png" ]]; then
  echo "✗ StatusBarIcon resource missing from Contents/Resources — packaging is broken" >&2
  echo "  Expected: $RESOURCES_DIR/Assets.xcassets/StatusBarIcon.imageset/StatusBarIcon.png" >&2
  exit 1
fi

# 2. Guard: bundle wrapper must NOT exist at app root (codesign rejects it)
if [[ -e "$APP/${APP_NAME}_${APP_NAME}.bundle" ]]; then
  echo "✗ SwiftPM resource bundle must not exist at the app root — codesign will reject it" >&2
  echo "  Found: $APP/${APP_NAME}_${APP_NAME}.bundle" >&2
  exit 1
fi

# 3. Guard: bundle wrapper must NOT exist as a wrapper in Contents/Resources
#    (contents should be flattened in, not the .bundle dir itself)
if [[ -e "$RESOURCES_DIR/${APP_NAME}_${APP_NAME}.bundle" ]]; then
  echo "✗ SwiftPM bundle wrapper must not exist in Contents/Resources as a .bundle dir" >&2
  echo "  Contents must be flattened into Contents/Resources/ directly. See issue #2138." >&2
  exit 1
fi

# ── Signing ──────────────────────────────────────────────────────────────────
# codesign --sign - (ad-hoc identity) is used for both local dev builds and
# CI builds. publish.yml calls `bash build.sh` with CI=true and does not
# perform a separate Developer ID codesign step — the CI signing step is an
# Ed25519 signature of the zip for update verification (see the "Sign release
# zip" step in publish.yml), which is distinct from codesign certificate signing.
# There is currently no Gatekeeper notarisation in the release pipeline.
# See issue #2128 for the tracked work to add notarisation.
#
# --force: replaces any existing signature on re-runs without prompting.
#   Required because `swift build` may leave a partial sig on the binary.
#
# --deep is intentionally REMOVED (was present before issue #2138):
#   The resource bundle contents are now flattened into Contents/Resources/
#   as codeless data files (PNG images, asset catalog metadata). Codeless
#   resources inside Contents/ are sealed as part of the outer .app signature
#   automatically — they do not need to be separately signed, and --deep is
#   not required. --deep is deprecated by Apple for production builds anyway
#   (tracked in issue #2128). If nested executables, helpers, or frameworks
#   are added in future, sign them explicitly inside-out before this line.
echo "→ Ad-hoc signing..."
codesign --force --sign - "$OUT_DIR/$APP_NAME.app"

# ── Zipping ──────────────────────────────────────────────────────────────────
# ditto is used instead of zip/tar intentionally:
# • ditto preserves macOS extended attributes, symlinks, and resource forks
#   that standard `zip` and `tar` silently strip.
# • Stripping these breaks the .app bundle structure — macOS will refuse to
#   launch it or Gatekeeper will reject it.
# • The -c -k --keepParent flags produce a zip-format archive (not CPIO)
#   that is compatible with the `unzip` call in install.sh.
# Do NOT replace ditto with zip or tar.
echo "→ Zipping..."
ditto -c -k --keepParent \
    "$OUT_DIR/$APP_NAME.app" \
    "$OUT_DIR/RunBot.zip"

# version.txt is written as a build output alongside the zip. Its consumers
# are outside this script (install.sh and/or the gh-pages deploy pipeline).
# It is not read by publish.yml directly — that workflow derives the version
# from its own tag computation step.
echo "$VERSION" > "$OUT_DIR/version.txt"

echo "✓ Done — dist/RunBot.zip is ready"

# ── Launch via `open` (not direct binary) ────────────────────────────────────
# IMPORTANT: The OAuth callback URL scheme (runbot://) is registered with
# macOS Launch Services only when the .app bundle is launched via `open` or
# Finder. Running the binary directly (./dist/RunBot.app/Contents/MacOS/RunBot)
# skips LS registration, so Safari cannot route runbot://oauth/callback
# back to the app and shows "address is invalid" instead.
#
# Always use `open dist/RunBot.app` for development — this script does it
# automatically. The pkill ensures a clean restart without a stale process.
# ─────────────────────────────────────────────────────────────────────────────
# Only kill/relaunch the running app when building locally, not in CI.
if [[ -z "${CI:-}" ]]; then
    echo "→ Restarting app via open (registers runbot:// URL scheme)..."
    # pkill exits non-zero when no matching process is found — that is
    # expected on a first build and must not abort the script via set -e.
    # The || true suppresses that expected non-zero exit intentionally.
    pkill -x RunBot 2>/dev/null || true
    # sleep 0.5 gives Launch Services time to deregister the old bundle
    # before `open` re-registers it. Without this pause the URL scheme
    # (runbot://) can transiently resolve to the terminating process,
    # causing the first OAuth callback after a rebuild to silently fail.
    sleep 0.5
    open "$OUT_DIR/$APP_NAME.app"
    echo "✓ RunBot launched"
fi
