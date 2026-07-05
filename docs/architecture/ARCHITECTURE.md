# RunBot — UI Architecture Decisions

Regression guards and architectural decisions enforced inline in the source.
**Do not remove** the corresponding inline annotations without updating this file.

For deep-dives on specific subsystems see:
- [../ui/nspopover-decisions.md](../ui/nspopover-decisions.md) — why NSPopover, side-jump prevention, sheet/file-picker dismiss
- [Swift concurrency lexicon](https://gist.github.com/eonist/cd034f2318a70ca03ee69635a2fc2583) — replacement for the deleted `swift-concurrency-lexicon.md`

---

## `panelVisibilityState` and `wrapEnv()`

> Regression guard ref: issue #377  
> See also: `AppDelegate.swift`, `PanelMainView.swift`

`panelVisibilityState: PanelVisibilityState` is an `ObservableObject` that
mirrors `panelIsOpen`. It is injected into every SwiftUI view hierarchy via
`wrapEnv()` so views can react to open/close without a direct reference to
`AppDelegate`.

- ❌ NEVER remove `panelVisibilityState`.
- ❌ NEVER remove `.environmentObject(panelVisibilityState)` from `wrapEnv()`.
- ❌ NEVER pass panel open state as a plain `Bool` prop to `PanelMainView`.

---

## `@MainActor` isolation on `AppDelegate`

> Regression guard ref: Swift 6 concurrency migration  
> See also: `AppDelegate.swift`, `AppDelegate+Navigation.swift`

`AppDelegate` is annotated `@MainActor`. This gives the Swift 6 compiler static
proof that all methods and stored properties are main-thread-only, eliminating
the need for runtime `DispatchQueue.main` assertions throughout.

The `nonisolated` blocking helper `enrichStepsIfNeeded` in
`AppDelegate+Navigation.swift` is intentionally exempt — it performs blocking
network I/O and is always dispatched onto `DispatchQueue.global()`.

- ❌ NEVER remove `@MainActor` from the `AppDelegate` class declaration.
- ❌ NEVER remove `nonisolated` from `enrichStepsIfNeeded`.

---

## Nav-state persistence across panel close/open

> Regression guard ref: issue #385  
> See also: `AppDelegate.swift` `closePanel()`

`savedNavState` is preserved across close so `openPanel()`'s `validatedView`
path navigates back to the same view on re-open. On close, `rootView` is always
reset to `mainView()` (so the SwiftUI tree is fresh), but `savedNavState` is
kept — `openPanel()` reads it and calls `navigate(to: validatedView(for: saved))`.

- ❌ NEVER clear `savedNavState` inside `closePanel()` or `hidePanel()`.
- ❌ NEVER try to preserve sheet `@State` across an explicit close (`closePanel()`) — see [nspopover-decisions.md](../ui/nspopover-decisions.md).
- Sheet `@State` IS preserved across `hidePanel()` (outside-tap / workspace-switch) via `hidePopoverWindowsPreservingSheets()` — this is intentional.

---

## OAuth URL handling

> Ref: issue #597  
> See also: `AppDelegate.swift` `application(_:open:)`

The `application(_:open:)` delegate searches the **full** `urls` array for the
`runbot://oauth/callback` URL rather than assuming `urls.first`. macOS may
deliver multiple URLs and the OAuth callback may not be first, which would leave
the sign-in spinner stuck indefinitely.

---

## `KeyablePanel` access level

> See also: `KeyablePanel.swift`, `AppDelegate.swift`

`KeyablePanel` must be `internal` (not `private` or `fileprivate`).
`AppDelegate+Navigation.swift` accesses `panel: KeyablePanel?` from a separate
file, and Swift `private` does not cross file boundaries.

---

## Dark Mode & Light Mode Support

Appearance adaptation is handled at three distinct layers. There is no user-facing toggle — the app defers entirely to the system setting.

### 1. `PanelChromeView` — Explicit AppKit check (`PanelChrome.swift`)

The custom `NSView` subclass uses `effectiveAppearance` to manually detect the active color scheme:

```swift
let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
let fill: NSColor = isDark
    ? NSColor(white: 0.18, alpha: 0.01)
    : NSColor(white: 0.95, alpha: 0.01)
```

### 2. `NSVisualEffectView` — Automatic material adaptation (`PanelChrome.swift`)

```swift
view.material = .popover
view.blendingMode = .behindWindow
view.state = .active
```

The `.popover` material resolves automatically to a light frosted-glass blur in Light Mode and a dark tinted blur in Dark Mode. **Do not change the material** — switching away from `.popover` is explicitly prohibited in inline code comments to prevent visual regressions.

### 3. SwiftUI views — Semantic colors (all view files)

All SwiftUI views exclusively use semantic system colors (`.primary`, `.secondary`, `.green`, `.red`, `.yellow`, `Color.secondary.opacity(0.12)`) that SwiftUI resolves at render time. There is **no hardcoded `NSColor` or `Color(hex:)`** in the UI layer.

| Layer | File | Mechanism |
|---|---|---|
| `PanelChromeView` (AppKit) | `PanelChrome.swift` | `effectiveAppearance.bestMatch` |
| `NSVisualEffectView` material | `PanelChrome.swift` | `.popover` + `.behindWindow` |
| SwiftUI views | All view files | Semantic colors |

- ❌ NEVER hardcode `NSColor` or `Color(hex:)` in the UI layer.
- ❌ NEVER change `view.material` away from `.popover` in `PanelChrome.swift`.


---

## RunBotCore Library Rationale

Great question. Here's the full picture for your specific setup.

## The Core Rationale

`RunBotCore` is a plain Swift package library target — no app bundle, no AppKit, no entitlements. Moving code there means that code is **completely decoupled from the macOS app runtime**. In a pure SPM codebase without `.xcodeproj`, this boundary is enforced by the compiler itself: if you accidentally import `AppKit` in a Core file, the build fails. The separation isn't just architectural — it's structural and verified on every build.

***

## Pros

**Testability is the biggest win.** Code in `RunBotCore` can be tested with `swift test` — no simulator, no app bundle, no entitlements, no Keychain access prompts. Your CI job becomes `swift build && swift test` and runs in seconds on a plain Linux or macOS runner with zero UI setup. App-layer code (`RunBot`) requires a full `xcodebuild` invocation with a derived data path, scheme, destination, and often a booted simulator or `-allowProvisioningUpdates`. The testing surface is fundamentally different.

**CI speed and reliability.** `swift test` on a library target is fast and deterministic. No simulator spin-up, no signing, no provisioning. If your GitHub Actions workflow currently runs `xcodebuild test` for everything, splitting testable logic into Core means you can run a fast `swift test` job in parallel (or before) the full app build, and fail early on pure logic errors without waiting for the full build chain.

**Parallel compilation.** SPM builds targets in parallel. The more code lives in `RunBotCore`, the more of your codebase compiles independently of the app layer. In practice this means incrementally faster `swift build` times in CI because Core and the app target compile on separate threads.

**Reusability across targets.** If you ever add a second target — a CLI tool, a helper app, an XCTest host, a Swift macro target — they can all import `RunBotCore` without pulling in any AppKit dependency graph. Right now `WorkflowActionsUseCase` only imports `RunBotCore` but lives in the app target, meaning any future tool that needs it must also link the full app.

**Dependency discipline.** The compiler enforces the boundary. You can't accidentally call `NSWorkspace` or read `UserDefaults.standard` in a way that bypasses your injected store because the type isn't available. This prevents an entire class of subtle bugs where app-layer singletons leak into business logic.

**SonarCloud / static analysis scope.** Tools like SonarCloud and Periphery can be scoped to `RunBotCore` alone for a fast, high-signal pass. Dead code in a library target is much easier to identify than in an app target where `@objc` and AppKit reflection can make things appear used.

***

## Cons

**`@MainActor` and `Observation` friction.** `@Observable` types work fine in a library target, but if you move something like `ScopeStore` or `AppPreferencesStore` to Core, you need to be careful that `@MainActor` isolation is declared explicitly rather than inherited from the app's implicit main-actor context. This is usually a one-line fix but it can surface Swift 6 concurrency warnings you hadn't seen before.

**`AppPreferencesStoreProtocol` split.** `RunnerStore.swift` currently defines `AppPreferencesStoreProtocol` and its conformance `extension AppPreferencesStore: AppPreferencesStoreProtocol {}` in the app layer. Moving `AppPreferencesStore` to Core means that conformance extension either moves to Core too (clean) or stays split across targets (messy). You need to decide the protocol's home before moving anything that depends on it.

**`RunnerStore` base type prerequisite.** As flagged in the issue — the three `RunnerStore+` extensions can't move until `RunnerStore` itself has a presence in Core. Right now `RunnerStore.swift` in the app layer takes `RunnerViewModel` (an app-layer type) as a dependency, which is the blocker. Resolving this likely means either introducing a `RunnerStoreProtocol` in Core, or refactoring `RunnerStore` to not hold a direct `RunnerViewModel` reference (push updates via `AsyncStream` instead). That's a real refactor, not just a file move.

**Module boundary boilerplate.** Types that were `internal` in the app become `public` when moved to Core. Every struct, actor, protocol, and initializer that crosses the boundary needs explicit `public` access control. In a large move this is mechanical but noisy — lots of diff noise in PRs.

**No practical benefit for truly app-specific code.** Moving `LoginItem` or `TerminalLauncher` to Core would be wrong — they need the app bundle or `ServiceManagement`. The value is only in genuinely framework-agnostic logic. Note: `OAuthService` has now been successfully moved to Core by extracting the `NSWorkspace.shared.open(url)` side-effect back to the app layer — demonstrating that the AppKit dependency was in the call site, not in the OAuth state machine itself.

***

## The Net Position for Your Setup

In a pure SPM / no-`.xcodeproj` codebase with GitHub Actions CI, the payoff is **high and concrete**: faster CI via `swift test`, enforced architectural boundaries, and a clean path to testing business logic without the full app build. The main cost is upfront refactoring — particularly the `RunnerStore`/`RunnerViewModel` coupling — but the files that don't have that coupling (the 13 straightforward candidates in the issue) are essentially free wins.

---

## GitHubClient Package (`runbot-hq/GitHubClient`)

`GitHubClient` is a first-party Swift package that owns all GitHub API communication, OAuth, and token management. It lives outside `RunBotCore` because it is a reusable, independently versioned module — not because it has app-layer dependencies.

**What it provides:**

- `GitHubClient` — the top-level facade that wires `OAuthService`, `GitHubTransport`, and `TokenCache` under a single initialiser. The production init takes Keychain credentials; the test init accepts protocol mocks, avoiding any Keychain or network access in tests.
- `GitHubTransport` / `GitHubTransportProtocol` — authenticated `URLSession`-backed transport for all GitHub REST calls. Token reads go through `TokenCache` so the Keychain is never hit on every request.
- `OAuthService` / `OAuthServiceProtocol` — manages the OAuth sign-in/sign-out flow and persists tokens to `KeychainTokenStore`. Calls `TokenCache.invalidate()` on every token change so the cache stays consistent.
- `GitHubRunnerAPI`, `GitHubWorkflowAPI` — typed API wrappers for the runner and workflow endpoints, built on top of `GitHubTransport`.
- `AnyJSON` — the type-erased JSON codec (see principle 19 in `project-tech-principles.md`).
- `RateLimitActor` / `GitHubRateLimitHandler` — serialises all rate-limit state behind an actor so concurrent API calls never race on limit tracking.

**Why a separate package, not part of `RunBotCore`?**

`GitHubClient` has no dependency on the `RunBot` app target — it is pure Swift with no AppKit imports. It is extracted as a package so it can be versioned, tested, and potentially reused independently of RunBot. `RunBotCore` declares it as a dependency and consumes it via protocol abstractions (`GitHubTransportProtocol`, `OAuthServiceProtocol`), keeping the core testable without the full Keychain/network stack.

**Isolation note:** `GitHubClient` is not annotated `@MainActor` at the type level. The production init is `@MainActor` (because `OAuthService.init` requires it), but the type itself is not isolated — a full type-level annotation is deferred until all remaining Keychain/`RunBotCore` call sites are migrated (#1914).

---

## AppUpdater Package (`runbot-hq/AppUpdater`)

`AppUpdater` is a first-party Swift package that drives the in-app auto-update flow end to end. It is consumed by `RunBotCore` and consumed transitively by the `RunBot` executable.

**What it provides:**

- `AppUpdater` — a `@MainActor` class that orchestrates the full update pipeline: GitHub Releases poll → semver compare → zip download → SHA-256 verification → install and relaunch on user confirmation. The caller injects an `any UpdateStateProviding` for all UI-facing state; `AppUpdater` itself owns no host-specific state beyond a fixed zip cache path under `~/Library/Caches/<schedulerIdentifier>/update.zip`.
- Background scheduler (`AppUpdater+BackgroundScheduler`) — periodic background polling via a `BGTaskScheduler`-style scheduler. The identifier is injected at init time so it can be overridden in tests.
- Download + verification (`AppUpdater+Download`) — `URLSession`-based zip download with SHA-256 checksum verification running in a `@concurrent` free function so it never blocks the main actor.
- Install + relaunch (`AppUpdater+Install`) — replaces the running `.app` bundle and relaunches via a subprocess, also in a `@concurrent` helper.

**Isolation model:** The class is `@MainActor`, so `isInstalling` and the scheduler reference are race-free without extra locking. All blocking work (download, checksum, subprocess) runs off the main thread via `URLSession` suspension or `@concurrent` free functions.

**Fixed zip path invariant:** All update cycles write to the same fixed path (`~/Library/Caches/<schedulerIdentifier>/update.zip`). `fixedZipURL` is a computed property (not `lazy let`) so that a transient `cachesDirectory` failure self-heals on the next scheduler cycle rather than permanently baking in a `/tmp` fallback. Any call site that needs this URL for more than one step must snapshot it once into a local `let`.

---

## Data Model

This document describes the runtime data model of RunBot: how the GitHub poll loop
fetches and enriches state, how that state reaches SwiftUI, and how local (on-disk)
runners are reconciled with GitHub-hosted runners.

> **Note on naming history.** What this document previously called `RunnerStore` was
> renamed to **`RunnerPoller`** and moved into the `RunBotCore` target ("Step 10").
> The old `RunnerViewModel` push-coupling has been replaced by an injected
> **`RunnerState`** observable read model ("Step 14"). The sections below reflect the
> current code.

---

## `RunnerPoller` — what it does today

`RunnerPoller` is a Swift 6 `actor` in `RunBotCore` that owns the GitHub poll loop
and all derived runner/job/action state. It runs on its own (background) executor and
has **no import of the `RunBot` app target** — all app-layer dependencies are injected
as protocol-typed values or closures.

**1. Polls GitHub on a timer**
A structured `Task` loop fetches immediately, sleeps `nextPollInterval()` seconds, then
repeats until cancelled. The interval is **10s when jobs are actively running**, otherwise
the user's configured idle interval (`preferencesStore.pollingInterval`, floored at 10s).
While rate-limited it also falls back to the idle interval.

**2. Fetches and enriches runners**
For each active scope (org or repo slug) it fetches the GitHub runner list across two
concurrent `withTaskGroup` phases (the `IndexedScopedRunner` carrier keeps a fetched
`Runner` paired with its source scope). For busy runners it resolves the local install
path via an `InstallPathMap` and reads live CPU/memory metrics from the machine.

**3. Maintains job and action-group state**
It tracks live jobs, a capped completed-job cache, live workflow action groups, and a
group cache — comparing each poll result against the previous snapshot to detect
vanished jobs/groups and fire failure hooks.

**4. Handles rate limiting**
It keeps an actor-local `isRateLimited` / `rateLimitResetDate` copy (read by
`nextPollInterval()`) and mirrors it into `RunnerState`. On a failed cycle it still syncs
these so a rate-limited failure doesn't leave stale interval behaviour.

**5. Pushes results to `RunnerState` on the main actor**
After every cycle, `applyFetchResult` does `await MainActor.run { state.runners = …;
state.jobs = …; state.actions = … }`. SwiftUI's `@Observable` machinery picks up the
mutation automatically — **no Combine `PassthroughSubject` and no `RunnerViewModel`
coupling**. Status-icon refresh is no longer triggered from inside the actor; `AppDelegate`
wires an `ObservationLoop` on `state.runners` instead.

### `PollLoopCoordinator`

`RunnerPoller` owns a `PollLoopCoordinator` (`private let pollLoop`) that holds the three
`Task` handles driving the loop: the poll task, the interval-observation task, and the
scope-observation task. Because it's a stored property of the actor, all access is
serialised by the actor's executor. It carries a documented `@unchecked Sendable`
sign-off (a deliberate Principle #4 exception) so `deinit` can cancel the handles.

### `RunnerPollerProtocol` and `MockPoller`

`AppDelegate` types the poller as `any RunnerPollerProtocol` (`func start() async` +
`var state: RunnerState { get }`). `RunnerPoller` is the production conformer; `MockPoller`
is a no-op actor for SwiftUI previews and snapshot tests — `start()` is a guaranteed no-op
that never touches the network.

---

## `RunnerState` — the observable read model

`RunnerState` is an `@Observable @MainActor public final class` populated by `RunnerPoller`
and consumed read-only by views and `AppDelegate` (via `withObservationTracking` /
`ObservationLoop`). It replaces the old `RunnerViewModel` push target.

Poll-written properties are `public internal(set)` — only `RunnerPoller.applyFetchResult`
(same module) mutates them:

- `runners: [Runner]` — enriched GitHub runner snapshots
- `jobs: [ActiveJob]` — live + recently-completed jobs
- `actions: [WorkflowActionGroup]` — workflow run groups
- `isRateLimited: Bool`
- `rateLimitResetDate: Date?`
- `fetchError: (any Error)?`

Two properties are `public var` (only `LocalRunnerStore` writes them in practice; the
`public` setter is required to satisfy the `RunnerViewModelProtocol` `{ get set }`
requirement):

- `localRunners: [RunnerModel]`
- `isLocalScanning: Bool`

It also exposes a derived `aggregateStatus: AggregateStatus` computed property.

---

## `RunnerModel` — local (on-disk) runner

`RunnerModel` is a **local self-hosted runner** discovered by scanning LaunchAgent plists
in `~/Library/LaunchAgents`, managed by the `LocalRunnerStore` actor. After discovery,
`RunnerStatusEnricher` enriches each model with live GitHub API data (`githubStatus`,
`isBusy`, `labels`, `runnerGroup`).

It is **fully `Sendable`**: all properties are `let`, and mutations go through a
`copying(…)` method that returns a new value — no in-place mutation, so the compiler
synthesises `Sendable` without an `@unchecked` escape hatch. Key fields:

- Identity / location: `id`, `runnerName`, `installPath`, `gitHubUrl`, `agentId`, `apiId`, `workFolder`
- Config: `labels`, `platform`, `platformArchitecture`, `agentVersion`, `isEphemeral`, `runnerGroup`
- Live state: `isRunning` (from `launchctl`), `githubStatus`, `isBusy`, `lifecycleWarning`, `metrics`
- Derived: `displayStatus`, `statusColor`

`RunnerModel` is the local ground truth used to build the `InstallPathMap` that resolves
which local machine runner corresponds to which GitHub API runner.

---

## `Runner` — GitHub API runner snapshot

`Runner` is the API-decoded remote snapshot (API-first, vs. `RunnerModel` which is
local-first): `id: Int`, `name`, `status: RunnerStatus`, `busy: Bool`, optional
`metrics: RunnerMetrics`, plus a derived `displayStatus`. `RunnerPoller` enriches busy
`Runner`s with metrics read from the corresponding local runner.

---

## How they relate

```
LocalRunnerStore (actor, Core)
  └─ [RunnerModel]              ← "what's installed on this Mac" (LaunchAgent scan)
        │  installPathMap
        ▼
RunnerPoller (actor, Core)
  ├─ fetchAndEnrichRunners()    ← GitHub API → [Runner]  (two withTaskGroup phases)
  ├─ enriches busy runners      ← reads CPU/MEM metrics from disk
  ├─ tracks jobs + action groups, fires failure hooks on vanished items
  ├─ handles rate limiting      ← actor-local copy + mirrored to state
  └─ applyFetchResult()         ← await MainActor.run { state.runners/jobs/actions = … }
        │
        ▼
RunnerState (@Observable @MainActor, Core)   ← read-only model
        │
        ▼
SwiftUI views + AppDelegate (ObservationLoop on state.runners)
```

`RunnerModel` is the local ground truth; `Runner` is the GitHub API model.
`RunnerPoller` reconciles the two every poll tick and writes the merged result into
`RunnerState`, which SwiftUI observes directly — no push coupling, no app-target import
from Core.

---

## Concurrency Model

## Concurrency Architecture Overview

The concurrency model is explicit and compiler-enforced end-to-end. All UI state lives on `@MainActor`, all background domain work is isolated in dedicated actors, and there are no `@unchecked Sendable` escape hatches in production types. The system maps to **six core concurrency pillars** across 21 documented principles.

***

## Pillar 1: Actor-Per-Concern Isolation (P1, P16)

Each mutable domain owns its own actor — there is no single "background actor" everything piles into. The canonical examples are:

- **`RateLimitActor`** — serialises all rate-limit state and exposes a `snapshot()` method for atomic reads (P10)
- **`RunnerConfigStore`** — its own actor, serialising all disk I/O for `.runner` config files
- **`LocalRunnerStore`** — pushes snapshots to `viewModel.localRunners` on `MainActor` using `await MainActor.run` (not fire-and-forget `Task`) to guarantee mutation ordering

## Pillar 2: MainActor Boundary Crossings (P2)

Views and ViewModels are `@MainActor`-isolated. The boundary-crossing pattern used throughout is:

```swift
let scopes = await MainActor.run { scopeStore.activeScopes }
```

This is used in `RunnerPoller.start()` and `RunnerPoller+PollBridge` to safely read `@MainActor`-isolated properties from a background context. `Task { @MainActor in ... }` is used for fire-and-forget operations from SwiftUI views (e.g. `SettingsView`, `ScopesView`, `StepLogView`).

## Pillar 3: Structured Concurrency for Timers & Loops (P9)

All timers use `Task` + `Task.sleep(for:)` rather than `DispatchQueue.asyncAfter`. A **generation counter** guards against stale-task races where a sleeping task wakes after a newer window has started. `PanelContainerView` uses a named poll task:

```swift
pollTask = Task(name: "sheetPoll") { @MainActor in
    while !Task.isCancelled {
        try await Task.sleep(for: .milliseconds(100))
    }
}
```

Task names leverage Swift 6.2's `Task(name:)` API (SE-0462) for Instruments/crash log debuggability.

## Pillar 4: Atomic Snapshot Pattern (P10)

Related values are never fetched with two separate `await` calls across an actor boundary. The `RateLimitActor.snapshot()` method returns `isLimited` and `resetDate` atomically in one hop — the canonical TOCTOU-eliminating pattern in the codebase. Parallel fetches use `async let` binding:

```swift
async let fetchedOrgs = fetchUserOrgs()
async let fetchedRepos = fetchUserRepos()
let (resolvedOrgs, resolvedRepos) = await (fetchedOrgs, fetchedRepos)
```

This is visible in `AddScopeSheet.swift`.

## Pillar 5: `@concurrent` for Blocking I/O (P18)

Synchronous disk I/O is placed in `@concurrent` async free functions, keeping blocking calls off actor serial executors. `LogFetcher` is a `Sendable` struct whose entry points are `async` but not `@concurrent` — they are called from `Task.detached` contexts (not actor-isolated paths). `ProcessRunner` retains the legacy `withCheckedContinuation` + `DispatchQueue` bridge because it requires a deliberate `DispatchQueue.sync` barrier as a join point; this pattern is not to be introduced in new code.

## Pillar 6: Sendable Use-Cases & Non-Isolated Structs (P8, P17)

Business logic lives in `Sendable` use-case structs (e.g. `WorkflowActionsUseCase`, `FailureHookRunnerUseCase`) with no isolation annotation. Because they are non-actor `Sendable` structs, all methods run on the cooperative thread pool when called with `await` from inside a `Task {}` (P18). `JSONDecoder` instances are `nonisolated` on actors where captured inside closures, expressing that they have no mutable state post-init — not as a workaround, but as a precise compiler-checked immutability guarantee (P17).

***

## Concurrency Ownership Map

| Component | Isolation | Pattern |
|---|---|---|
| `RunnerPoller` / `RunnerPoller+PollBridge` | nonisolated / background Task | `withTaskGroup`, `await MainActor.run` |
| `LocalRunnerStore` | background actor | `await MainActor.run` for UI pushes (ordered) |
| `RunnerConfigStore` | actor | `@concurrent` disk I/O helpers |
| `RateLimitActor` | actor | `snapshot()` atomic reads (P10) |
| `GitHubRateLimitHandler` | actor | generation counter for stale-task guard |
| `FailureHookRunnerUseCase` | Sendable struct | inline `async`, no `Task.detached` |
| `LogFetcher` | Sendable struct | `async` entry points, `Task.detached` callers |
| All SwiftUI Views | `@MainActor` | Plain `Task {}` inherits isolation |
| `ProcessRunner` | nonisolated | Legacy `withCheckedContinuation` + `DispatchQueue` (deliberate) |

The principles document (P4) confirms this is a **build-time guarantee** — no `@unchecked Sendable` in production, every actor crossing visible at the call site.
