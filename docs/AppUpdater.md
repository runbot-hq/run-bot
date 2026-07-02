# AppUpdater

A standalone, host-agnostic Swift package target that drives an in-app
auto-update flow for macOS apps distributed outside the Mac App Store.

`AppUpdater` has **zero dependency on RunBotCore** (or any host code). All
host-specific values — the GitHub repo slug, the zip asset name, the scheduler
identifier, the beta-channel preference, and the UI state model — are injected by
the caller. The library reads no `Bundle`, holds no singletons, and ships no
resources.

## Flow

```
GitHub Releases poll → semver compare (incl. beta.N) → zip download
   → SHA-256 sidecar verification → cache → host state mutation
   → install & relaunch on user confirmation
```

## Concurrency model

`AppUpdater` is a `@MainActor final class`, so its flags (`isInstalling`,
`isDownloading`) and the retained `NSBackgroundActivityScheduler` are race-free
without extra locking. Blocking work is kept off the main thread regardless:

- `URLSession` downloads suspend rather than block.
- Checksum verification runs in the `@concurrent` `verifyChecksum` free function.
- Subprocess launches (`ditto`, `open`) run in the `@concurrent` `runCommand`
  helper (no `DispatchQueue` / `withCheckedContinuation`).

The background download is spawned with a plain `Task { }` that inherits
`@MainActor`, so the host state existential is captured in-actor and needs no
`Sendable` conformance across an actor boundary.

`NSBackgroundActivityScheduler` and other AppKit usage are guarded by
`#if canImport(AppKit)` so the target still compiles where AppKit is absent.

## Host integration

### 1. Conform your UI state model to `UpdateStateProviding`

The protocol is entirely `@MainActor`. Properties are read-only `{ get }`; all
mutations go through named methods so no caller can set `updateZipURL` without
also setting the paired version (the write is encapsulated in
`setDownloadComplete`). `isDownloading` is intentionally **not** part of the
protocol — whether a spinner shows is a host UI detail.

```swift
extension MyUpdateState: UpdateStateProviding {}
```

### 2. Construct the updater with host-specific configuration

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: Bundle.main.rbVersionString,
    assetName: { _ in "YourApp.zip" },              // sidecar expected at "<assetName>.sha256"
    schedulerIdentifier: "com.your-org.update-check", // also scopes UserDefaults keys
    betaChannelProvider: { MyPrefs.shared.betaChannel }
)
```

### 3. Drive it from your app delegate

```swift
updater.rehydrateCachedUpdateIfNewer(state: myState) // offline-ready, before any network
await updater.checkAndHandle(state: myState)          // channel-aware check + download/cache
updater.scheduleBackgroundCheck(state: myState)       // daily background re-check
// From the "Install & Relaunch" button:
await updater.installAndRelaunch(state: myState)
```

## Persisted state

Two `UserDefaults` keys, scoped by `schedulerIdentifier` via
`AppUpdaterDefaults(domain:)`, survive a relaunch so a downloaded-but-not-yet-
installed update is offered again on next launch:

- `<domain>.cachedUpdateZipPath`
- `<domain>.cachedUpdateVersion`

The verified zip is cached at
`~/Library/Caches/<schedulerIdentifier>/update-<version>.zip`.

## Distribution assumptions

- The release archive carries exactly one `.app` bundle at its root. The install
  path locates the first `*.app` (non-recursive) and swaps the running bundle via
  `FileManager.replaceItem` (atomic).
- Each release attaches a `<assetName>.sha256` sidecar. A missing sidecar is a
  hard failure — the download is aborted and the host failure state is set.
- On any download/install failure the host's failure flag is set so the app can
  surface a browser-download fallback. This is a designed recovery path, not a
  silent failure.

## Logging

Messages appear in Console.app under subsystem `io.github.appupdater`, category
`AppUpdater`. `.debug` calls are elided at zero cost in release builds when no
one is streaming.
