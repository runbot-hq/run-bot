## Contents

- [Quick reference](#quick-reference)
- [How the pipeline works](#how-the-pipeline-works)
- [Channels](#channels)
- [Versioning rules](#versioning-rules)
- [Build internals](#build-internals)
- [Distribution & install](#distribution--install)
- [Branch rules](#branch-rules)
- [`deploy.sh` deprecation](#deploysh-deprecation)
- [Rollback procedure](#rollback-procedure)
- [In-app update check](#in-app-update-check)
- [Dry run](#dry-run)
- [Update Flow](#update-flow)
- [Related](#related)

# Releasing RunBot

This document is the single source of truth for shipping a new build — from
triggering CI to how the binary lands on a user's machine.
All automation lives in [`publish.sh`](../../publish.sh) (local) and
[`.github/workflows/publish.yml`](../../.github/workflows/publish.yml) (CI).

To verify the pipeline is healthy before shipping, run a dry run first —
see [**Dry run**](#dry-run) below.

---

## Quick reference

```bash
# Pre-release (beta)
./publish.sh -beta

# Stable release
./publish.sh
```

That is the entire manual workflow. Everything else — tagging, building,
zipping, and creating the GitHub Release — is handled by CI automatically.

---

## How the pipeline works

1. **`publish.sh`** validates a clean working tree on `main`, then
   force-pushes `main` HEAD to either the `beta` or `release` routing branch.
   That push is the only trigger.
2. **`publish.yml`** picks it up and does all the real work in sequence:
   1. **Compute tag** — reads full git tag history, derives the next version
      automatically (no manual version bumping ever)
   2. **Guard duplicates** — aborts if that tag already exists on origin
   3. **Patch Info.plist** — writes `CFBundleShortVersionString` (X.Y.Z),
      `RBVersionString` (full semver incl. beta suffix), and `CFBundleVersion`
      (git commit count) — only in the CI artifact, never committed back to `main`
   4. **Build** — `bash build.sh <version>` compiles arm64, assembles `.app`,
      signs ad-hoc, zips to `dist/RunBot.zip` (see [Build internals](#build-internals) below)
   5. **Verify** — confirms the binary is actually present inside the zip
   6. **Generate SHA-256 sidecar** — computes a `shasum -a 256` digest and writes
      `RunBot.zip.sha256` alongside the zip. **This step is load-bearing:** `AppUpdater`
      treats a missing sidecar as a hard failure — every user's in-app update
      will fall back to the curl install command if the sidecar is absent
   7. **Tag + push** — creates an annotated git tag and pushes it
   8. **Create GitHub Release** — attaches both the zip and the SHA-256 sidecar,
      with `--prerelease` for beta or `--latest` for stable

   > **Dry-run via `workflow_dispatch`:** See [Dry run](#dry-run) below for
   > step-by-step instructions and a full checklist of what to verify.

---

## Channels

| Command | Routing branch | Tag format | Release type | Marked latest |
|---|---|---|---|---|
| `./publish.sh -beta` | `beta` | `vX.Y.(Z+1)-beta.N` | Pre-release | No |
| `./publish.sh` | `release` | `vX.Y.(Z+1)` | Full release | Yes |

The `beta` and `release` branches are **ephemeral CI trigger targets**.
Do not commit to them directly or use them for long-lived work — they are
always force-pushed by `publish.sh`.

---

## Versioning rules

- **Source of truth:** `Resources/Info.plist`
  - `CFBundleShortVersionString` — the human-visible version (`X.Y.Z`)
  - `RBVersionString` — the full semver including pre-release suffix
    (e.g. `0.7.3-beta.2`). This is the key `UpdateChecker` reads at runtime
    for version comparison; it carries the beta suffix that
    `CFBundleShortVersionString` omits.
  - `CFBundleVersion` — monotonically increasing build number (git commit
    count); used by Gatekeeper ordering
- **You never set the version manually.** CI computes it from the latest
  stable tag in git history and increments PATCH automatically.
- **Rollover:** PATCH rolls over from 9 → 0 and MINOR increments; MINOR
  rolls over from 9 → 0 and MAJOR increments. This keeps all components
  single-digit by convention.
- **Beta sequence:** betas are pre-releases of the **next** patch version,
  not the current stable. CI computes `NEXT_BASE = MAJOR.MINOR.(PATCH+1)`
  and tags betas as `vNEXT_BASE-beta.N`:
  ```
  v0.7.2 ships (stable)
    → v0.7.3-beta.1, v0.7.3-beta.2, …
    → v0.7.3 ships (stable)
  ```
  This is correct per the [semver spec §9](https://semver.org/#spec-item-9):
  `v0.7.3-beta.1 > v0.7.2`, so beta users are semver-ahead of stable users.
  Stable users are not offered betas via the update channel preference in
  `UpdateChecker`, not by semver precedence.
- **Promoting to stable:** run `./publish.sh` — CI bumps PATCH from the
  latest stable tag and creates `vX.Y.(Z+1)`, which is the same base the
  betas were already under. No version gap, no collision.

---

## Build internals

`build.sh` is what CI calls at step 4 above. It does four things:

```bash
# 1. Compile arm64 binary
swift build -c release --arch arm64

# 2. Assemble .app bundle
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/MacOS"
mkdir -p "$OUT_DIR/$APP_NAME.app/Contents/Resources"
cp ".build/arm64-apple-macosx/release/$APP_NAME" \
   "$OUT_DIR/$APP_NAME.app/Contents/MacOS/"
cp Resources/Info.plist "$OUT_DIR/$APP_NAME.app/Contents/"

# 3. Ad-hoc sign (required for Apple Silicon)
codesign --force --deep --sign - "$OUT_DIR/$APP_NAME.app"

# 4. Zip (preserves symlinks and resource forks)
ditto -c -k --keepParent \
  "$OUT_DIR/$APP_NAME.app" \
  "$OUT_DIR/RunBot.zip"
```

The output is always `dist/RunBot.zip`. CI then generates the `.sha256` sidecar
from that zip before attaching both to the GitHub Release.

---

## Distribution & install

RunBot is distributed as a zipped `.app` hosted on GitHub Releases. End users
install with a single `curl` command:

```bash
curl -fsSL https://runbot-hq.github.io/run-bot/install.sh | bash
```

The `install.sh` script downloads the zip, extracts it to `/Applications`,
and launches the app:

```bash
BASE="https://runbot-hq.github.io/run-bot"
TMP=$(mktemp -d)
curl -fsSL "$BASE/RunBot.zip" -o "$TMP/RunBot.zip"
rm -rf /Applications/RunBot.app
unzip -qo "$TMP/RunBot.zip" -d /Applications
rm -rf "$TMP"
open /Applications/RunBot.app
```

**Why no Gatekeeper fires:** `curl` does not set the `com.apple.quarantine`
extended attribute on downloaded files. Gatekeeper is only triggered by that
attribute. The `.app` lands in `/Applications` clean and opens without any
security dialog.

> **Architecture:** RunBot requires Apple Silicon (arm64). The build pipeline
> produces an arm64-only binary. Intel Macs are not supported.

---

## Branch rules

| Branch | Purpose | Push rule |
|---|---|---|
| `main` | Active development | Normal commits / PRs |
| `beta` | Beta CI trigger | Force-push via `publish.sh -beta` only |
| `release` | Stable CI trigger | Force-push via `publish.sh` only |

> ⚠️ **Do not add branch-protection rules to `beta` or `release`.** They
> are force-push targets. Protecting them will break `publish.sh`.

---

## `deploy.sh` deprecation

`deploy.sh` previously pushed build artefacts to `gh-pages` for the
install script at `https://eonist.github.io/run-bot/`. It is now
**deprecated and must not be run manually**.

`publish.yml` handles the full release. If the `gh-pages` install script
ever needs updating, add a `deploy-pages` step to `publish.yml` rather
than reviving `deploy.sh`.

---

## Rollback procedure

If a release needs to be pulled:

1. **Delete the GitHub Release** via the web UI or:
   ```bash
   gh release delete vX.Y.Z --yes
   ```
2. **Delete the tag** locally and on origin:
   ```bash
   git tag -d vX.Y.Z
   git push origin --delete vX.Y.Z
   ```
3. If the release was marked `--latest`, the previous stable release will
   automatically become latest once the bad release is deleted.
4. Investigate, fix, commit to `main`, then re-run `./publish.sh`.

> Do not re-use a deleted tag. CI's duplicate-tag guard will block it
> anyway — but more importantly, users who already downloaded the old zip
> would have no way to distinguish it from the new one.

---

## In-app update check

At launch, `AppUpdater.checkAndHandle(state:)` hits `GET /repos/.../releases`,
sorts by semver (not publish date), and filters by the `betaChannel` preference
from `AppPreferencesStore`. The result is applied to `RunnerState` via
`UpdateStateProviding.apply(_ phase:)`, which advances the state machine
(`idle` → `available` → `downloading` → `ready` / `failed`). After the
launch-time check, `AppUpdater.scheduleBackgroundCheck(state:)` registers a
repeating background check at `AppUpdater.checkInterval`. Settings → About
reads `RunnerState.availableUpdate` and shows the update row if non-nil.
For full details see [UPDATE_FLOW.md](UPDATE_FLOW.md).

---

## Dry run

The publish pipeline has a built-in dry-run mode that exercises every step
— tag computation, duplicate-tag guard, `Info.plist` patching, build, zip
verification, and SHA-256 sidecar generation — without creating a tag,
committing anything, or publishing a GitHub Release.

Use this to verify the pipeline is healthy before shipping a real release,
or after any changes to `publish.yml` or `build.sh`.

### How to trigger

1. Go to [Actions → Publish](../../actions/workflows/publish.yml).
2. Click **Run workflow** (top-right of the workflow list).
3. In the **Branch** dropdown, select **`beta`** or **`release`**.
   - `main` will fail immediately by design — `publish.yml` validates
     `GITHUB_REF_NAME` and aborts if it is not `beta` or `release`.
4. Set **Dry run** to **`true`**.
5. Click **Run workflow**.

### What runs (and what is skipped)

| Step | Dry run | Real run |
|---|---|---|
| Checkout | ✅ | ✅ |
| Compute next tag | ✅ | ✅ |
| Duplicate-tag guard | ✅ | ✅ |
| Patch `Info.plist` | ✅ | ✅ |
| Build | ✅ | ✅ |
| Verify zip | ✅ | ✅ |
| Generate SHA-256 sidecar | ✅ | ✅ |
| Commit patched `Info.plist` | ❌ skipped | ✅ |
| Tag + push | ❌ skipped | ✅ |
| Create GitHub Release | ❌ skipped | ✅ |

### What to check in the log

- **Compute next tag** — the computed tag looks correct (e.g. `v0.7.3-beta.1`
  for a beta dry run when latest stable is `v0.7.2`, or `v0.7.3` for a stable dry run)
- **Guard against duplicate tag** — passes without aborting
- **Patch Info.plist** — log line reads:
  `Patched Info.plist: shortVersion=X.Y.Z fullVersion=X.Y.Z[-beta.N] build=NNN`
- **Build** — exits 0; no Swift compiler errors
- **Verify zip** — log line reads:
  `Zip verified: RunBot.app/Contents/MacOS/RunBot is present at archive root.`
- **Generate SHA-256 sidecar** — log line shows a 64-character hex digest
- **Commit patched Info.plist**, **Tag and push**, **Create GitHub Release** —
  all show ❌ (skipped), confirming dry-run mode was active

### Troubleshooting

**"publish.yml must be triggered from 'beta' or 'release' branch"**\
You triggered from `main` or another branch. Re-run and select `beta` or
`release` in the Branch dropdown.

**Duplicate-tag guard fires during dry run**\
The tag that CI would compute already exists. This is safe — a dry run
would never push the tag anyway. Check whether the existing tag points at
the correct commit.

**Build fails**\
Run `swift build` and `bash build.sh <version>` locally first to isolate
whether the failure is in the source or the pipeline.

---

## Update Flow

RunBot checks for updates in the background and presents a single update row in **Settings → About**. There is no banner, no separate update UI anywhere else in the app.

### Flow step-by-step

1. **Trigger** — On launch and every 24 hours (60 seconds in DEBUG builds), `NSBackgroundActivityScheduler` fires `UpdateChecker.checkForUpdate`. If the system signals low battery or high CPU load, the check is deferred via the `shouldDefer` guard (`completion(.deferred)`).

2. **Version check** — `UpdateChecker` fetches releases from the GitHub REST API, performs a numeric semver comparison (handles `v`-prefix trimming and `beta.N` ordering), and identifies whether a newer `RunBot.zip` asset exists.

3. **Silent download** — If a newer release is found, the zip is downloaded silently in the background with no user interaction required. The zip is cached at:
   ```
   ~/Library/Caches/io.github.runbot-hq/RunBot-<version>.zip
   ```
   The version string and cache path are persisted in `UserDefaults` (`AutoUpdaterDefaults`) so the state survives force-quits.

4. **UI state** — Settings → About shows a single `updateActionRow`:

   | State | Button shown |
   |---|---|
   | Download in progress | `ProgressView` (spinner) |
   | Download complete | **Install & Relaunch** |
   | Failure (any step) | **Download** (browser fallback) |

5. **Install & Relaunch** — When the user taps **Install & Relaunch**, `AutoUpdater.installAndRelaunch` performs the following sequence:
   - Extracts the zip into a temporary directory using `ditto`
   - Replaces the running `RunBot.app` bundle using `FileManager.replaceItem(at:withItemAt:backupItemName:options:resultingItemURL:)` — an atomic rename-based swap; the old bundle is preserved as a named backup and removed on success, so a mid-swap crash cannot leave a half-written bundle
   - Relaunches via `open -n`
   - Terminates the current process via `NSApp.terminate(nil)`

   A double-tap guard (`@MainActor private static var isInstalling`) ensures concurrent install attempts are ignored until the app terminates.

   > ⚠️ **Permission note:** `replaceItem` requires write access to the directory containing `RunBot.app`. This works when RunBot is installed in `~/Applications` (the recommended location). If installed in the system `/Applications` directory, the process will not have write permission and Install & Relaunch will silently fall back to the browser Download button.

6. **Failure fallback** — Any failure during download, checksum verification, or install sets `updateActionFailed = true`. The row then shows a **Download** button that opens the GitHub releases page in the browser. The fallback also triggers when the `RunBot.zip` asset is missing from the release (`updateAssetMissing`).

### Integrity verification — v1 status

**SHA-256 checksum verification is implemented in v1.** `AutoUpdater.downloadUpdate` fetches the `RunBot.zip.sha256` sidecar asset from the GitHub Release, and `verifyChecksum` computes a `CryptoKit` SHA-256 digest of the downloaded zip and compares it against the expected hex string. A mismatch sets `updateActionFailed = true`.

Code-signing identity verification (`codesign --verify`) is deferred to [#1795](https://github.com/runbot-hq/run-bot/issues/1795). The `checksumURL` field is already decoded in `AvailableRelease` so that #1795 can add further verification logic without a model change.

### Key types

| Type | Role |
|---|---|
| `UpdateChecker` | Fetches releases, semver comparison, selects best asset |
| `AutoUpdater` | Caseless enum; static functions for download, install, relaunch |
| `RunnerState` | `@Observable @MainActor`; holds `availableUpdate`, `isInstalling`, `updateActionFailed` |
| `AutoUpdaterDefaults` | `UserDefaults` keys for persisting version + cache path |
| `AvailableRelease` | Decoded model; includes `checksumURL` for SHA-256 verification |

### Design constraints

- **One UI location only** — update UI appears exclusively in Settings → About. This is a hard constraint from the spec ([#1794](https://github.com/runbot-hq/run-bot/issues/1794)).
- **`NSApp.terminate(nil)` not `exit(0)`** — RunBot is non-sandboxed with no `applicationWillTerminate` side-effects that conflict with the handoff. `exit(0)` is the helper-process self-update pattern and was explicitly rejected.

---

## Related

- [#1794](https://github.com/runbot-hq/run-bot/issues/1794) — In-app auto-update spec
- [#1795](https://github.com/runbot-hq/run-bot/issues/1795) — Code-signing verification (v2)
- [#1797](https://github.com/runbot-hq/run-bot/issues/1797) — Step-by-step implementation plan
