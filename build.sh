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

# ── Resolve dependencies ─────────────────────────────────────────────
# All deps track a branch (not a tag/revision) — `swift package update` ensures
# the local Package.resolved is updated to the current branch HEAD before every
# build. Without this, `swift build` reuses the cached resolved versions and will
# miss commits pushed to dependency branches since the last update.
#
# ⚠️ NON-DETERMINISM NOTE: `swift package update` resolves ALL three branch-tracked
# deps (MenuBarKit, AppUpdater, GitHubClient) to their live branch HEAD at execution
# time — not just MenuBarKit. Two CI runs against the same run-bot commit SHA can
# produce different binaries if any commit lands on any of those branches between
# runs. This is an accepted and intentional trade-off for this PR:
# • MenuBarKit is temporarily pinned to fix/arrow-center-drift (see Package.swift).
#   Once that branch merges into MBK main, Package.swift reverts to branch: "main".
#   Tracked in #2275 — do not remove that issue until Package.swift is back on main.
# • AppUpdater and GitHubClient are internal repos; the non-determinism risk is low
#   but exists. Both will continue to track main after this PR merges.
echo "→ Updating dependencies..."
swift package update

# ── Validate XcodeGen ───────────────────────────────────────────────────
# XcodeGen is required to generate RunBot.xcodeproj before xcodebuild can run.
# Install via: brew install xcodegen
if ! command -v xcodegen &>/dev/null; then
  echo "✗ xcodegen not found. Install it with: brew install xcodegen" >&2
  exit 1
fi

# ── Prepare dist dir ─────────────────────────────────────────────────────────
# rm -rf is intentional and safe: OUT_DIR is always the hardcoded string
# "dist" — a local subdirectory relative to the project root, never an
# absolute or system path. It is never set from user input or environment
# variables. A full wipe before each build prevents stale files from a
# previous run being silently included in the zip.
echo "→ Preparing dist/..."
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# DerivedData is placed inside dist/ so the EXIT trap below can clean it up
# alongside the ephemeral .xcodeproj. Using a controlled path also avoids
# contaminating ~/Library/Developer/Xcode/DerivedData with release build
# artefacts from local iteration.
DERIVED_DATA="$OUT_DIR/DerivedData"

# ── EXIT trap: clean generated project + DerivedData ──────────────────────
# RunBot.xcodeproj is ephemeral: it is generated from project.yml, used for
# this build, then deleted. It must never be committed — see .gitignore.
# DerivedData is cleaned because it can be several GB and holds artefacts
# specific to this build configuration that are useless after the zip is made.
cleanup() {
  echo "→ Cleaning up ephemeral project and DerivedData..."
  rm -rf RunBot.xcodeproj
  rm -rf "$DERIVED_DATA"
}
trap cleanup EXIT

# ── Generate Xcode project ───────────────────────────────────────────────
# project.yml is the single source of truth for the app target definition.
# xcodegen generates RunBot.xcodeproj from it. The generated project is
# ephemeral — deleted by the EXIT trap above.
echo "→ Generating Xcode project..."
xcodegen generate

# ── Build with xcodebuild ──────────────────────────────────────────────────
# xcodebuild owns the full app-bundle construction:
#   • compiles Sources/ via the RunBot scheme
#   • runs actool to compile Assets.xcassets into Assets.car
#   • processes Resources/Info.plist (MARKETING_VERSION injected below)
#   • copies Resources/AppIcon.icns to Contents/Resources/
#   • places the binary at Contents/MacOS/RunBot
#
# ⚠️  DO NOT CHANGE THE ARCH BELOW ───────────────────────────────────
# This project targets Apple Silicon (arm64) ONLY.
# ARCHS=arm64 + ONLY_ACTIVE_ARCH=NO is the xcodebuild equivalent of the
# former --arch arm64 flag passed to `swift build`. The previous generic path
# (.build/apple/Products/Release/) caused stale build artefacts that led to
# hours of wasted debugging. Do not revert to a generic/universal build.
# ───────────────────────────────────────────────────────────────────────────
echo "→ Building with xcodebuild (Release, arm64)..."
xcodebuild build \
  -project RunBot.xcodeproj \
  -scheme RunBot \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION"

# ── Locate built .app in DerivedData ───────────────────────────────────────
# Use the deterministic Release product path rather than `find | head -1`.
# The find+head pattern silently selects the wrong bundle if DerivedData
# contains index, test-host, preview, or secondary build products with the
# same name. The Release path is always unambiguous for a `build` invocation.
BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
if [[ ! -d "$BUILT_APP" ]]; then
  echo "✗ Built ${APP_NAME}.app not found at expected Release path: $BUILT_APP" >&2
  exit 1
fi

# ── Copy .app to dist/ ───────────────────────────────────────────────────────
# ditto preserves macOS extended attributes, symlinks, and resource forks that
# standard `cp -r` may strip. Using ditto here is consistent with the zip step.
echo "→ Copying .app to dist/..."
ditto "$BUILT_APP" "$OUT_DIR/$APP_NAME.app"

# ── Post-build checks ───────────────────────────────────────────────────────────
# Explicit post-build guards confirm both icon pipelines are intact.
# These are belt-and-suspenders checks: xcodebuild should have failed if
# either resource was missing, but explicit guards catch silent omissions
# and give actionable error messages.

# Application icon: must be byte-for-byte identical to the committed source.
# Existence alone is not sufficient — a mismatched binary means the wrong
# icns was bundled (e.g. from a stale DerivedData cache or a wrong resources
# entry in project.yml).
cmp -s \
  Resources/AppIcon.icns \
  "$OUT_DIR/$APP_NAME.app/Contents/Resources/AppIcon.icns" || {
    echo "✗ Built AppIcon.icns differs from committed Resources/AppIcon.icns" >&2
    echo "  Check: Resources/AppIcon.icns is listed in project.yml resources" >&2
    exit 1
  }

# CFBundleIconFile must point to AppIcon so macOS resolves the dock/Finder icon.
BUNDLE_ICON=$(
  plutil -extract CFBundleIconFile raw \
    "$OUT_DIR/$APP_NAME.app/Contents/Info.plist"
)
[[ "$BUNDLE_ICON" == "AppIcon" ]] || {
  echo "✗ CFBundleIconFile mismatch: expected 'AppIcon', got '$BUNDLE_ICON'" >&2
  exit 1
}

# CFBundleShortVersionString must match the version passed to this script.
BUILT_VERSION=$(
  plutil -extract CFBundleShortVersionString raw \
    "$OUT_DIR/$APP_NAME.app/Contents/Info.plist"
)
if [[ "$BUILT_VERSION" != "$VERSION" ]]; then
  echo "✗ Version mismatch: expected $VERSION, got $BUILT_VERSION" >&2
  echo "  Check: Resources/Info.plist references \$(MARKETING_VERSION), not a literal string" >&2
  exit 1
fi

# Status-bar icon: actool must have produced Assets.car
if [[ ! -f "$OUT_DIR/$APP_NAME.app/Contents/Resources/Assets.car" ]]; then
  echo "✗ Assets.car missing from built bundle Contents/Resources/" >&2
  echo "  Check: Sources/RunBot/Resources/Assets.xcassets is listed in project.yml resources" >&2
  exit 1
fi

# Architecture check
BUILT_ARCH=$(lipo -archs "$OUT_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" 2>/dev/null || true)
if [[ "$BUILT_ARCH" != "arm64" ]]; then
  echo "✗ Architecture mismatch: expected arm64, got '${BUILT_ARCH}'" >&2
  exit 1
fi

# ── Signing ──────────────────────────────────────────────────────────────────────────
# codesign --sign - (ad-hoc identity) is used for both local dev builds and
# CI builds. publish.yml calls `bash build.sh` with CI=true and does not
# perform a separate Developer ID codesign step — the CI signing step is an
# Ed25519 signature of the zip for update verification (see the "Sign release
# zip" step in publish.yml), which is distinct from codesign certificate signing.
# There is currently no Gatekeeper notarisation in the release pipeline.
# See issue #2128 for the tracked work to add notarisation.
#
# --force: replaces any existing signature on re-runs without prompting.
# xcodebuild applies its own ad-hoc signature (CODE_SIGN_IDENTITY = "-" in
# project.yml). The explicit codesign call here re-signs the copied bundle
# to ensure a clean, consistent ad-hoc signature after ditto.
# --deep is NOT needed: Assets.car and AppIcon.icns are plain resource files,
# not nested bundles with executable code.
echo "→ Ad-hoc signing..."
codesign --force --sign - "$OUT_DIR/$APP_NAME.app"

# ── Zipping ──────────────────────────────────────────────────────────────────────────────
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

# ── Launch via `open` (not direct binary) ──────────────────────────────────────────────────
# IMPORTANT: The OAuth callback URL scheme (runbot://) is registered with
# macOS Launch Services only when the .app bundle is launched via `open` or
# Finder. Running the binary directly (./dist/RunBot.app/Contents/MacOS/RunBot)
# skips LS registration, so Safari cannot route runbot://oauth/callback
# back to the app and shows "address is invalid" instead.
#
# Always use `open dist/RunBot.app` for development — this script does it
# automatically. The pkill ensures a clean restart without a stale process.
# ───────────────────────────────────────────────────────────────────────────────────
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
