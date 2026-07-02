# Releasing RunBot

This document is the single prose entry-point for shipping a new build.
All automation lives in [`publish.sh`](../publish.sh) (local) and
[`.github/workflows/publish.yml`](../.github/workflows/publish.yml) (CI).

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

1. **`publish.sh`** checks that the working tree is clean, then
   force-pushes the current HEAD to the `beta` or `release` routing branch.
2. **`publish.yml`** triggers on that push (or on `workflow_dispatch`):
   - Computes the next semver tag from git history.
   - Guards against duplicate tags.
   - Patches `Resources/Info.plist` with the computed version and a
     monotonic build number derived from the total commit count.
   - Runs `bash build.sh "$version"` with `CI=true` (skips local relaunch).
   - Verifies `dist/RunBot.zip` contains `RunBot.app/Contents/MacOS/RunBot`.
   - Generates a `RunBot.zip.sha256` sidecar via `shasum -a 256` and
     uploads it alongside the zip. **This step is load-bearing:** `AutoUpdater`
     treats a missing sidecar as a hard failure — every user's in-app update
     will fall back to the curl install command if the sidecar is absent from
     the release assets.
   - Creates an annotated git tag and pushes it.
   - Creates the GitHub Release with both the zip and the `.sha256` sidecar
     attached.

   > **Dry-run via `workflow_dispatch`:** When triggering manually from the
   > Actions UI, select the **`beta`** or **`release`** branch in the branch
   > selector to simulate the correct channel. Triggering from `main` (or any
   > other branch) will fail immediately: `publish.yml` validates
   > `GITHUB_REF_NAME` and aborts with an error if it is not `"beta"` or
   > `"release"`. There is no silent stable-path fallback.

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
  - `CFBundleShortVersionString` — the human-visible version (`X.Y.Z`).
  - `RBVersionString` — the full semver including pre-release suffix
    (e.g. `0.7.0-beta.2`). This is the key `UpdateChecker` reads at runtime
    for version comparison; it carries the beta suffix that
    `CFBundleShortVersionString` omits.
  - `CFBundleVersion` — monotonically increasing build number (git commit
    count); used by Gatekeeper ordering.
- **You never set the version manually.** CI computes it from the latest
  stable tag in git history and increments PATCH automatically.
- **Rollover:** PATCH rolls over from 9 → 0 and MINOR increments; MINOR
  rolls over from 9 → 0 and MAJOR increments. This keeps all components
  single-digit by convention.
- **Beta sequence:** multiple betas for the same base share the **current
  stable** `vX.Y.Z` base and increment only the `beta.N` suffix
  (e.g. `v0.7.0-beta.1`, `v0.7.0-beta.2`, …). The base is *not*
  pre-incremented to `vX.Y.(Z+1)` — betas sit on the same base as the
  current stable so that the stable release simply bumps PATCH when it
  ships, giving the correct ordering:
  `v0.7.0-beta.1` → `v0.7.0-beta.2` → `v0.7.1` (stable).
- **Promoting to stable:** run `./publish.sh` — CI bumps PATCH from the
  latest stable tag and creates `vX.Y.(Z+1)` regardless of how many betas
  preceded it.

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
