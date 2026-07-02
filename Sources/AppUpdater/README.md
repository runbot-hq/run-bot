# AppUpdater

A Swift library that drives an in-app auto-update flow for macOS apps
distributed via GitHub Releases outside the Mac App Store.

## Installation

Add the dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/runbot-hq/run-bot", branch: "main"),
```

Then add the product to your target:

```swift
.product(name: "AppUpdater", package: "run-bot")
```

> **Pin to a commit for reproducible builds.** For production use, pin to a specific commit SHA:
> ```swift
> .package(url: "https://github.com/runbot-hq/run-bot", revision: "<commit-sha>"),
> ```

## Caveats

- macOS 26+ only
- Sandboxed apps are not supported
- GitHub Releases as the distribution source (no other providers)
- No built-in UI — the host owns all update state and surfaces it however it likes

## Flow

```
GitHub Releases poll → semver compare (incl. beta.N) → zip download
    → SHA-256 sidecar verification → cache → host state mutation
    → install & relaunch on user confirmation
```

## Minimal host app

```swift
import AppKit
import AppUpdater

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    @Observable
    final class UpdateState: UpdateStateProviding {
        private(set) var currentPhase: UpdatePhase = .idle
        func apply(_ phase: UpdatePhase) { currentPhase = phase }
    }

    let updateState = UpdateState()
    let updater = AppUpdater(
        repo: "your-org/your-repo",
        currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
        assetName: { _ in "YourApp.zip" },               // SHA-256 sidecar expected at "YourApp.zip.sha256"
        schedulerIdentifier: "com.your-org.update-check" // also scopes the on-disk cache directory
        // betaChannelProvider: { false }                 // optional — defaults to stable channel only
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await updater.checkAndHandle(state: updateState) }
        updater.scheduleBackgroundCheck(state: updateState)
    }
}

struct UpdateRow: View {
    let state: AppDelegate.UpdateState
    let updater: AppUpdater

    var body: some View {
        switch state.currentPhase {
        case .idle:
            EmptyView()
        case .available(let version):
            Text("Update \(version) found, downloading…")
        case .downloading(let version):
            Text("Downloading \(version)…")
        case .ready(let version):
            VStack {
                Text("\(version) ready to install")
                Button("Install & Relaunch") {
                    Task { await updater.installAndRelaunch(state: state) }
                }
            }
        case .failed:
            Button("Retry") {
                Task { await updater.checkAndHandle(state: state) }
            }
        }
    }
}
```

## Cache

The verified zip is written to:

```
~/Library/Caches/<schedulerIdentifier>/update.zip
```

The path is deterministic from `schedulerIdentifier` alone. The file is deleted at the start of each new download and on successful install.

## Background check interval

```swift
AppUpdater.checkInterval  // default: 86400 (24 hours)
```

Mutate before calling `scheduleBackgroundCheck` if you need a different cadence.

> **Test isolation:** Always restore the original value in a `tearDown` block when mutating `checkInterval` in a test — Swift Testing runs cases concurrently by default and a stale override will cause flaky failures.

## Distribution assumptions

The SHA-256 sidecar must be named exactly `<assetName>.sha256` — i.e. if `assetName` returns `"YourApp.zip"`, the expected sidecar is `"YourApp.zip.sha256"`. A file named `"YourApp.sha256"` or `"YourApp.zip.sha256sum"` will not be found and the download will be skipped.

## Trust model

**Unsigned (default)** — integrity via SHA-256 sidecar only. Correct for ad-hoc signed or unsigned apps. No extra configuration needed.

**Developer ID signed** — enable bundle identity verification:

```swift
updater.skipCodeSignValidation = false
```

When enabled, `codesign -dvvv` is run on both the running bundle and the downloaded bundle. The `Authority=` identity strings must match exactly or the install is aborted with `.failed`.

## Known limitations

**`beta.N` labels only** — pre-release ordering is supported only for `beta.N` suffixes (e.g. `v1.0.0-beta.2`). Any other suffix (`rc.1`, `alpha.1`) is treated as unordered and `isNewer` returns `false` when comparing against it.

## Design principles

See [PRINCIPLES.md](PRINCIPLES.md).

## Alternatives

- [Sparkle](https://github.com/sparkle-project/Sparkle) — the standard choice; supports sandboxed apps, Appcast XML, delta updates, and built-in UI
- [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater) — GitHub Releases-based like this library but with SwiftUI UI, code-sign validation, and localized changelogs
