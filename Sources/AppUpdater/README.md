# AppUpdater

A host-agnostic Swift library that drives an in-app auto-update flow
for macOS apps distributed outside the Mac App Store. Zero host-specific
dependencies — all host values (repo slug, asset name, scheduler identifier,
beta-channel preference, UI state model) are injected by the caller.

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

## Design Principles

These principles govern this library and all future changes to it. They are not negotiable.

**1. One enum owns all state.**
There is one `UpdatePhase` enum. All state is expressed as a case of that enum. There are no boolean flags, no parallel URL properties, no implicit combinations. Illegal states are unrepresentable by construction.

**2. No mid-flight recovery. Binary outcomes only.**
An update either succeeds or it doesn't. An app is either installable or it isn't. There is no partial-success path, no `open -n` failure recovery, no rehydration-on-launch. If something goes wrong mid-flow, the phase becomes `.failed`. The user relaunches or retries. We do not attempt to recover state across process boundaries.

**3. The task is exactly: check → download → verify → cache → install.**
Nothing else. This is the entire feature surface. Any requirement that adds a step outside this pipeline is out of scope.

**4. No sprawl.**
Do not add features to handle edge cases that arise from other features. If an edge case requires new state, new flags, or new recovery paths — the correct response is to remove the feature that created the edge case, not to add more code around it.

**5. Strict feature plane. Unsupported is correct.**
Not supporting every scenario is a feature, not a gap. A smaller, correct update flow is better than a large one with subtle state bugs that can leave users with a bricked app. When in doubt, do less.

**6. The library owns the flow, not the host.**
`AppUpdater` drives all phase transitions. The host only calls `apply()` — it never constructs or transitions phases itself. The seam is one-directional: library writes, host reads.

**7. No UserDefaults as state.**
UserDefaults is persistence, not state. The source of truth is the enum. The rehydration complexity deleted in this refactor came entirely from treating UserDefaults as a second state store.

## Quick start

### 1. Conform your state model to `UpdateStateProviding`

Implement two requirements: a single mutation method and a readable phase property.

```swift
@Observable @MainActor
final class MyUpdateState: UpdateStateProviding {
    private(set) var currentPhase: UpdatePhase = .idle

    func apply(_ phase: UpdatePhase) {
        currentPhase = phase
    }
}
```

All state transitions go through `apply(_:)`. The library drives every phase
change; the host only reads `currentPhase` to render UI.

### 2. Construct the updater

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
    assetName: { _ in "YourApp.zip" },               // SHA-256 sidecar expected at "<assetName>.sha256"
    schedulerIdentifier: "com.your-org.update-check" // also scopes the on-disk cache directory
    // betaChannelProvider: { false }                 // optional — defaults to stable channel
    // releaseProvider: GitHubReleaseProvider()       // optional — injectable for testing
)
// If you distribute a Developer ID-signed app, also set:
// updater.skipCodeSignValidation = false
// See the Trust model section below for details.
```

### 3. Drive it from your app delegate

```swift
await updater.checkAndHandle(state: myState)     // channel-aware check + download/cache
updater.scheduleBackgroundCheck(state: myState)   // periodic background re-check (interval: AppUpdater.checkInterval)
```

> **No `cancelBackgroundCheck()`.**
> The scheduler is fire-and-forget. It starts once at app launch and runs for the
> process lifetime. There is no supported scenario for stopping it mid-session — if
> there were, the correct fix is to not start it, not to cancel it later. If an
> external consumer genuinely needs cancellation, add it then (Principle 4).

```swift
// From the "Install & Relaunch" button:
await updater.installAndRelaunch(state: myState)
```

### 4. Render your update UI

Switch on `myState.currentPhase` to render the appropriate UI:

```swift
switch myState.currentPhase {
case .idle:
    // No update — hide the update row
case .available(let version):
    // A newer release was found; download is queued but not yet started.
    // Show a disabled Install button or "Checking…" indicator.
case .downloading(let version):
    // Download is in progress — show ProgressView("Downloading update…")
case .ready(let version, let zipURL):
    // Download complete and verified — show active Install & Relaunch button
case .failed(let version):
    // Show error label + Retry button that calls checkAndHandle again
}
```

## UX states

The update row in Settings → About has exactly four user-visible states.
The row is absent entirely when there is no update (`.idle`).

| Phase | What the user sees | User action |
|---|---|---|
| `.available` | "A new version of RunBot is ready to download." + disabled **Install & Relaunch** | None — download is already running automatically |
| `.downloading` | *(same as `.available` — not separately visible; see note below)* | None |
| `.ready` | "A new version of RunBot is ready to install." + active **Install & Relaunch** | Tap to install and relaunch |
| `.failed` | "Download failed. Check your connection and try again." + **Retry** | Tap Retry to re-run the full pipeline from scratch |

The download is automatic — it starts the moment an update is found.
The user consent gate is at **install**, not at download. This matches
the macOS and Sparkle convention: downloading is low-risk and reversible
(a cached zip); installing is destructive (replaces the running app).

> **Why `.downloading` is not separately visible:** `RunnerState.currentPhase`
> cannot reconstruct `.downloading` from stored fields — it is indistinguishable
> from `.available` in storage. This is intentional (Principle 1: no boolean
> flags). The user sees the same disabled button throughout the download, which
> is correct: the zip completes in under 3 seconds on any normal connection and
> a spinner would be noise. If download progress UI is ever needed, the right
> fix is a `downloading(version: String, progress: Double)` case on `UpdatePhase`
> — not a parallel flag on `RunnerState`.
>
> **Why there is no "Check for updates" opt-out toggle:** Scheduler start/stop
> logic would add new state and a new code path for a feature with negligible
> user demand. Principle 4: no sprawl. Principle 5: unsupported is correct.

## API reference

### `AppUpdater.init`

```swift
public init(
    repo: String,
    currentVersion: String,
    assetName: @escaping @Sendable (String) -> String,
    schedulerIdentifier: String,
    betaChannelProvider: @escaping @MainActor () -> Bool = { false },
    releaseProvider: P = GitHubReleaseProvider()
)
```

| Parameter | Description |
|---|---|
| `repo` | `"owner/repo"` slug on GitHub |
| `currentVersion` | Running version string, e.g. `"1.2.3"` or `"v1.2.3"` |
| `assetName` | Closure receiving the release tag and returning the expected zip asset filename |
| `schedulerIdentifier` | Reverse-DNS string; also scopes the on-disk cache directory (`~/Library/Caches/<schedulerIdentifier>/update.zip`) |
| `betaChannelProvider` | Called at check time to decide whether to include pre-release tags. Defaults to `{ false }` (stable channel only) |
| `releaseProvider` | Injectable release fetcher. Defaults to `GitHubReleaseProvider()`. Override in tests. |

### `AppUpdater.checkInterval`

```swift
public static var checkInterval: TimeInterval  // default: 86400 (24 hours)
```

The interval at which `scheduleBackgroundCheck` fires. Mutate before calling
`scheduleBackgroundCheck` if you need a different cadence. In DEBUG builds
you may want a shorter interval for manual testing — restore to the default
before shipping.

### Protocol shape

```swift
@MainActor
public protocol UpdateStateProviding: AnyObject, Sendable {
    /// Advance the update state to `phase`.
    func apply(_ phase: UpdatePhase)
    /// The current update phase.
    var currentPhase: UpdatePhase { get }
}

public enum UpdatePhase: Equatable {
    /// No update activity — nothing available, nothing in progress.
    case idle
    /// A newer release was found; version is the tag string (e.g. `"v1.2.0"`).
    /// Download is queued but not yet started.
    case available(version: String)
    /// A download is in progress for the given version.
    case downloading(version: String)
    /// Download complete and integrity-verified; zip is at `zipURL`.
    case ready(version: String, zipURL: URL)
    /// A download or install attempt failed.
    case failed(version: String?)
}
```

The library advances through these phases in order during a normal update:
`.idle` → `.available` → `.downloading` → `.ready`. If anything goes wrong the
phase becomes `.failed`. There is no partial-success path and no rehydration on
relaunch — if the user quits before installing, the next background check
rediscovers and re-downloads the update.

## Choosing an entry point

The library exposes two public entry-point shapes. Use `AppUpdater` for
virtually every case; `UpdateChecker` is a narrow escape hatch.

| | `AppUpdater.checkAndHandle(state:)` | `UpdateChecker.checkForUpdate(...)` |
|---|---|---|
| **What it does** | Full pipeline: check → download → cache → state mutation | Check only: returns a raw `UpdateCheckResult`; no download, no state |
| **Requires `UpdateStateProviding`** | Yes | No |
| **Works with `scheduleBackgroundCheck`** | Yes (designed for it) | No |
| **Use when** | You want the complete update flow | You need to know whether an update exists without side effects — e.g. displaying a badge without triggering a download, or in a CLI tool that manages its own install step |

If you find yourself calling `UpdateChecker.checkForUpdate` and then
manually downloading the result, switch to `AppUpdater` instead — that
pipeline is already implemented, tested, and handles the scheduler,
cache, and failure paths for you.

## Trust model

`AppUpdater` supports two distribution paths, controlled by the
`skipCodeSignValidation` flag on `AppUpdater`.

### Unsigned path — `skipCodeSignValidation = true` (default, RunBot)

Download integrity is guaranteed by the SHA-256 sidecar only:

- The release zip is downloaded and verified against the `.sha256` sidecar asset.
- No `codesign` invocation is performed on the downloaded bundle.
- The atomic bundle swap proceeds immediately after checksum verification passes.
- **Correct for apps distributed without a Developer ID signature.** RunBot is
  ad-hoc signed (no Developer ID, no notarisation), so Gatekeeper cannot validate
  a codesign identity — skipping the check is both safe and required.

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: "1.2.3",
    assetName: { _ in "YourApp.zip" },
    schedulerIdentifier: "com.your-org.update-check"
)
// skipCodeSignValidation defaults to true — no extra configuration needed
```

### Signed path — `skipCodeSignValidation = false` (external signed consumers)

For apps distributed with a Developer ID signature, enable identity verification:

1. **SHA-256 verification** runs first (always). A checksum mismatch aborts the
   install before any codesign check is attempted.
2. **`codesign -dvvv`** is run on both the running bundle (`Bundle.main`) and the
   freshly unzipped candidate bundle.
3. The `Authority=` identity strings (leaf certificate common name, e.g.
   `"Developer ID Application: Acme Corp (XXXXXXXX)"`) must match exactly.
4. A mismatch applies `.failed` via `state.apply(.failed(version:))` and aborts
   the install. No bundle swap is performed.

```swift
let updater = AppUpdater(
    repo: "your-org/your-repo",
    currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
    assetName: { _ in "YourApp.zip" },
    schedulerIdentifier: "com.your-org.update-check"
)
updater.skipCodeSignValidation = false // enable identity check for Developer ID builds
```

> **Note:** Set `skipCodeSignValidation` before calling `scheduleBackgroundCheck`
> or `checkAndHandle`. The value is read at `installAndRelaunch` time, but
> establishing it early removes any ambiguity about which value was in effect
> when a background check fired.

> **Why `codesign -dvvv` instead of the Security framework?**
> The subprocess approach avoids Hardened Runtime entitlement requirements and
> produces the same `Authority=` string that developers already see in Console.app.
> `SecCode`/`SecRequirement` would require additional entitlements and add
> framework complexity for equivalent security guarantees.

## Distribution assumptions

- The release archive carries exactly one `.app` at its root.
- Each release attaches a `<assetName>.sha256` sidecar.
- **Missing zip asset or missing checksum sidecar** (`checksumURL` is nil on the
  `AvailableRelease`, or no asset matches `assetName`) — `AppUpdater` logs a
  warning and stays `.idle`. This is a publishing/CI problem; the background
  scheduler will retry on the next interval.
- **Download or verification failure** (network error, HTTP non-200, checksum
  mismatch, empty sidecar body) → phase advances to `.failed`. The host should
  offer a Retry button that calls `checkAndHandle` again.

## Cache location

The verified zip is always written to a fixed path:

```
~/Library/Caches/<schedulerIdentifier>/update.zip
```

The path is deterministic from `schedulerIdentifier` alone — no `UserDefaults`
persistence is required. The file is deleted at the start of each new download
and on successful install.

## Logging

Messages appear in Console.app under subsystem `io.github.appupdater`, category `AppUpdater`.
`.debug` calls are elided at zero cost in release builds when no one is streaming.

## Known limitations

### 100-release ceiling

`AppUpdater` fetches releases with `per_page=100` and makes a single request —
no pagination. If your repository has published more than 100 releases, releases
beyond the first page are never evaluated. In practice the newest release is
always in the first page (GitHub returns releases newest-first by default), so
this is not a correctness problem for the common case.

It becomes a problem only if you publish hotfixes to old branches and those
releases sort after the 100th entry by semver. Recommended mitigations:
- Keep total published releases ≤ 100 by converting old releases to drafts.
- Or tag hotfixes with a version that sorts into the top 100 by semver.

Pagination support is a future enhancement if there is demand.

### `beta.N` pre-release labels only

`UpdateChecker.isNewer` supports pre-release ordering **only for `beta.N` labels**
(e.g. `v0.8.0-beta.2` > `v0.8.0-beta.1`). Any other pre-release suffix —
`rc.1`, `alpha.1`, or an arbitrary string — is parsed with a nil beta index.
When both versions share the same `major.minor.patch` and at least one has a
non-`beta.N` pre-release label, `isNewer` returns `false`.

The current publish pipeline only generates `beta.N` tags, so this is not a
problem in practice. If you add an RC channel, extend `ParsedVersion` in
`UpdateChecker.swift` to recognise the new suffix before relying on `isNewer`
for ordering.

## Alternatives

- [Sparkle](https://github.com/sparkle-project/Sparkle) — the standard choice; supports sandboxed apps, Appcast XML, delta updates, and built-in UI
- [s1ntoneli/AppUpdater](https://github.com/s1ntoneli/AppUpdater) — GitHub Releases-based like this library but with SwiftUI UI, code-sign validation, and localized changelogs
