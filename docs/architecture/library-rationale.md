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
