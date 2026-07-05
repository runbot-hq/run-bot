# Testing — UI Test Runner Setup

One-time manual steps required on the self-hosted Mac before UI tests will run unattended in CI.

## Triggering UI Tests

UI tests are **opt-in** — they do NOT run on every push or PR. They take over the
self-hosted Mac's display (WindowServer), so they must be requested explicitly.

### Opt-in via commit message

Add `[run ui tests]` anywhere in your commit message:

```bash
git commit -m "fix: settings navigation [run ui tests]"
git push
```

The CI job is skipped on all other commits. Both `push` and `pull_request`
events honour the flag.

### Opt-in via manual dispatch

You can also trigger the workflow manually from the GitHub Actions UI without
making a commit:

1. Go to **Actions → UI Tests**
2. Click **Run workflow**
3. Select the branch and click **Run workflow**

---

## 1. Grant Accessibility permission to Xcode

Without this step, every CI run will block on a system dialog:

> **"XCTest is trying to Enable UI Automation. Touch ID or enter your password to allow this."**

This dialog cannot be dismissed programmatically and will cause the workflow to hang until it times out.

### Fix (do once on the runner machine)

1. Open **System Settings → Privacy & Security → Accessibility**
2. Click **+** and add the following:
   - `/Applications/Xcode.app`
   - `/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild`
3. Make sure the toggle next to both entries is **enabled** (blue)

Once granted, macOS remembers the permission permanently and the popup will never appear again during CI runs.

> **Note:** If you install a new major version of Xcode (e.g. upgrade from Xcode 26 to Xcode 27), you may need to re-grant permission for the new app bundle.

## 2. Confirm the runner has a GUI session

UI tests require a live WindowServer session. The GitHub Actions runner **must** be installed as a user launch agent (not a system daemon).

Verify by running on the runner machine:

```bash
ls ~/Library/LaunchAgents/com.github.runner.*.plist
```

If that file exists, you have a GUI session. If it's missing and the runner is under `/Library/LaunchDaemons/` instead, reinstall it:

```bash
sudo ./svc.sh uninstall
./svc.sh install
./svc.sh start
```

### Reset instruction for local tests when they go stale

```
rm -rf .derived # clear stale app binary

xcodebuild build \
-project RunBot.xcodeproj \
-scheme RunBot \
-destination 'platform=macOS'
-derivedDataPath .derived

xcodebuild test \
-project RunBot.xcodeproj \
-scheme RunBotUITests \
-destination 'platform=macOS' \
-derivedDataPath .derived
-only-testing:RunBotUITests
2>&1 | tee uitest.log
```
