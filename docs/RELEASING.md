# Releasing RunBot

This document covers the mechanics of the `publish.yml` workflow — how versioning works, how to trigger releases, and how to recover from failures.

---

## Triggering a release

```sh
# Beta from main (most common)
gh workflow run publish.yml --ref main \
  --field branch=main \
  --field channel=beta

# Beta from a feature branch
gh workflow run publish.yml --ref main \
  --field branch=feature/my-branch \
  --field channel=beta

# Stable release from main
gh workflow run publish.yml --ref main \
  --field branch=main \
  --field channel=release

# Dry run (no tag, no plist commit, no GitHub Release)
gh workflow run publish.yml --ref main \
  --field branch=main \
  --field channel=beta \
  --field dry_run=true
```

**Important:** `--ref` must always be `main`. It controls which copy of `publish.yml` is read. The `--field branch=` input controls which branch is actually checked out and built.

When using the GitHub Actions UI, leave the "Use workflow from" selector on `main` and set the source branch via the **Branch** input field.

---

## Version scheme

| Channel   | Tag format                  | Example           |
|-----------|-----------------------------|-------------------|
| `beta`    | `vMAJOR.MINOR.(PATCH+1)-beta.N` | `v0.7.3-beta.1` |
| `release` | `vMAJOR.MINOR.PATCH`        | `v0.7.3`          |

### Why betas use `PATCH+1`

The [semver spec §9](https://semver.org/#spec-item-9) gives pre-release versions *lower* precedence than the normal version they annotate:

```text
v0.7.2-beta.1  <  v0.7.2
```

This means a beta tagged against the current stable base would appear *older* than the stable release it follows — UpdateChecker would never offer it as an update. Using `PATCH+1` as the beta base fixes this:

```text
v0.7.3-beta.1  >  v0.7.2   ✓ beta users are ahead of stable
```

Stable users not receiving beta updates is enforced by the update-channel preference in `UpdateChecker`, not by semver precedence.

### `CFBundleVersion` offset

`CFBundleVersion` is set from `git rev-list --count HEAD` *before* the plist commit step runs. This means the build number embedded in the bundle is `N`, while `git rev-list` at the tag SHA returns `N+1` (because the plist commit itself is counted). This is intentional — `CFBundleVersion` only needs to be monotonically increasing and the tag is pinned to the exact plist commit SHA.

### Rollover

When `PATCH` reaches `9` (i.e. `NEW_PATCH` would be `10`), it rolls over to `0` and `MINOR` increments; when `MINOR` reaches `9` it rolls over to `0` and `MAJOR` increments. The rollover condition in `publish.yml` is `> 9` — PATCH 8→9 does not roll, PATCH 9→(0 + MINOR bump) does. This is the project convention — do not change the rollover threshold without updating `publish.yml`.

---

## Rollback procedure

The workflow is designed so that partial failures leave the repo in a recoverable state. The most common partial failure is a cancelled or failed run that pushed a plist commit but not the tag.

### Plist commit pushed, no tag

```sh
# Revert the plist commit on the source branch.
# Use the exact SHA from the workflow run's 'Commit patched Info.plist' step
# output — do NOT use HEAD, as the branch may have advanced since the run.
git fetch origin <branch>
git checkout <branch>
git pull --ff-only origin <branch>
git revert <plist-commit-sha> --no-edit
git push origin <branch>
```

Then re-trigger the workflow. The duplicate-tag guard will pass because the tag was never pushed.

### Tag pushed, no GitHub Release

Delete the tag and re-run:

```sh
git push origin --delete <tag>
# then re-trigger the workflow
```

The plist commit is already on the branch — the next run will compute the same tag (since no new stable tag exists) and re-create it.

> ⚠️ **Do not skip the tag delete.** If you re-run without deleting the tag
> first, the duplicate-tag guard will abort the run immediately — no harm done,
> but the existing plist commit on the branch will permanently show the old
> version string until manually reverted. Always delete the tag before re-running.

---

## Tag-namespace collision recovery

### What can happen

Two concurrent beta runs from *different* branches (e.g. `main` and `feature/foo`) that share the same `LATEST_STABLE` base will both compute the same `NEXT_N` (e.g. `v0.7.3-beta.1`). They run in separate concurrency groups so they do not cancel each other. Both may pass the `Guard against duplicate tag` check if they race closely enough.

The collision surfaces at `git push origin $TAG` in the `Tag and push` step: one run pushes the tag successfully; the second run's push is rejected by the remote with a `already exists` error. This is **loud, non-destructive, and re-runnable** — no data is lost and the remote tag is authoritative.

### Recovery

1. Identify which run lost the race (the one whose `Tag and push` step failed).
2. The losing branch now has a plist commit with version strings for the tag that was never pushed on that branch (e.g. `beta.1`). Before re-running, revert that commit using its exact SHA from the workflow run logs — otherwise the next run will push `beta.2` on top of a stale `beta.1` plist commit, leaving two version-bump commits with no intervening real work.
3. Re-trigger the workflow from that branch. The tag counter will now advance to `beta.2` (because `beta.1` exists on origin), so the run will compute `v0.7.3-beta.2` and succeed.

> **Edge case:** if the branch had no other changes since the stale plist commit,
> reverting it produces an identical `Info.plist`. The next run's `git commit`
> will then fail with `nothing to commit` (caught loudly by `set -euo pipefail`).
> If this happens, make a trivial content change (e.g. amend the revert message)
> to give the plist patch a clean base to land on.

### Why no global serialisation lock

A global `concurrency.group` (without the branch component) would queue all publish runs behind each other regardless of branch. For teams releasing betas from multiple active feature branches, this creates unnecessary serialisation. The race-to-rejection failure mode is preferred: it is obvious, loud, and has a one-step recovery (re-run).

---

## Pinned action SHAs

Most `uses:` references in `publish.yml` are pinned to full commit SHAs. To update an action:

1. Find the new commit SHA on the action's repository.
2. Update the `uses:` line in `publish.yml`.
3. Update the inline comment with the version and date.

```yaml
# Example
uses: actions/checkout@<new-sha>  # v4.x.x
```

Do not use branch refs (e.g. `@main`, `@master`) or mutable tags (e.g. `@v4`) in release workflows — they allow silent behaviour changes on the next run.
