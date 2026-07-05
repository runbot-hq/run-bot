# Update Flow

This document describes how RunBot detects, downloads, and installs updates automatically.

## Overview

RunBot checks for updates in the background and presents a single update row in
**Settings → About**. There is no banner, no separate update UI anywhere else in the app.

## Flow Step-by-Step

1. **Trigger** — On launch and every 24 hours (60 seconds in DEBUG builds),
   `NSBackgroundActivityScheduler` fires `UpdateChecker.checkForUpdate`.
   If the system signals low battery or high CPU load, the check is deferred via
   the `shouldDefer` guard (`completion(.deferred)`).

2. **Version check** — `UpdateChecker` fetches releases from the GitHub REST API,
   performs a numeric semver comparison (handles `v`-prefix trimming and `beta.N`
   ordering), and identifies whether a newer `RunBot.zip` asset exists.

3. **Silent download** — If a newer release is found, the zip is downloaded
   silently in the background with no user interaction required.
   The zip is cached at:
   ```
   ~/Library/Caches/io.github.runbot-hq/RunBot-<version>.zip
   ```
   The version string and cache path are persisted in `UserDefaults`
   (`AutoUpdaterDefaults`) so the state survives force-quits.

4. **UI state** — Settings → About shows a single `updateActionRow`:

   | State | Button shown |
   |---|---|
   | Download in progress | `ProgressView` (spinner) |
   | Download complete | **Install & Relaunch** |
   | Failure (any step) | **Download** (browser fallback) |

5. **Install & Relaunch** — When the user taps **Install & Relaunch**,
   `AutoUpdater.installAndRelaunch` performs the following sequence:
   - Extracts the zip into a temporary directory using `ditto`
   - Replaces the running `RunBot.app` bundle using `FileManager.replaceItem(at:withItemAt:backupItemName:options:resultingItemURL:)` — an atomic rename-based swap; the old bundle is preserved as a named backup and removed on success, so a mid-swap crash cannot leave a half-written bundle
   - Relaunches via `open -n`
   - Terminates the current process via `NSApp.terminate(nil)`

   A double-tap guard (`@MainActor private static var isInstalling`) ensures
   concurrent install attempts are ignored until the app terminates.

   > ⚠️ **Permission note:** `replaceItem` requires write access to the directory
   > containing `RunBot.app`. This works when RunBot is installed in `~/Applications`
   > (the recommended location). If installed in the system `/Applications` directory,
   > the process will not have write permission and Install & Relaunch will silently
   > fall back to the browser Download button. See the inline comment in
   > `AutoUpdater+Install.swift` step 3 for details.

6. **Failure fallback** — Any failure during download, checksum verification, or
   install sets `updateActionFailed = true`. The row then shows a **Download** button
   that opens the GitHub releases page in the browser.
   The fallback also triggers when the `RunBot.zip` asset is missing from
   the release (`updateAssetMissing`).

## Integrity Verification — v1 Status

**SHA-256 checksum verification is implemented in v1.** `AutoUpdater.downloadUpdate`
fetches the `RunBot.zip.sha256` sidecar asset from the GitHub Release, and
`verifyChecksum` computes a `CryptoKit` SHA-256 digest of the downloaded zip and
compares it against the expected hex string. A mismatch sets `updateActionFailed = true`.

Code-signing identity verification (`codesign --verify`) is **deferred to
[#1795](https://github.com/runbot-hq/run-bot/issues/1795)**.

The `checksumURL` field is already decoded in `AvailableRelease` so that #1795
can add further verification logic without a model change.

## Key Types

| Type | Role |
|---|---|
| `UpdateChecker` | Fetches releases, semver comparison, selects best asset |
| `AutoUpdater` | Caseless enum; static functions for download, install, relaunch |
| `RunnerState` | `@Observable @MainActor`; holds `availableUpdate`, `isInstalling`, `updateActionFailed` |
| `AutoUpdaterDefaults` | `UserDefaults` keys for persisting version + cache path |
| `AvailableRelease` | Decoded model; includes `checksumURL` for SHA-256 verification |

## Design Constraints

- **One UI location only** — update UI appears exclusively in Settings → About.
  This is a hard constraint from the spec (#1794).
- **`NSApp.terminate(nil)` not `exit(0)`** — RunBot is non-sandboxed with no
  `applicationWillTerminate` side-effects that conflict with the handoff.
  `exit(0)` is the helper-process self-update pattern and was explicitly rejected.

## Related

- [#1794](https://github.com/runbot-hq/run-bot/issues/1794) — In-app auto-update spec
- [#1795](https://github.com/runbot-hq/run-bot/issues/1795) — Code-signing verification (v2)
- [#1797](https://github.com/runbot-hq/run-bot/issues/1797) — Step-by-step implementation plan
- [docs/RELEASING.md](./RELEASING.md) — How to publish a new release
