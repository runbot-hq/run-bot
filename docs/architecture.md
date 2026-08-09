## Contents

- [panelVisibilityState and wrapEnv()](#panelvisibilitystate-and-wrapenv)
- [@MainActor isolation on AppDelegate](#mainactor-isolation-on-appdelegate)
- [Nav-state persistence across panel close/open](#nav-state-persistence-across-panel-closeopen)
- [OAuth URL handling](#oauth-url-handling)
- [KeyablePanel access level](#keyablepanel-access-level)
- [Dark Mode & Light Mode Support](#dark-mode--light-mode-support)
- [RunBotCore Library Rationale](#runbotcore-library-rationale)
- [Log Directive Parsing — Reference Spec](#log-directive-parsing--reference-spec)
- [GitHubClient Package](#githubclient-package-runbot-hqgithubclient)
- [AppUpdater Package](#appupdater-package-runbot-hqappupdater)
- [Data Model](#data-model)
- [Concurrency Model](#concurrency-model)
- [NSPopover Decisions](#nspopover-decisions)
- [Design](#design)
 
# RunBot — UI Architecture Decisions

Regression guards and architectural decisions enforced inline in the source.
**Do not remove** the corresponding inline annotations without updating this file.

For deep-dives on specific subsystems see:
- [#nspopover-decisions](#nspopover-decisions) — why NSPopover, side-jump prevention, sheet/file-picker dismiss
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
- ❌ NEVER try to preserve sheet `@State` across an explicit close (`closePanel()`) — see [NSPopover Decisions](#nspopover-decisions).
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

## Log Directive Parsing — Reference Spec

`LogLineParser.swift` (`RunBotCore`) parses raw GitHub Actions step log text directly.
This is distinct from how `gh` CLI works — `gh` fetches annotations from the REST API
(`/check-runs/:id/annotations`) and never touches `::` wire-format strings.
The reference sources for the wire format are:

| File | Repo | What it contains |
|---|---|---|
| [command.ts](https://github.com/actions/toolkit/blob/main/packages/core/src/command.ts) | actions/toolkit | Canonical `::name key=val,key=val::message` wire format encoder; `escapeProperty` percent-encodes `,`→`%2C`, `:`→`%3A`, `\n`→`%0A`; `escapeData` encodes message; `issueCommand` is the emitter for all directives |
| [utils.ts](https://github.com/actions/toolkit/blob/main/packages/core/src/utils.ts) | actions/toolkit | `toCommandProperties` maps `AnnotationProperties` to wire keys: `startLine`→`line`, `startColumn`→`col`, `endLine`→`endLine`, `endColumn`→`endColumn` |
| [core.ts](https://github.com/actions/toolkit/blob/main/packages/core/src/core.ts) | actions/toolkit | Public `AnnotationProperties` interface: `title`, `file`, `startLine`, `endLine`, `startColumn`, `endColumn`; `warning`/`error`/`notice`/`debug`/`setSecret`/`startGroup`/`endGroup` public API |
| [file-command.ts](https://github.com/actions/toolkit/blob/main/packages/core/src/file-command.ts) | actions/toolkit | Newer `GITHUB_ENV` / `GITHUB_OUTPUT` file-based command format using `key<<delimiter\nvalue\ndelimiter`; completely separate from `::` stream commands; never appears in step log output |
| [ActionCommandManager.cs](https://github.com/actions/runner/blob/main/src/Runner.Worker/ActionCommandManager.cs) | actions/runner | The C# runner that actually receives and parses `::` commands; `IssueCommandProperties` defines wire keys: `file`, `line`, `endLine`, `col`, `endColumn`, `title`; `AddMaskCommandExtension` has `OmitEcho = true`; `DebugCommandExtension` also `OmitEcho = true`; `ValidateLinesAndColumns` strips `col`/`endColumn` when `line` is absent |
| [shared.go](https://github.com/cli/cli/blob/trunk/pkg/cmd/run/shared/shared.go) | cli/cli | REST API `Annotation` struct (`annotation_level`, `start_line`, `path`); `GetAnnotations` fetches from `/check-runs/:id/annotations` — annotations sourced from REST API, separate from log stream |
| [logs.go](https://github.com/cli/cli/blob/trunk/pkg/cmd/run/view/logs.go) | cli/cli | ZIP archive log fetcher; splits by job/step filename; streams raw text to terminal; no `::` directive parsing — annotations come from the REST API pipeline instead |

**Intentional scope gaps in `AnnotationParams`:** `col` and `endColumn` are valid wire-format
keys (emitted by `core.ts`, parsed by `ActionCommandManager.cs`) but are not modelled in
`AnnotationParams`. They are silently ignored as unknown keys — this is by design; column
metadata has no current display use in the log view.

---

## GitHubClient Package (`runbot-hq/GitHubClient`)

> See also: [runbot-hq/GitHubClient](https://github.com/runbot-hq/GitHubClient) for full API docs and package internals.

`GitHubClient` is the package RunBot uses for all GitHub API communication. `RunBotCore` declares it as a dependency and consumes it exclusively through protocol abstractions — `GitHubTransportProtocol` and `OAuthServiceProtocol` — so the core remains testable without Keychain or network access.

**How RunBot wires it up:**

`AppDelegate` constructs a single `GitHubClient` instance at launch, passing Keychain credentials, and holds the resulting `oauthService` and `transport` references. These are injected into `RunBotCore` types (e.g. `RunnerPoller`, `OAuthUseCase`) at init time — nothing in Core imports the package directly.

**What RunBot calls:**

- `fetchRunners(scope:)` — called by `RunnerPoller` on every poll tick to get the live runner list for each active org/repo scope
- `fetchActiveRuns(scope:)` — called by `RunnerPoller` to build workflow action groups; returns a typed result distinguishing `.success`, `.rateLimited(partial)`, and `.noToken`
- `fetchJobs(runID:scope:)` — called when a run is expanded in the UI to load its jobs and steps
- `fetchStepLog(jobID:stepNumber:scope:)` — called by `LogFetcher` to retrieve and display per-step CI logs
- `fetchUserOrgs()` / `fetchUserRepos()` — called by `AddScopeSheet` to populate the scope picker
- `oauthService.makeSignInURL()` / `oauthService.handleCallback(_:)` — called from `AppDelegate.application(_:open:)` to drive the OAuth sign-in flow

**Token resolution in RunBot's context:**

RunBot uses an explicitly selected authentication mode. OAuth mode resolves only from the Keychain-backed `TokenStore`. Environment mode resolves only from `GH_TOKEN` or `GITHUB_TOKEN`, including the login-shell lookup used for Finder/Dock launches. Unauthenticated mode supplies no token.

Credentials never fall back across modes. Discovering an environment token only makes the Environment control available; the user must explicitly enable Environment mode.

**Testing boundary:**

All tests that touch network or Keychain inject `MockTransport` and `MockOAuthService` via the `GitHubClient(oauthService:transport:)` test initialiser. No production `GitHubClient` instance is created in the test suite.

- ❌ NEVER import `GitHubClient` directly in `RunBotCore` source files — consume via the injected protocol only.
- ❌ NEVER construct a second `GitHubClient` instance — the one created in `AppDelegate` is the single source of truth for tokens and rate-limit state.

---

## AppUpdater Package (`runbot-hq/AppUpdater`)

> See also: [runbot-hq/AppUpdater](https://github.com/runbot-hq/AppUpdater) for full API docs and package internals.

`AppUpdater` is the package RunBot uses for in-app auto-update. RunBot is distributed outside the Mac App Store as an unsigned, Gatekeeper-bypass app, so `AppUpdater`'s first-class support for that distribution model is the reason it was chosen over Sparkle.

**How RunBot wires it up:**

`AppDelegate` holds a single `AppUpdater` instance initialised with RunBot's GitHub repo slug, the current bundle version, the expected zip asset name, an Ed25519 public key (embedded in the binary), and the `NSBackgroundActivityScheduler` identifier. An `@Observable UpdateState` object — conforming to `UpdateStateProviding` — is injected into the SwiftUI environment so update UI reacts automatically.

```swift
// AppDelegate.swift (illustrative)
let updater = AppUpdater(
    repo: "runbot-hq/run-bot",
    currentVersion: Bundle.main.shortVersion,
    assetName: { _ in "RunBot.zip" },
    publicKey: Secrets.appUpdaterPublicKey,
    schedulerIdentifier: "com.runbot.update-check"
)
```

**What RunBot calls:**

- `updater.checkAndHandle(state:)` — called once at launch inside a `Task` to perform an immediate update check
- `updater.scheduleBackgroundCheck(state:)` — called at launch to register the 24-hour background polling schedule
- `updater.installAndRelaunch(state:)` — called from the update UI when the user taps "Install & Relaunch"

**Update state in the UI:**

`UpdateState.currentPhase` drives a single `UpdateRow` view in the Settings panel. The view switches on `.idle`, `.available`, `.downloading`, `.ready`, and `.failed` — no other update logic exists in the app layer.

**Beta channel:**

RunBot opts into the beta channel by passing `betaChannelProvider: { AppPreferencesStore.shared.isBetaChannel }` at init time. The channel is toggled from Settings without restarting the updater.

**Ed25519 key:**

The public key is stored as a compile-time constant in `Secrets.swift` (not in `UserDefaults` or any plist). The matching private key lives as a GitHub Actions secret and is used by the release workflow to sign each `RunBot.zip` artifact before upload.

**`fixedZipURL` invariant:**

`fixedZipURL` is a computed property — not `lazy let`. This is intentional: a transient `FileManager.cachesDirectory` failure on one scheduler cycle will self-heal on the next rather than permanently baking in a `/tmp` fallback from a failed lazy initialisation. Any call site that needs the URL for more than one step (e.g. write then verify) must snapshot it into a local `let` at the top of that scope — never call `fixedZipURL` twice expecting the same value under concurrent access.

**`@MainActor` isolation note:**

`AppUpdater` is `@MainActor` at the instance level (its stored properties and the methods RunBot calls are all main-actor). A full type-level `@MainActor` annotation on the class itself is deferred until all remaining call sites are migrated (#1914). Do not add `nonisolated` to any of the three call sites listed above in the interim — that would silently remove the main-actor guarantee at those call sites.

- ❌ NEVER call `checkAndHandle` or `installAndRelaunch` from anywhere other than `AppDelegate` and the update UI respectively.
- ❌ NEVER store the Ed25519 public key in `UserDefaults`, a plist, or any on-disk file — binary only.
- ❌ NEVER change `schedulerIdentifier` without also migrating the on-disk cache path (`~/Library/Application\ Support/RunBot/ZIPCache<id>.zip`).
- ❌ NEVER call `fixedZipURL` more than once per operation — snapshot into a local `let` instead.

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
  ├─ tracks jobs + action groups, detects vanished items
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

Business logic lives in `Sendable` use-case structs (e.g. `WorkflowActionsUseCase`) with no isolation annotation. Because they are non-actor `Sendable` structs, all methods run on the cooperative thread pool when called with `await` from inside a `Task {}` (P18). `JSONDecoder` instances are `nonisolated` on actors where captured inside closures, expressing that they have no mutable state post-init — not as a workaround, but as a precise compiler-checked immutability guarantee (P17).

***

## Concurrency Ownership Map

| Component | Isolation | Pattern |
|---|---|---|
| `RunnerPoller` / `RunnerPoller+PollBridge` | nonisolated / background Task | `withTaskGroup`, `await MainActor.run` |
| `LocalRunnerStore` | background actor | `await MainActor.run` for UI pushes (ordered) |
| `RunnerConfigStore` | actor | `@concurrent` disk I/O helpers |
| `RateLimitActor` | actor | `snapshot()` atomic reads (P10) |
| `GitHubRateLimitHandler` | actor | generation counter for stale-task guard |
| `LogFetcher` | Sendable struct | `async` entry points, `Task.detached` callers |
| All SwiftUI Views | `@MainActor` | Plain `Task {}` inherits isolation |
| `ProcessRunner` | nonisolated | Legacy `withCheckedContinuation` + `DispatchQueue` (deliberate) |

The principles document (P4) confirms this is a **build-time guarantee** — no `@unchecked Sendable` in production, every actor crossing visible at the call site.

---

## NSPopover Decisions

Everything you need to know before touching `AppDelegate.swift`,
`AppDelegate+PanelSetup.swift`, `PopoverView.swift`, or any
sizing/frame/contentSize code in this project.

**Read this entire document before writing a single line.**

### Contents

- [Why NSPopover Instead of NSPanel](#why-nspopover-instead-of-nspanel)
- [Preventing Side-Jump on Resize](#preventing-side-jump-on-resize)
- [Dismiss, Sheets, and File Pickers](#dismiss-sheets-and-file-pickers)

---

### Why NSPopover Instead of NSPanel

> Issue: #1017 — SettingsView gets rectangular corners when a SwiftUI `.sheet` is presented

#### The core problem

When a SwiftUI `.sheet` (e.g. `RunnerDetailPopover`, `ScopeEditSheet`, `AddRunnerSheet`) is
presented on top of `SettingsView`, the **parent window** — not the sheet — loses its rounded
corners and goes fully rectangular.

This is **not** a bug in RunBot's logic. It is a well-known consequence of how AppKit handles
sheet presentation on windows that rely on any form of *custom* corner radius.

When AppKit calls `window.beginSheet(sheet)` it:
1. Adds the sheet as a child `NSWindow` via `addChildWindow(_:ordered:)` (or the newer
   `NSWindowAttachmentBehavior` path on macOS 14+).
2. To composite the two windows, it modifies the **parent window's `CALayer` tree** — in
   particular the `masksToBounds` and `mask` properties on the content view's backing layer.
3. Any `CAShapeLayer` mask or `cornerRadius + masksToBounds` that *you* set on that layer is
   removed or invalidated by AppKit as a side-effect.

This is documented nowhere publicly, but is confirmed by multiple developer reports:
- https://github.com/runbot-hq/run-bot/issues/1017
- https://stackoverflow.com/questions/62995489 (clear bg + borderless doesn't survive sheet)
- Electron issue #9159 (same root cause in a different runtime)

#### What was tried and failed

**Attempt 1 — `CAShapeLayer` mask on `NSVisualEffectView`** (`PanelChromeView`)

Drew a custom Bézier path (rounded rect + arrow tip) as a `CAShapeLayer` and applied it as
`fxView.layer.mask`. AppKit removes/replaces `layer.mask` on the parent window's content view
when a sheet is attached. The panel body went rectangular immediately on sheet presentation.

**Attempt 2 — `contentView.layer.cornerRadius + masksToBounds`** (PR #1017 first iteration)

Removed `PanelChromeView` and set `cornerRadius` + `masksToBounds` directly on the
`NSHostingController.view`. `masksToBounds = true` is precisely what AppKit modifies during
sheet attachment. Same result. Also: `masksToBounds` clips child `NSWindow`s' visual content.

**Attempt 3 — `backgroundColor = .clear + isOpaque = false`** ("window-server native corners")

Made the panel fully transparent, relying on the window server to draw native rounded corners.
Failed because a borderless `NSPanel` with `backgroundColor = .clear` does NOT get
window-server native rounded corners. That behaviour only applies to windows with a standard
(non-borderless) style mask. The transparency just made the rectangle invisible — the issue
was never fixed, just hidden in the zero-sheet state.

**Attempt 4 — `.background(.regularMaterial)` on `PanelMainView`**

Added vibrancy back after removing `PanelChromeView`. No rounding — the window layer has no
corner radius, so the material renders as a plain rectangle regardless.

#### Root cause

All attempts share the same flaw: they try to apply corner rounding *inside the window's view
hierarchy*. AppKit deliberately discards or overrides any such in-hierarchy clipping when a
sheet is presented. **The only correct solution is to never let the parent window's own layers
be responsible for rounding.**

#### The solution: NSPopover

`NSPopover` uses `NSPopoverWindowFrame`, a dedicated window class whose chrome is drawn by the
window-server compositor — completely unaffected by sheet attachment. Rounded corners survive
`.sheet` natively with zero extra code.

This is how every well-maintained macOS status bar app works: Raycast, Proxyman, Hand Mirror,
Longo, Almighty. The canonical Apple tutorial also uses `NSPopover`.

```
❌ NEVER revert to NSPanel without understanding the .sheet corner regression.
```

---

### Preventing Side-Jump on Resize

> Regression guard ref: issues #377, #1017  
> See also: `AppDelegate.swift`, `PopoverSizeObserver.swift`

#### The one rule

**Call `popover.show(relativeTo:of:preferredEdge:)` exactly once per open.** Never call it
again while the popover is visible. Every side-jumping bug in this codebase's history has
violated this rule.

#### Why jumping happens

`NSPopover` has two completely independent concepts:

| Concept | API | What it controls |
|---|---|---|
| **Anchor** | `popover.show(relativeTo:of:preferredEdge:)` | Where the arrow attaches. Recalculated from scratch on every call. |
| **Size** | `popover.contentSize` | How big the popover body is. Pure resize around the fixed anchor. |

Every time you call `show()`, AppKit recomputes the anchor geometry from the current
`button.bounds` and the *current* `contentSize`. If the size has changed since the last
`show()`, the anchor lands in a slightly different horizontal position — that's the jump.

#### The correct pattern

```swift
// AppDelegate.swift — openPanel()
// Called ONCE when the user clicks the status bar button.
popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

// PopoverSizeObserver.swift — KVO callback
// Called whenever SwiftUI changes preferredContentSize.
// NEVER calls show() again.
popover.contentSize = NSSize(width: newWidth, height: newHeight)
```

`contentSize` resizes the body in-place. The arrow never moves.

#### `animates = false` is not optional

With `animates = true` (AppKit default), every `contentSize` write starts a 200 ms Core
Animation resize. If SwiftUI fires multiple `preferredContentSize` KVO updates in one layout
pass (it does), you get overlapping animations, stuttering, and apparent jumps.

```swift
popover.animates = false   // set this at init time, never change it
```

#### Common mistakes

```swift
// ❌ WRONG — re-anchors the popover every time the size changes
func updateSize(_ size: CGSize) {
    popover.contentSize = size
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
}

// ❌ WRONG — bypasses AppKit geometry; anchor recalculates on next event tick
popover.contentViewController?.view.window?.setFrame(newFrame, display: true)

// ❌ WRONG — NSPanel.setFrame() couples position + size; always repositions
panel.setFrame(NSRect(origin: currentOrigin, size: newSize), display: true)
```

| Mistake | Why it jumps |
|---|---|
| Calling `popover.show()` again on resize | `show()` re-runs full anchor calculation from scratch |
| `behavior = .transient` with size changes | Transient mode can close and re-show automatically in some AppKit paths |
| Setting `contentSize` before `show()` with wrong size | Popover opens at wrong size; `show()` is called again to "fix" it |
| `NSWindow.setFrame()` on the popover's window | Bypasses AppKit geometry; anchor recalculates on next event loop tick |

#### History of this bug

| Commit / PR | What broke | Root cause |
|---|---|---|
| Pre-NSPopover migration | Jump on every resize | `NSPanel.setFrame()` couples position and size |
| First NSPopover attempt | Jump on tab switch | `show()` called in the resize observer |
| #1017 workaround attempt | Jump on sheet present | `show()` called to "reposition after promotion" |

#### Checklist before merging any PR that touches popover code

- [ ] `popover.show()` is called in exactly one place (the status bar button action)
- [ ] No resize/layout observer calls `show()`
- [ ] `popover.animates` is `false`
- [ ] `contentSize` is the only API used for size changes while the popover is open
- [ ] Tested: open popover, trigger a size change (switch tab, load data), confirm no horizontal shift

```
❌ NEVER re-call popover.show() on resize.
```

---

### Dismiss, Sheets, and File Pickers

> PR: #1195 — popover dismissing when user clicks inside NSOpenPanel  
> See also: `AppDelegate.swift`, `AppDelegate+PanelSetup.swift`, `WindowGrabber.swift`

#### The problem

RunBot uses an NSPopover as its main UI surface. Inside the popover, SwiftUI presents a
Settings flow via `.sheet`, and inside that sheet the user can open a folder picker
(NSOpenPanel) to select a path.

NSOpenPanel opens as a separate window. When the user clicks inside it, the click lands
outside the popover's frame. RunBot's global `NSEvent` monitor sees an outside click and
calls `hidePanel()`, dismissing both the popover and the sheet before the user has picked
anything. This is the bug fixed by PR #1195.

#### Popover configuration

```
behavior  = .applicationDefined
animates  = false
delegate  = AppDelegate
```

**Why `.applicationDefined` and not `.transient`:**

`.transient` closes on any outside interaction with no awareness of NSOpenPanel. Worse: with
`.transient` AppKit bypasses the global NSEvent monitor entirely — it closes the popover
internally without ever delivering the click event to our handler. This made every guard and
flag in Attempts 4–7 unreachable dead code.

`.applicationDefined` keeps dismiss control in our hands. AppKit consults
`popoverShouldClose(_:)` before dismissing, and our global event monitor receives every
outside click so we can decide what to do with it.

**Re-asserting `behavior` and `delegate` before every `show()`:**

AppKit latches `behavior` at `popover.show()` time, not at assignment time. If the value ever
resets between sessions, the next open silently runs as `.transient`. Fix: re-assert
`popover.behavior = .applicationDefined` and `popover.delegate = self` immediately before
every `popover.show()` call in `openPanel()`.

#### How the dismiss pipeline works

```
Status bar click
    └─> togglePanel()
            └─> openPanel()
                    ├─> popover.show()
                    ├─> install outsideClickMonitor  (NSEvent global monitor)
                    └─> install workspaceObserver    (NSWorkspace notification)

Outside click
    └─> outsideClickMonitor fires
            ├─> guard panelIsOpen
            ├─> guard !hasActiveSheet      ← THE KEY GUARD
            ├─> guard click not in popover frame
            └─> hidePanel()

App switch
    └─> workspaceObserver fires
            ├─> guard panelIsOpen
            ├─> guard !hasActiveSheet
            ├─> guard activatedApp != NSRunningApplication.current
            └─> hidePanel()

Any close path
    └─> tearDownOpenState()
            ├─> removes outsideClickMonitor
            └─> removes workspaceObserver
```

`popoverShouldClose(_:)` always returns `true`. AppKit is never blocked here. All dismiss
control goes through `outsideClickMonitor` and `workspaceObserver`.

#### The fix — `hasActiveSheet` + `beginSheetModal`

**1. `beginSheetModal(for: popoverWindow)`**

NSOpenPanel is opened using `picker.beginSheetModal(for: hostWindow)` instead of
`picker.begin { }` or `picker.runModal()`. `beginSheetModal` attaches NSOpenPanel as a child
sheet of the popover's own `NSWindow`, making it appear in `popoverWindow.sheets`.

`picker.begin { }` opens NSOpenPanel as a free-floating window that is completely invisible to
every guard mechanism: `NSApp.modalWindow` is `nil`, `NSApp.windows` doesn't contain it,
`popoverWindow.sheets` doesn't contain it. `beginSheetModal` fixes all three at once.

**2. `guard !hasActiveSheet`**

```swift
var hasActiveSheet: Bool {
    popover?.contentViewController?.view.window?.sheets.isEmpty == false
}
```

Both `outsideClickMonitor` and `workspaceObserver` guard on this before calling `hidePanel()`.
If any sheet is attached to the popover window — NSOpenPanel, SwiftUI `.sheet()`, or any
future modal — the monitor returns immediately. No dismiss.

**Why not a boolean flag (`isFilePickerActive`):**

Attempts 4–9 all tried a flag. Every one failed:

| Failure mode | Attempts affected |
|---|---|
| Flag set after `NSApp.activate()` fires the workspace notification (ordering race) | 6 |
| Flag read in non-isolated closure — Swift 6 stale-value warning | 6 |
| Flag threaded through `Task { @MainActor }` hop — new async timing window | 7 |
| Second call site (`AddRunnerSheet`) missed entirely — flag never set | 9 |

`hasActiveSheet` has none of these failure modes: it's a direct structural check on
`popoverWindow.sheets` with no timing dependency and no call-site boilerplate.

#### `WindowGrabber` — reliable `NSWindow` reference for `beginSheetModal`

`beginSheetModal(for:)` requires a valid `NSWindow` at call time. `NSApp.keyWindow` is
unreliable — key window can be `nil` or point to the wrong window depending on focus state.

`WindowGrabber` is a zero-size `NSViewRepresentable` that captures the hosting `NSWindow` via
`viewDidMoveToWindow()`, which fires when the SwiftUI view is first inserted into the view
hierarchy — before any user interaction is possible.

```swift
// In ScopeDetailView / AddRunnerSheet:
.background(WindowGrabber { w in
    if hostWindow == nil, let w { hostWindow = w }
})
```

**Gotcha:** `viewDidMoveToWindow()` also fires with `window = nil` when the view is removed.
The `if hostWindow == nil, let w` guard prevents it overwriting a valid reference. If a future
view can be re-attached to a different window, add `guard let window else { return }` inside
`WindowGrabber` itself and remove the call-site guard.

#### Sheet state across hide/show

`hidePanel()` does **not** call `dismissSheets()` and does **not** reset `rootView`.
`popover.performClose()` closes `NSPopoverWindowFrame` and all child windows together —
removed from screen but the `NSHostingController` and its SwiftUI tree stay alive with
`@State` preserved. On re-open, `popover.show()` re-attaches the same controller and SwiftUI
re-presents the sheet automatically because the binding is still `true`.

`closePanel()` resets `rootView = mainView()` so the next open starts fresh.

### Rules

```
❌ NEVER use picker.begin { }            — free-floating, invisible to hasActiveSheet
❌ NEVER use picker.runModal()           — same reason
✅ ALWAYS use picker.beginSheetModal(for: hostWindow)

❌ NEVER call popover.show() on resize   — re-anchors the arrow; use contentSize only
❌ NEVER omit behavior re-assert before show() — AppKit latches at show-time
❌ NEVER omit delegate re-assert before show() — same reason

❌ NEVER add dismissSheets() to hidePanel()
❌ NEVER reset hostingController.rootView in hidePanel()

❌ NEVER remove tearDownOpenState() from any close path — monitor leak
❌ NEVER inline teardown back into AppDelegate.swift
❌ NEVER call popover.performClose() while a sheet is open without first calling
        hidePopoverWindowsPreservingSheets()
```

### Design
- liquid glass: https://gist.github.com/eonist/a8f0d160c7e9e37f634a15c3a33a8109
