# Release Pipeline — Overview

Two commands, that's it:

```bash
./publish.sh -beta   # pre-release
./publish.sh         # stable
```

## What Happens

`publish.sh` does almost nothing itself — it validates a clean working tree
on `main`, then force-pushes `main` HEAD to either the `beta` or `release`
routing branch. That push is the trigger.

`publish.yml` picks it up and does all the real work in sequence:

1. **Compute tag** — reads full git tag history, derives the next version
   automatically (no manual version bumping ever)
2. **Guard duplicates** — aborts if that tag already exists on origin
3. **Patch Info.plist** — writes `CFBundleShortVersionString` (X.Y.Z),
   `RBVersionString` (full semver incl. beta suffix), and `CFBundleVersion`
   (git commit count) — only in the CI artifact, never committed back to `main`
4. **Build** — `bash build.sh <version>` compiles arm64, assembles `.app`,
   signs ad-hoc, zips to `dist/RunBot.zip`
5. **Verify** — confirms the binary is actually present inside the zip
6. **Generate SHA-256 sidecar** — computes a `shasum -a 256` digest and writes
   `RunBot.zip.sha256` alongside the zip; both are uploaded with the release so
   `AutoUpdater` can verify integrity before installing
7. **Tag + push** — creates an annotated git tag and pushes it
8. **Create GitHub Release** — attaches both the zip and the SHA-256 sidecar,
   with `--prerelease` for beta or `--latest` for stable

## Versioning

| Action | Result |
|---|---|
| Beta push | `v0.7.0-beta.1`, `.2`, `.3`… (on current stable base) |
| Stable push | `v0.7.1` (patch bump from latest stable tag) |

Beta tags sit on the **current** stable base, not a pre-incremented one.
Stable always just bumps patch when it ships, regardless of how many betas
preceded it.

## In-App Update Check

At launch, `UpdateChecker` hits `GET /repos/.../releases`, sorts by semver
(not publish date), filters by `betaChannel` preference, and returns an
`UpdateCheckResult`. `AutoUpdater.handle()` writes `RunnerState.availableUpdate`
via `setAvailableUpdate()` — called on each check (launch-time and every
24-hour background tick). Settings → About reads that
and shows the update row if non-nil.

> For the full operator reference — rollback procedure, branch rules,
> deploy deprecation — see [`docs/RELEASING.md`](../RELEASING.md).
