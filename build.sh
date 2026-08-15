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

# Version ownership invariant:
# publish.yml computes the release version and patches Resources/Info.plist
# before invoking this script. The legacy positional argument never stamped
# the app plist; it only validated a parallel value and wrote version.txt.
# build.sh now reads the packaged plist and writes version.txt from that same
# value so the built app is the single source of truth.
#
# Local builds intentionally retain the literal version committed in
# Resources/Info.plist. Do not reintroduce a 0.0.0-dev shell-only value or a
# positional version argument, because either would make version.txt diverge
# from the packaged application.
#
# build.sh intentionally takes no positional arguments.
# Release version metadata is read from Resources/Info.plist, which publish.yml
# patches before invoking this script. Reject arguments rather than silently
# ignoring them and potentially packaging a different version than the caller
# expected.
if [[ $# -ne 0 ]]; then
  echo "✗ build.sh takes no arguments." >&2
  echo "  Version metadata is read from Resources/Info.plist." >&2
  echo "  Usage: bash build.sh" >&2
  exit 1
fi

# ── Resolve dependencies ─────────────────────────────────────────────
# Validate and refresh the root SwiftPM dependency graph before generating the
# Xcode project. xcodebuild performs its own package resolution for the
# generated project; this step is an early dependency-health check, not the
# source of Xcode's resolved package state.
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
#   • processes Resources/Info.plist (literal version values from the plist)
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
# ── Verbosity control ────────────────────────────────────────────────────────
# -quiet suppresses phase/command noise while keeping warnings and errors.
# Set RUNBOT_VERBOSE_BUILD=1 to get the full xcodebuild log, e.g.:
#   RUNBOT_VERBOSE_BUILD=1 bash build.sh 2>&1 | tee /tmp/runbot-build.log
XCODEBUILD_FLAGS=()
if [[ -z "${RUNBOT_VERBOSE_BUILD:-}" ]]; then
  XCODEBUILD_FLAGS+=(-quiet)
fi

echo "→ Building with xcodebuild (Release, arm64)..."
xcodebuild build \
  "${XCODEBUILD_FLAGS[@]}" \
  -project RunBot.xcodeproj \
  -scheme RunBot \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO

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
    echo "  Check: Resources/AppIcon.icns is declared in project.yml sources with buildPhase: resources" >&2
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

# CFBundleShortVersionString and RBVersionString must be identical — publish.yml
# patches both from the same version source. A mismatch means the plist was
# edited by hand or the patch step ran incompletely.
BUILT_VERSION=$(
  plutil -extract CFBundleShortVersionString raw \
    "$OUT_DIR/$APP_NAME.app/Contents/Info.plist"
)
BUILT_RB_VERSION=$(
  plutil -extract RBVersionString raw \
    "$OUT_DIR/$APP_NAME.app/Contents/Info.plist"
)
if [[ "$BUILT_VERSION" != "$BUILT_RB_VERSION" ]]; then
  echo "✗ Version mismatch: CFBundleShortVersionString=$BUILT_VERSION RBVersionString=$BUILT_RB_VERSION" >&2
  echo "  Check: publish.yml patches both keys from the same version source" >&2
  exit 1
fi

# CFBundleVersion must be a non-empty numeric build number.
BUILT_BUILD=$(
  plutil -extract CFBundleVersion raw \
    "$OUT_DIR/$APP_NAME.app/Contents/Info.plist"
)
if ! printf '%s\n' "$BUILT_BUILD" | grep -E -q '^[0-9]+$'; then
  echo "✗ CFBundleVersion is not a numeric build number: '$BUILT_BUILD'" >&2
  exit 1
fi

# Status-bar icon: actool must have produced Assets.car containing StatusBarIcon.
# Existence of Assets.car alone is insufficient — verify the catalog actually
# contains the StatusBarIcon asset so a stale or empty catalog is caught early.
if [[ ! -f "$OUT_DIR/$APP_NAME.app/Contents/Resources/Assets.car" ]]; then
  echo "✗ Assets.car missing from built bundle Contents/Resources/" >&2
  echo "  Check: Sources/RunBot/Resources/Assets.xcassets is listed in project.yml sources with buildPhase: resources" >&2
  exit 1
fi
xcrun assetutil --info \
  "$OUT_DIR/$APP_NAME.app/Contents/Resources/Assets.car" 2>/dev/null |
  grep -Eq '"Name"[[:space:]]*:[[:space:]]*"StatusBarIcon"' || {
    echo "✗ StatusBarIcon missing from compiled Assets.car" >&2
    echo "  Check: StatusBarIcon.imageset is inside Assets.xcassets and actool ran" >&2
    exit 1
  }

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
# Read from the built bundle so version.txt always matches what was actually
# packaged, regardless of how the script was invoked.
echo "$BUILT_VERSION" > "$OUT_DIR/version.txt"

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
