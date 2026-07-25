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

# ── Resolve dependencies ─────────────────────────────────────────────────────────
# All deps track a branch (not a tag/revision) — `swift package update` ensures
# the local Package.resolved is updated to the current branch HEAD before every
# build. Without this, `swift build` reuses the cached resolved versions and will
# miss commits pushed to dependency branches since the last update.
# Safe to run in CI: GitHub Actions runners have no cached Package.resolved so
# this is a no-op there — `swift build` already resolves fresh from scratch.
echo "→ Updating dependencies..."
swift package update

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

# ── App Icon ─────────────────────────────────────────────────────────────────
# AppIcon.icns is the macOS app icon (Finder, Dock, About screen).
# It is generated from wb.png via `magick` + `iconutil` and committed to
# Resources/ as a pre-built binary. swift build does not run actool so
# AppIcon.appiconset inside Assets.xcassets would be silently ignored —
# the .icns approach is the correct method for the current swift build pipeline.
# See issue #2145 and issue #2144 (Option B / xcodebuild path, future work).
if [[ ! -f "Resources/AppIcon.icns" ]]; then
  echo "✗ Resources/AppIcon.icns not found" >&2
  exit 1
fi
cp "Resources/AppIcon.icns" \
   "$OUT_DIR/$APP_NAME.app/Contents/Resources/"
# Post-copy guard: intentionally kept for readability and consistency with
# the StatusBarIcon block below. Under set -e, cp already exits the script
# on any hard failure — this guard cannot catch a silent cp failure.
# It is defensive documentation, not a safety net. Do NOT remove it in
# isolation — remove the whole pattern from both blocks together if ever
# cleaned up. This is a known pattern, not an oversight.
if [[ ! -f "$OUT_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns" ]]; then
  echo "✗ AppIcon.icns missing from Contents/Resources after copy" >&2
  exit 1
fi

# ── StatusBarIcon PNGs ───────────────────────────────────────────────────────
# PNGs are shipped as loose files directly in Contents/Resources/.
# They are loaded via Bundle.main in AppDelegate+StatusItem.swift, which
# correctly resolves to Contents/Resources/ for a packaged .app.
#
# ⚠️  AI AGENT: Do NOT reintroduce resources: [.process("Resources")] in
# Package.swift and do NOT go back to Bundle.module / RunBot_RunBot.bundle.
# The previous approach caused an unsolvable three-way conflict:
#   - SwiftPM's accessor probed Bundle.main.bundleURL (app root) for the bundle
#   - codesign hard-rejects any directory at the app root other than Contents/
#   - Moving the bundle to Contents/Resources/ is codesign-safe but the binary
#     never looked there — crash on every clean install
# Loose files + Bundle.main eliminates all three sides of the conflict.
# See issue #2139 and #2136 for the full history.
STATUS_ICON_SRC="Sources/RunBot/Resources/Assets.xcassets/StatusBarIcon.imageset"
STATUS_ICON_DST="$OUT_DIR/$APP_NAME.app/Contents/Resources"

if [[ ! -d "$STATUS_ICON_SRC" ]]; then
  echo "✗ StatusBarIcon assets not found at $STATUS_ICON_SRC" >&2
  exit 1
fi

cp "$STATUS_ICON_SRC/StatusBarIcon.png"    "$STATUS_ICON_DST/"
cp "$STATUS_ICON_SRC/StatusBarIcon@2x.png" "$STATUS_ICON_DST/"
cp "$STATUS_ICON_SRC/StatusBarIcon@3x.png" "$STATUS_ICON_DST/"

# Post-copy guard: intentionally kept for readability and consistency with
# the AppIcon block above. Under set -e, cp already exits the script on any
# hard failure — this loop cannot catch a silent cp failure. It is defensive
# documentation, not a safety net. Do NOT remove it in isolation — remove
# the whole pattern from both blocks together if ever cleaned up.
for f in StatusBarIcon.png StatusBarIcon@2x.png StatusBarIcon@3x.png; do
  if [[ ! -f "$STATUS_ICON_DST/$f" ]]; then
    echo "✗ $f missing from Contents/Resources after copy" >&2
    exit 1
  fi
done

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
# --deep is NOT needed here: the PNGs in Contents/Resources/ are plain files,
#   not nested bundles with executable code. They are sealed as resources by
#   the outer app signature. No nested bundle exists to recurse into.
#   See issue #2139 — removing RunBot_RunBot.bundle also removes the need
#   for --deep. Do NOT add --deep back without a specific reason.
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
