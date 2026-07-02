# Testing the publish pipeline (dry run)

The publish pipeline has a built-in dry-run mode that exercises every step
— tag computation, duplicate-tag guard, `Info.plist` patching, build, zip
verification, and SHA-256 sidecar generation — without creating a tag,
committing anything, or publishing a GitHub Release.

Use this to verify the pipeline is healthy before shipping a real release,
or after any changes to `publish.yml` or `build.sh`.

---

## How to trigger a dry run

1. Go to [Actions → Publish](../../actions/workflows/publish.yml).
2. Click **Run workflow** (top-right of the workflow list).
3. In the **Branch** dropdown, select **`beta`** or **`release`**.
   - `main` will fail immediately by design — `publish.yml` validates
     `GITHUB_REF_NAME` and aborts if it is not `beta` or `release`.
4. Set **Dry run** to **`true`**.
5. Click **Run workflow**.

---

## What runs (and what is skipped)

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

No commits are pushed, no tags are created, and no release is published
during a dry run.

---

## What to check in the dry-run log

After the run completes, open the workflow run and verify:

- **Compute next tag** — the computed tag looks correct (e.g. `v0.7.0-beta.1`
  for a beta dry run, `v0.7.1` for a stable dry run).
- **Guard against duplicate tag** — passes without aborting.
- **Patch Info.plist** — log line reads:
  `Patched Info.plist: shortVersion=X.Y.Z fullVersion=X.Y.Z[-beta.N] build=NNN`
- **Build** — exits 0; no Swift compiler errors.
- **Verify zip** — log line reads:
  `Zip verified: RunBot.app/Contents/MacOS/RunBot is present at archive root.`
- **Generate SHA-256 sidecar** — log line shows a 64-character hex digest.
- **Commit patched Info.plist**, **Tag and push**, **Create GitHub Release** —
  all show ❌ (skipped), confirming dry-run mode was active.

---

## After a successful dry run — firing a real release

Once the dry run passes, follow the steps in [RELEASING.md](RELEASING.md)
to publish a real beta or stable release.

---

## Troubleshooting

**"publish.yml must be triggered from 'beta' or 'release' branch"**\
You triggered from `main` or another branch. Re-run and select `beta` or
`release` in the Branch dropdown.

**Duplicate-tag guard fires during dry run**\
The tag that CI would compute already exists. This is safe — a dry run
would never push the tag anyway. Check whether the existing tag points at
the correct commit; if the pipeline is in a good state you can ignore this.

**Build fails**\
Run `swift build` and `bash build.sh <version>` locally first to isolate
whether the failure is in the source or the pipeline.
