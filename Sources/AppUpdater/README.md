# AppUpdater

A host-agnostic Swift library that drives an in-app auto-update flow
for macOS apps distributed outside the Mac App Store. Zero host-specific
dependencies — all host values (repo slug, asset name, scheduler identifier,
beta-channel preference, UI state model) are injected by the caller.

## Installation

Add the dependency to your `Package.swift`:

```swift
.package(url: "https://github.com/runbot-hq/run-bot", branch: "main"),
```

Then add the product to your target:

```swift
.product(name: "AppUpdater", package: "run-bot")
```

> **Pin to a commit for reproducible builds.** Using `branch: "main"` always
> resolves to the latest commit. For production use, pin to a specific commit SHA:
> ```swift
> .package(url: "https://github.com/runbot-hq/run-bot", revision: "<commit-sha>"),
> ```

## Caveats

- macOS 26+ only
- Non-sandboxed apps only
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
        assetName: { _ in "YourApp.zip" },
        schedulerIdentifier: "com.your-org.update-check"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { await updater.checkAndHandle(state: updateState) }
        updater.scheduleBackgroundCheck(state: updateState)
    }
}
```

Wire the install button from your settings UI:

```swift
Button("Install & Relaunch") {
    Task { await updater.installAndRelaunch(state: updateState) }
}
```

## UpdatePhase

Switch on `currentPhase` to render your update UI:

```swift
switch state.currentPhase {
case .idle:                    // no update — hide the update row
case .available(let version):  // update found, download starting automatically
case .downloading(let version):// download in progress
case .ready(let version):      // verified and cached — show Install & Relaunch button
case .failed(let version):     // show error + Retry button calling checkAndHandle again
}
```

## Trust model

**Unsigned (default)** — integrity via SHA-256 sidecar only. Correct for ad-hoc signed or unsigned apps.

```swift
// skipCodeSignValidation defaults to true — no extra configuration needed
```

**Developer ID signed** — enable bundle identity verification:

```swift
updater.skipCodeSignValidation = false
```

When enabled, `codesign -dvvv` is run on both the running bundle and the downloaded bundle. The `Authority=` identity strings must match exactly or the install is aborted with `.failed`.

> Set `skipCodeSignValidation` before calling `checkAndHandle` or `scheduleBackgroundCheck`.

## Known limitations

**100-release ceiling** — a single `per_page=100` request is made. Releases beyond the first page are never evaluated. In practice the newest release is always in the first page (GitHub returns newest-first). Pagination is a future enhancement.

**`beta.N` labels only** — pre-release ordering is supported only for `beta.N` suffixes. Any other suffix (`rc.1`, `alpha.1`) is treated as unordered and `isNewer` returns `false` when comparing against it.

## Design principles

See [PRINCIPLES.md](PRINCIPLES.md).

## Alternatives

- [Sparkle](https://github.com/sparkle-project/Sparkle) — the standard choice; supports sandboxed apps, Appcast XML, delta updates, and built-in UI
- [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater) — GitHub Releases-based like this library but with SwiftUI UI, code-sign validation, and localized changelogs
