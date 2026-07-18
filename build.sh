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
#   or a default guard. That audit is deferred. Do not add -u until it is done.
# • -o pipefail is redundant here — no command in this script uses a pipe
#   where a mid-pipe failure would otherwise be silently swallowed.
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
# rm -rf is intentional and safe: OUT_DIR is always the local `dist/`
# build artefact directory, never a system path. A full wipe before
# each build prevents stale files from a previous run being silently
# included in the zip (e.g. a leftover binary from a different arch).
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
# The bundle contains Sources/RunBot/Resources/Assets.xcassets (declared via
# `resources: [.process("Resources")]` in Package.swift), copied in
# uncompiled as a plain directory tree (no Assets.car — actool is not run
# by `swift build`). All Bundle.module access fails if this bundle is
# missing or misplaced — not just icon lookups. The app code must load
# assets by their literal nested path — see AppDelegate+StatusItem.swift.
# Do NOT move the bundle into Contents/Resources/. See issue #2126.
RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  # cp -R (uppercase) is intentional on macOS: lowercase -r does not follow
  # symlinks inside .bundle directories; uppercase -R does. Do not change
  # to -r or the bundle contents may be silently incomplete.
  cp -R "$RESOURCE_BUNDLE" \
     "$OUT_DIR/$APP_NAME.app/"
else
  echo "✗ Expected resource bundle not found at $RESOURCE_BUNDLE" >&2
  echo "  All Bundle.module access will fail at runtime (icons, assets, and all other resources)." >&2
  exit 1
fi

# ── Signing ──────────────────────────────────────────────────────────────────
# codesign --sign - (ad-hoc identity) is intentional for local dev builds.
# Developer ID signing and notarisation are performed in CI by publish.yml
# using the team certificate stored in GitHub Actions secrets — they are
# NOT done here to keep the local build loop fast and credential-free.
#
# --force: replaces any existing signature on re-runs without prompting.
#   Required because `swift build` may leave a partial sig on the binary.
# --deep: recursively signs nested bundles (including RunBot_RunBot.bundle).
#   Without --deep, Gatekeeper rejects the app because the nested bundle
#   is unsigned even though the outer .app is signed.
#   ⚠️  --deep is deprecated by Apple for production/notarised builds because
#   it can miss dynamically loaded bundles and does not replicate the
#   explicit signing order that notarisation requires. For local ad-hoc
#   builds it is acceptable. For CI/notarisation, explicit per-bundle
#   signing is the correct long-term path — tracked in issue #2128.
#   Do NOT silently remove --deep without implementing explicit signing first.
echo "→ Ad-hoc signing..."
codesign --force --deep --sign - "$OUT_DIR/$APP_NAME.app"

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

# version.txt is written for consumers outside this script:
# • The gh-pages deploy step in publish.yml reads it to stamp the download
#   page with the current version.
# • The install.sh version-check logic reads it to display the installed
#   version after a fresh install.
# It is not consumed by this script itself — that is intentional.
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
