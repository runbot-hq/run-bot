# Releasing RunBot

This document is the single source of truth for shipping a new build — from
triggering CI to how the binary lands on a user's machine.
All automation lives in [`publish.sh`](../../publish.sh) (local) and
[`.github/workflows/publish.yml`](../../.github/workflows/publish.yml) (CI).

To verify the pipeline is healthy before shipping, run a dry run first —
see [**DRY_RUN.md**](DRY_RUN.md).

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

   > **Dry-run via `workflow_dispatch`:** See [DRY_RUN.md](DRY_RUN.md) for
   > step-by-step instructions and a full checklist of what to verify.

---

## Channels

| Command | Routing branch | Tag format | Release type | Marked latest |
|---|---|---|---|---|
| `./publish.sh -beta` | `beta` | `vX.Y.Z-beta.N` | Pre-release | No |
| `./publish.sh` | `release` | `vX.Y.Z` | Full release | Yes |

The `beta` and `release` branches are **ephemeral CI trigger targets**.
Do not commit to them directly or use them for long-lived work — they are
always force-pushed by `publish.sh`.

---

## Versioning rules

- **Source of truth:** `Resources/Info.plist`
  - `CFBundleShortVersionString` — the human-visible version (`X.Y.Z`)
  - `RBVersionString` — the full semver including pre-release suffix
    (e.g. `0.7.0-beta.2`). This is the key `UpdateChecker` reads at runtime
    for version comparison; it carries the beta suffix that
    `CFBundleShortVersionString` omits.
  - `CFBundleVersion` — monotonically increasing build number (git commit
    count); used by Gatekeeper ordering
- **You never set the version manually.** CI computes it from the latest
  stable tag in git history and increments PATCH automatically.
- **Rollover:** PATCH rolls over from 9 → 0 and MINOR increments; MINOR
  rolls over from 9 → 0 and MAJOR increments. This keeps all components
  single-digit by convention.
- **Beta sequence:** multiple betas for the same base share the **current
  stable** `vX.Y.Z` base and increment only the `beta.N` suffix
  (e.g. `v0.7.0-beta.1`, `v0.7.0-beta.2`, …). The base is *not*
  pre-incremented — betas sit on the current stable so the stable release
  simply bumps PATCH when it ships:
  `v0.7.0-beta.1` → `v0.7.0-beta.2` → `v0.7.1` (stable).
- **Promoting to stable:** run `./publish.sh` — CI bumps PATCH from the
  latest stable tag and creates `vX.Y.(Z+1)` regardless of how many betas
  preceded it.

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

At launch, `UpdateChecker` hits `GET /repos/.../releases`, sorts by semver
(not publish date), filters by `betaChannel` preference, and returns an
`UpdateCheckResult`. `AutoUpdater.handle()` writes `RunnerState.availableUpdate`
via `setAvailableUpdate()` — called on each check (launch-time and every
24-hour background tick). Settings → About reads that and shows the update
row if non-nil. For full details see [UPDATE_FLOW.md](UPDATE_FLOW.md).

---

## Related

- [UPDATE_FLOW.md](UPDATE_FLOW.md) — how the in-app updater detects, downloads, and installs updates
- [DRY_RUN.md](DRY_RUN.md) — how to test the pipeline without shipping a real release
