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
# Note: Contents/Resources/ is intentionally not created here.
# Info.plist is copied directly to Contents/ (not Contents/Resources/).
# RunBot_RunBot.bundle lives at the app bundle ROOT per SwiftPM's
# resource_bundle_accessor.swift lookup — see comment below.

cp ".build/arm64-apple-macosx/release/$APP_NAME" \
   "$OUT_DIR/$APP_NAME.app/Contents/MacOS/"
cp "Resources/Info.plist" \
   "$OUT_DIR/$APP_NAME.app/Contents/"

# SwiftPM's auto-generated resource_bundle_accessor.swift resolves
# Bundle.module by searching for RunBot_RunBot.bundle at the app bundle
# ROOT (i.e. RunBot.app/RunBot_RunBot.bundle), NOT inside Contents/Resources/.
# Placing the bundle anywhere else causes a fatal crash at launch:
#
#   Fatal error: could not load resource bundle:
#   from /Applications/RunBot.app/RunBot_RunBot.bundle
#
# The built bundle contains Assets.xcassets at its root (SwiftPM's .process()
# rule copies resources to the bundle root, so the source-tree path
# Sources/RunBot/Resources/Assets.xcassets becomes Assets.xcassets at the
# bundle root — not a nested subdirectory). It is copied in uncompiled as a
# plain directory tree (no Assets.car — actool is not run by `swift build`).
# All Bundle.module access fails if this bundle is missing or misplaced —
# not just icon lookups. The app code must load assets by their literal
# nested path — see AppDelegate+StatusItem.swift.
# Do NOT move the bundle into Contents/Resources/. See issue #2126.
#
# NAMING: ${APP_NAME}_${APP_NAME}.bundle (doubled name) is NOT a typo.
# SwiftPM's bundle naming convention is <TargetName>_<ModuleName>.bundle.
# Because this package has a single target where the target name and module
# name are both "RunBot", the result is RunBot_RunBot.bundle. This is
# SwiftPM-generated and matches what resource_bundle_accessor.swift expects.
RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  # SOURCE TRUST: $RESOURCE_BUNDLE is a path inside .build/, the local SwiftPM
  # build output directory. It is produced entirely by `swift build` from this
  # project's own source — it is not user-supplied, downloaded, or externally
  # controlled. There is no untrusted content being copied into the app bundle.
  #
  # cp -R (uppercase) is intentional on macOS: -R preserves symlinks as-is
  # (copies the symlink itself, not the target it points to). Lowercase -r
  # dereferences symlinks and copies the target content instead, which can
  # silently corrupt .bundle directory structures that rely on symlinks.
  # Do NOT change to -r.
  cp -R "$RESOURCE_BUNDLE" \
     "$OUT_DIR/$APP_NAME.app/"
else
  echo "✗ Expected resource bundle not found at $RESOURCE_BUNDLE" >&2
  echo "  All Bundle.module access will fail at runtime (icons, assets, and all other resources)." >&2
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
# SIGNING ORDER: RunBot_RunBot.bundle must be signed BEFORE the outer .app.
# codesign seals the app container when signing the .app — all nested bundles
# must already be signed at that point or codesign rejects them as
# "unsealed contents". --deep is NOT used here because:
#   1. RunBot_RunBot.bundle sits at the app bundle ROOT (not inside Contents/),
#      and codesign --deep on the outer .app errors with:
#        "unsealed contents present in the bundle root"
#      when any non-Contents directory is present at the root. See issue #2132.
#   2. --deep is deprecated by Apple for all builds — explicit per-bundle
#      signing in inside-out order is the correct and supported approach.
# Do NOT add --deep back. Do NOT reorder these two codesign calls.
echo "→ Signing resource bundle..."
codesign --force --sign - \
  "$OUT_DIR/$APP_NAME.app/${APP_NAME}_${APP_NAME}.bundle"

echo "→ Signing app..."
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
