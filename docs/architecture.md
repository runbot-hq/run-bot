# RunBot — Architecture

This document describes the current ownership model, startup lifecycle, and UI
architecture of the windowed SwiftUI app, plus the subsystem deep-dives that are
still current (log processing, ETag caching, ZIP cache, concurrency).

> The former MenuBarKit-based status-item panel was retired during the windowed
> app migration tracked by #2945 and #2969.

Regression guards and architectural decisions are enforced inline in the source.
**Do not remove** the corresponding inline annotations without updating this file.

---

## Index

- [System overview](#system-overview)
- [Startup lifecycle](#startup-lifecycle)
- [UI architecture](#ui-architecture)
- [Presentation](#presentation)
- [Package boundaries](#package-boundaries)
  - [`GitHubClient`](#githubclient-package-runbot-hqgithubclient)
  - [`MarkdownKit`](#markdownkit-package-runbot-hqmarkdownkit)
  - [`AppUpdater`](#appupdater-package-runbot-hqappupdater)
- [Core runtime](#core-runtime)
  - [`RunBotCore` library rationale](#runbotcore-library-rationale)
  - [`RunnerPoller` responsibilities](#runnerpoller-responsibilities-and-isolation)
  - [`PollLoopCoordinator`](#pollloopcoordinator)
  - [`RunnerPollerProtocol` and `MockPoller`](#runnerpollerprotocol-and-mockpoller)
  - [Data model](#data-model)
  - [Log processing](#log-processing)
  - [Markdown rendering](#markdown-rendering)
- [Concurrency model](#concurrency-model)
- [ETag caching](#etag-caching)
- [ZIP log cache](#zip-log-cache)

---

## System overview

```
main.swift
└── RunBotDesktopApp
    ├── GitHubAuthentication
    ├── MigrationAppDependencies
    │   ├── GitHubClient
    │   ├── OAuthCredentialController
    │   ├── RunnerState
    │   ├── LocalRunnerStore
    │   ├── RunnerPoller
    │   │   └── PollLoopCoordinator
    │   ├── LogFetcher
    │   └── MigrationSettingsDependencies
    │       └── AppUpdater
    └── AppShellView
        └── NavigationSplitView
            ├── AppSidebarView
            ├── AppContentView
            └── AppDetailView
```

- `main.swift` calls `RunBotDesktopApp.main()` inside `MainActor.assumeIsolated`.
  (`@main` cannot coexist with top-level code in `main.swift`; never remove the
  `assumeIsolated` wrapper — the OS always starts on the main thread and this
  satisfies strict-concurrency checking.)
- `RunBotDesktopApp` is the application composition root. It constructs
  authentication and dependencies synchronously before any view is mounted and
  handles the OAuth callback via `.onOpenURL`.
- `MigrationAppDependencies` owns all long-lived domain services for the app
  lifetime. Views receive shared state and services; they never construct their
  own instances of stores, clients, or pollers.
- `RunnerState` is the observable read model for the entire UI — one instance,
  written only by `RunnerPoller`, observed directly by SwiftUI.
- `RunnerPoller` owns GitHub polling. Its `PollLoopCoordinator` owns the three
  task handles driving the loop (poll, interval observation, scope observation)
  and remains active architecture.

---

## Startup lifecycle

The order below is encoded by `MigrationAppDependencies`:

```
RunBotDesktopApp.init
→ create GitHubAuthentication
→ create MigrationAppDependencies
→ configure LocalRunnerStore synchronously
→ construct GitHubClient and RunnerPoller
→ construct OAuthCredentialController
→ mount AppShellView
→ MigrationAppDependencies.start()
→ reconcile OAuth state
→ start OAuth observation
→ refresh local runners
→ start runner polling
```

Invariants:

- `LocalRunnerStore.configure(viewModel:)` must happen **before any view mounts**
  (fix for issue #1741). It is the first call in `init()`, synchronous.
- OAuth reconciliation and observation start **before the first suspension
  point** in `start()` — no `await` may precede them.
- Local-runner hydration finishes before the poll loop starts, so the install
  path map is populated on the first fetch.
- `start()` is idempotent (`didStart` guard) because SwiftUI `.task` blocks can
  run more than once.
- Sign-out restarts polling through `OAuthCredentialController.didSignOut`.
- There must be exactly one configured `GitHubClient`, one `RunnerState`, and
  one poller for the app lifetime.

---

## UI architecture

A three-column `NavigationSplitView` shell:

| Column | Router | Responsibilities |
|---|---|---|
| Sidebar | `AppSidebarView` | Top-level section selection and pinned system metrics |
| Content | `AppContentView` | Workflow hierarchy, local runners, scopes, or settings list |
| Detail | `AppDetailView` | Step log, runner detail, scope detail, or settings detail |

State ownership:

- `AppShellView` owns top-level section selection.
- `MigrationWorkflowSelection` owns workflow → job → step selection.
- Runner, scope, and settings selection are owned by the shell and passed down
  as bindings so the content list and detail column stay consistent (#2900).
- `LogFetcher` is app-owned (`RunBotDesktopApp` → `@Binding` into
  `AppShellView`) so its ZIP cache survives navigation and view remounts.
- Detail views resolve selected models from current observable snapshots rather
  than retaining stale copies.

---

## Presentation

RunBot is a regular SwiftUI `Window` application. It does not use an
`NSStatusItem`, anchored `NSPanel`, outside-click dismissal monitor, or shared
overlay gate.

Presentation uses native SwiftUI APIs:

- `.sheet` for application sheets.
- `.fileImporter` for directory selection.
- `.alert` for alerts.
- `NavigationSplitView` for primary navigation.

A file importer launched from sheet content must be attached inside that
sheet's view hierarchy so AppKit parents the importer to the sheet window.
While an importer is presented, the parent sheet disables interactive dismissal
(#2948).

Dark & light mode follow the macOS system appearance with no user-facing
toggle: Liquid Glass styling comes from the design tokens in `DesignTokens.swift`
(`glassCard`, spacing/typography/radius tokens), and all views use semantic
colors that resolve at render time. Never hardcode raw colors in the UI layer.

---

## Package boundaries

| Module | Responsibility |
|---|---|
| `RunBot` | SwiftUI application, composition root, navigation, platform UI |
| `RunBotCore` | Runner models, polling, stores, log processing, process and filesystem services |
| `GitHubClient` | GitHub transport, authentication, token resolution, rate limiting |
| `AppUpdater` | Release discovery, signature verification, download and update lifecycle |
| `MarkdownKit` | Markdown detection, parsing, normalized models, rendering and highlighting |

**MenuBarKit is no longer a dependency.**

The load-bearing boundary rule: **`RunBotCore` must never import the `RunBot`
app target.** App-layer dependencies are injected into Core via protocols and
closures. See [Core runtime](#core-runtime) for how this is enforced.

---

### `GitHubClient` Package (`runbot-hq/GitHubClient`)

> See also: [runbot-hq/GitHubClient](https://github.com/runbot-hq/GitHubClient) for full API docs and package internals.

`GitHubClient` is the package RunBot uses for all GitHub API communication.
Testable seams are protocol-typed — `GitHubTransportProtocol`,
`OAuthServiceProtocol` — so tests inject stubs instead of hitting the network or
Keychain.

**How RunBot wires it up:**

`MigrationAppDependencies` constructs a single `GitHubClient` instance in
`init()`, passing Keychain credentials (service/account names must match the
pre-GitHubClient keychain entries — changing them orphans stored tokens) and an
auth-source closure reading `GitHubAuthentication`. The client's `oauthService`
and transport references are injected into `RunBotCore` types (`RunnerPoller`,
`OAuthCredentialController`) at init time.

**What RunBot calls:**

- `fetchRunners(scope:)` — called by `RunnerPoller` on every poll tick to get the live runner list for each active org/repo scope
- `fetchActiveRuns(scope:)` — called by `RunnerPoller` to build workflow action groups; returns a typed result distinguishing `.success`, `.rateLimited(partial)`, and `.noToken`
- `fetchJobs(runID:scope:)` — called when a run is expanded in the UI to load its jobs and steps
- `fetchStepLog(jobID:stepNumber:scope:)` — called by `LogFetcher` to retrieve and display per-step CI logs
- `fetchUserOrgs()` / `fetchUserRepos()` — called by `AddScopeSheet` to populate the scope picker
- `oauthService.makeSignInURL()` / `oauthService.handleCallback(_:)` — sign-in URL opened from the settings auth card; callbacks arrive via `.onOpenURL` → `MigrationAppDependencies.handleOAuthCallback(_:)`

**Token resolution in RunBot's context:**

RunBot uses an explicitly selected authentication mode. OAuth mode resolves only from the Keychain-backed `TokenStore`. Environment mode resolves only from `GH_TOKEN` or `GITHUB_TOKEN`, including the login-shell lookup used for Finder/Dock launches. Unauthenticated mode supplies no token.

Credentials never fall back across modes. Discovering an environment token only makes the Environment control available; the user must explicitly enable Environment mode. `gh auth login` / `gh auth token` is not a supported path.

**Testing boundary:**

All tests that touch network or Keychain inject mock transports and OAuth services via the `GitHubClient(oauthService:transport:)` test initialiser. No production `GitHubClient` instance is created in the test suite.

- ❌ NEVER construct a second `GitHubClient` instance — the one created by `MigrationAppDependencies` is the single source of truth for tokens and rate-limit state.

---

### `MarkdownKit` Package (`runbot-hq/MarkdownKit`)

`MarkdownKit` owns Markdown parsing, rendering primitives, syntax highlighting, and its underlying `swift-markdown` and `Highlightr` dependencies. The `RunBot` target owns application-specific presentation:

- `MarkdownLogView` integrates the renderer into step-log presentation.
- `MarkdownStyle+RunBot` maps RunBot design tokens onto `MarkdownStyle`.
- `MarkdownKit` must not import or depend on app-target symbols.

The package tracks the `main` branch. Dependency pinning and release behavior are documented in [deployment.md](deployment.md).

---

### `AppUpdater` Package (`runbot-hq/AppUpdater`)

> See also: [runbot-hq/AppUpdater](https://github.com/runbot-hq/AppUpdater) for full API docs and package internals.

`AppUpdater` is the package RunBot uses for in-app auto-update. RunBot is distributed outside the Mac App Store as an unsigned, Gatekeeper-bypass app, so `AppUpdater`'s first-class support for that distribution model is the reason it was chosen over Sparkle.

**How RunBot wires it up:**

`MigrationAppDependencies.init()` constructs a single `AppUpdater` instance inside `MigrationSettingsDependencies`, initialised with RunBot's GitHub repo slug, the current bundle version, the expected zip asset name, an Ed25519 public key (embedded in the binary as a base64 constant), and the `NSBackgroundActivityScheduler` identifier. Its `UpdateState`-conforming state object drives update UI via observation.

```swift
// MigrationAppDependencies.swift (illustrative)
let updater = AppUpdater(
    repo: "runbot-hq/run-bot",
    currentVersion: Bundle.main.rbVersionString,
    assetName: { _ in "RunBot.zip" },
    publicKey: <Ed25519 public key, base64>,
    schedulerIdentifier: "io.github.runbot-hq.update-check",
    betaChannelProvider: { AppPreferencesStore.shared.betaChannel }
)
```

**What RunBot calls:**

- `updater.checkAndHandle(state:)` — user-initiated check from `UpdateSettingsSection`
- `updater.installAndRelaunch(state:)` — called from the update UI when the user taps "Install & Relaunch"

**Update state in the UI:**

`runnerState.currentPhase` drives the update controls in `UpdateSettingsSection`. The view switches on the update phases (idle, available, downloading, ready, failed) — no other update logic exists in the app layer.

**Ed25519 key:**

The public key is embedded as a base64 constant in `MigrationAppDependencies.swift` (not in `UserDefaults` or any plist). The matching private key lives as a GitHub Actions secret and is used by the release workflow to sign each `RunBot.zip` artifact before upload.

**`fixedZipURL` invariant:**

`fixedZipURL` is a computed property — not `lazy let`. This is intentional: a transient `FileManager.cachesDirectory` failure on one scheduler cycle will self-heal on the next rather than permanently baking in a `/tmp` fallback from a failed lazy initialisation. Any call site that needs the URL for more than one step (e.g. write then verify) must snapshot it into a local `let` at the top of that scope — never call `fixedZipURL` twice expecting the same value under concurrent access.

**`@MainActor` isolation note:**

`AppUpdater` is `@MainActor` at the instance level (its stored properties and the methods RunBot calls are all main-actor). Do not add `nonisolated` to the call sites listed above — that would silently remove the main-actor guarantee.

- ❌ NEVER call `checkAndHandle` or `installAndRelaunch` from anywhere other than the update UI.
- ❌ NEVER store the Ed25519 public key in `UserDefaults`, a plist, or any on-disk file — binary only.
- ❌ NEVER change `schedulerIdentifier` without also migrating the on-disk cache path (`~/Library/Application Support/RunBot/ZIPCache<id>.zip`).
- ❌ NEVER call `fixedZipURL` more than once per operation — snapshot into a local `let` instead.

---

## Core runtime

### `RunBotCore` Library Rationale

`RunBotCore` is a plain Swift package library target — no app bundle, no AppKit,
no entitlements. Code there is **completely decoupled from the macOS app
runtime**. In a pure SPM codebase without `.xcodeproj`, this boundary is
enforced by the compiler itself: if you accidentally import AppKit-level app
concerns in a Core file, the build fails.

**Why it pays off:**

- **Testability.** Core code runs under bare `swift test` — no app bundle, no
  entitlements, no Keychain prompts. CI runs `swift build && swift test` in
  seconds; app-layer testing requires a full `xcodebuild` invocation.
- **CI speed and parallel compilation.** SPM builds targets in parallel; the
  more logic lives in Core, the more compiles independently of the app layer.
- **Dependency discipline.** The compiler prevents app-layer singletons from
  leaking into business logic.
- **Static-analysis scope.** Periphery/SonarCloud can scan Core alone for
  high-signal dead-code findings.
- **Reusability.** A future CLI tool or helper target can import `RunBotCore`
  without pulling in the app dependency graph.

**Costs and constraints:**

- Types moved to Core need explicit `public` access control — mechanical but
  noisy.
- `@MainActor` isolation must be declared explicitly rather than inherited from
  the app's implicit main-actor context.
- Truly app-specific code (LaunchAgents, `ServiceManagement`, UI) belongs in
  the app target — moving it to Core would be wrong.

---

### `RunnerPoller` Responsibilities and Isolation

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
mutation automatically — **no Combine `PassthroughSubject` and no view-model
push coupling**. Views observe `RunnerState` directly.

### `PollLoopCoordinator`

`RunnerPoller` owns a `PollLoopCoordinator` (`private let pollLoop`) that holds the three
`Task` handles driving the loop: the poll task, the interval-observation task, and the
scope-observation task. Because it's a stored property of the actor, all access is
serialised by the actor's executor. It carries a documented `@unchecked Sendable`
sign-off (a deliberate Principle #4 exception) so `deinit` can cancel the handles.

### `RunnerPollerProtocol` and `MockPoller`

`MigrationAppDependencies` types the poller as `any RunnerPollerProtocol`
(`func start() async` + `var state: RunnerState { get }`). `RunnerPoller` is the
production conformer; `MockPoller` is a no-op actor for SwiftUI previews and
snapshot tests — `start()` is a guaranteed no-op that never touches the network.

---

## Data Model

This section describes the runtime data model of RunBot: how the GitHub poll loop
fetches and enriches state, how that state reaches SwiftUI, and how local (on-disk)
runners are reconciled with GitHub-hosted runners.

### `RunnerState` — the observable read model

`RunnerState` is an `@Observable @MainActor public final class` populated by `RunnerPoller`
and consumed read-only by views. It replaces the retired `RunnerViewModel` push target.

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

### `RunnerModel` — local (on-disk) runner

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

### `Runner` — GitHub API runner snapshot

`Runner` is the API-decoded remote snapshot (API-first, vs. `RunnerModel` which is
local-first): `id: Int`, `name`, `status: RunnerStatus`, `busy: Bool`, optional
`metrics: RunnerMetrics`, plus a derived `displayStatus`. `RunnerPoller` enriches busy
`Runner`s with metrics read from the corresponding local runner.

### How they relate

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
SwiftUI views (observe RunnerState directly)
```

`RunnerModel` is the local ground truth; `Runner` is the GitHub API model.
`RunnerPoller` reconciles the two every poll tick and writes the merged result into
`RunnerState`, which SwiftUI observes directly — no push coupling, no app-target import
from Core.

---

### Log processing

#### Log Directive Parsing — Reference Spec

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

### Markdown rendering

Markdown rendering is owned by the `MarkdownKit` package (see [Package boundaries](#package-boundaries)). The `RunBot` app target provides application-specific presentation via `MarkdownLogView` and `MarkdownStyle+RunBot`, which maps RunBot design tokens onto `MarkdownStyle`.

---

## Concurrency Model

The concurrency model is explicit and compiler-enforced end-to-end. All UI state lives on `@MainActor`, all background domain work is isolated in dedicated actors, and there are no `@unchecked Sendable` escape hatches in production types. The system maps to **six core concurrency pillars** across 21 documented principles.

***

## Pillar 1: Actor-Per-Concern Isolation (P1, P16)

Each mutable domain owns its own actor — there is no single "background actor" everything piles into. The canonical examples are:

- **`RateLimitActor`** — serialises all rate-limit state and exposes a `snapshot()` method for atomic reads (P10)
- **`RunnerConfigStore`** — its own actor, serialising all disk I/O for `.runner` config files
- **`LocalRunnerStore`** — pushes snapshots to `state.localRunners` on `MainActor` using `await MainActor.run` (not fire-and-forget `Task`) to guarantee mutation ordering

## Pillar 2: MainActor Boundary Crossings (P2)

Views are `@MainActor`-isolated. The boundary-crossing pattern used throughout is:

```swift
let scopes = await MainActor.run { scopeStore.activeScopes }
```

This is used in `RunnerPoller.start()` and `RunnerPoller+PollBridge` to safely read `@MainActor`-isolated properties from a background context. `Task { @MainActor in ... }` is used for fire-and-forget operations from SwiftUI views.

## Pillar 3: Structured Concurrency for Timers & Loops (P9)

All timers use `Task` + `Task.sleep(for:)` rather than `DispatchQueue.asyncAfter`. A **generation counter** guards against stale-task races where a sleeping task wakes after a newer window has started. Task names leverage Swift 6.2's `Task(name:)` API (SE-0462) for Instruments/crash log debuggability:

```swift
Task(name: "RunnerPoller.init: startObservingScopes") { await self.startObservingScopes() }
```

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

The principles document (P4) confirms this is a **build-time guarantee** — no `@unchecked Sendable` in production (except the documented `PollLoopCoordinator` sign-off), every actor crossing visible at the call site.

---

## ETag caching

RunBot polls the same GitHub endpoints continuously, and most polls return
unchanged JSON. `ConditionalGETCache` turns those repeated downloads into
cheap revalidations, entirely inside the transport layer.

### How it works

Each `GitHubTransport` owns a private, actor-isolated, memory-only cache. On a
successful response with an `ETag`, the transport stores the ETag, the response
body, and the response's `Link` header, keyed by fully resolved URL. The next
request for that URL sends `If-None-Match`:

- `200 OK` — a new representation; replace the cached entry.
- `304 Not Modified` — reuse the cached body and `Link` header.

A cache-backed `304` is surfaced to callers as a normal `.success` with status
`200`, so polling, pagination, and decoding follow one code path regardless of
where the bytes came from.

### Token ownership

An ETag is valid for a *representation*, not a URL: the same endpoint returns
different authenticated bodies under different tokens. Rather than keying by
`URL + token` (which would retain old accounts' bodies and put PATs in
dictionary keys), the cache treats the active token as its owner and maintains
one invariant:

```text
cached response owner == currently active token
```

Any token change clears every entry before a lookup or store. A lookup may
establish or change ownership; storing a completed response may not — this
prevents a late in-flight response from an old token from resurrecting stale
authenticated data after an account switch.

### Scope and opt-in

Conditional GET is opt-in per request via `execute(conditionalGET:)`, and only
GitHub JSON reads opt in:

| Transport path | ETag cache |
|---|---:|
| `apiAsync` | Yes |
| `apiPaginated` | Yes |
| Raw ZIP downloads | No |
| POST, PUT, PATCH, DELETE | No |
| Other requests | No |

Gating both lookup and storage keeps a mutation or ZIP response from parking an
incompatible body under a URL later used for JSON. Opted-in requests use
`.reloadIgnoringLocalCacheData` so the system URL cache cannot hide GitHub's
`304` from the transport.

### Pagination and API accounting

Because pagination depends on the `Link` header, each entry stores it alongside
the body — a `304` on page one restores its `Link` header and pagination
continues to page two. Pages are validated independently, so a cached page one
may combine with a fresh page two if the remote collection shifts; this
eventual-consistency tradeoff avoids a collection-level cache or a pagination
state machine.

A `304` delivers no new representation, so API-call accounting does not count
it:

```text
200 → fresh representation → count it
304 → cached representation → do not count it
```

### Deliberate non-goals

This is not persistent storage, a general-purpose URL cache, or an
application-level data cache. Its only job is making repeated authenticated
GitHub reads cheap while keeping ETag, token, pagination, and `304` handling
confined to the transport.

## ZIP log cache

The primary purpose of the ZIP cache is to preserve GitHub Actions logs while they
still contain precise per-step data.

GitHub's workflow-run log endpoint can temporarily return a rich ZIP archive whose
files can be mapped to individual workflow steps. After an undocumented and
unpredictable period, the same endpoint may stop returning that structure or may
return a degraded archive containing only job-level log data.

The duration of this window is not treated as a contract. It has appeared to vary
from minutes to hours. RunBot must therefore capture the rich archive as soon as a
workflow run reaches a terminal conclusion.

### Best-effort capture

`ZIPPrefetchQueue` observes workflow groups transitioning from active to completed.
For every workflow run in the completed group, it requests:

```text
/repos/{owner}/{repo}/actions/runs/{run-id}/attempts/{run-attempt}/logs
```

The returned ZIP is written to `DiskZIPCache` only after the run has completed. This
includes successful, failed, cancelled, and other terminal conclusions; caching is
not restricted to successful runs.

Capture is deliberately best-effort:

- RunBot must be active when the completion transition is observed.
- The ZIP must still be available in its rich, step-dividable form.
- Failed or expired downloads are not considered fatal application errors.
- RunBot does not replay historical completion transitions after restart.
- A cache miss must never prevent the step log view from attempting its fallback paths.

This cache is therefore a preservation mechanism, not a guaranteed archive of every
workflow execution.

### Cache identity

A cache group uses the same semantic identity as a displayed workflow group:

```text
repository + full head SHA + normalized event
```

It is stored as one readable directory directly under the cache root:

```text
<owner>@<repo>--<full-sha>--<normalized-event>/
```

Each workflow-run archive is identified by run ID and run attempt:

```text
<run-id>-<run-attempt>.zip
```

Example:

```text
DiskZIPCache/
├── runbot-hq@run-bot--fb306a5bcaad562d2e7bc183b86e4a70e983c3dd--commit/
│   ├── 31350001-1.zip
│   ├── 31350002-1.zip
│   └── 31350003-2.zip
└── runbot-hq@run-bot--fb306a5bcaad562d2e7bc183b86e4a70e983c3dd--workflow_dispatch/
    └── 31350100-1.zip
```

GitHub retains the same run ID when a workflow is rerun and increments
`run_attempt`. A cache hit is valid only when both values match.

RunBot displays the attempt associated with the current `ActiveJob`. Each
`runID-runAttempt.zip` archive is stored independently, so an older attempt cannot
satisfy a newer attempt's cache lookup. Attempts remain on disk until the containing
workflow-group directory is evicted.

### Step-log resolution

The step log view resolves logs through progressively less precise sources.

#### 1. Cached rich workflow-run ZIP

The preferred source is a cached workflow-run ZIP captured during the completion
window.

A rich archive contains files that can be matched to individual workflow steps.
The view extracts and displays only the requested step's content.

This is the only fully reliable source of precise per-step boundaries after GitHub's
availability window has closed.

#### 2. Degraded workflow-run ZIP

GitHub may later return a ZIP with a different structure that no longer contains
individually addressable step files. It may contain only job-level log content.

RunBot attempts to locate or infer the requested step from this content. If precise
extraction is impossible, the view displays the containing job log for the
requested step and shows a visible degradation notice.

This means multiple steps may display the same complete job log. That is intentional:
the original step boundaries are no longer available.

#### 3. Job-level flat-blob fallback

If the workflow-run ZIP is unavailable or unusable, `LogFetcher` requests:

```text
/repos/{owner}/{repo}/actions/jobs/{job-id}/logs
```

This endpoint returns a flat job log through a short-lived redirect. RunBot attempts
to parse the requested step from that blob.

If parsing succeeds, the inferred step section is displayed. If parsing fails,
the view displays the complete job log with a degradation notice rather than
showing no data.

The fallback hierarchy is therefore:

```text
cached rich ZIP
→ live workflow-run ZIP
→ parsed job-level flat blob
→ complete job-level flat blob
→ no output
```

### Folder-level eviction

Capacity is measured in workflow-group directories, not individual ZIP files. A
commit that produces ten workflow runs consumes one cache slot rather than ten.

The cache retains up to ten workflow-group directories:

1. Immediate child directories of the cache root are ordered by filesystem
   modification date, newest first.
2. Directories beyond the ten newest groups are deleted recursively.
3. ZIP count inside a retained group directory does not affect capacity.

Eviction always removes a complete workflow group. It never removes individual
sibling workflow runs merely because a commit contains many workflows.

Legacy root-level `<run-id>.zip` files do not contain enough identity information to
migrate safely and are deleted during cache preparation.

---

### Design

- liquid glass: https://gist.github.com/eonist/a8f0d160c7e9e37f634a15c3a33a8109
