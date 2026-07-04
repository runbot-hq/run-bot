# 📁 File Hierarchy

A short description of every source file in the project.

---

```
run-bot/
├── Package.swift                            — SPM manifest; defines RunBot + RunBotCore + GitHubClient targets and their dependencies
├── project.yml                              — XcodeGen project definition
├── build.sh                                 — local build helper script
├── deploy.sh                                — deployment/release helper script
├── install.sh                               — runner installation helper script
├── README.md                                — project overview, screenshots, setup instructions
├── AGENTS.md                                — instructions / context for AI coding agents (repo root, per the AGENTS.md standard)
├── LICENSE                                  — project licence
├── sonar-project.properties                 — SonarCloud project configuration
├── .swiftlint.yml                           — SwiftLint rule configuration
├── .periphery.yml                           — Periphery dead-code scanner configuration
│
├── docs/
│   ├── architecture/
│   │   ├── file-hierarchy.md                — this file; annotated map of the codebase
│   │   ├── concurrency-overview.md          — overview of the concurrency architecture (actors, isolation, poll loop)
│   │   ├── data-model.md                    — description of the runner data model and how it is populated
│   │   ├── library-rationale.md             — rationale for third-party/library and architectural choices
│   │   └── swift-concurrency-lexicon.md     — glossary of Swift concurrency terms used across the project
│   ├── principles/
│   │   ├── project-principles.md            — core engineering principles and conventions for the project
│   │   └── reach-goal-principles.md         — aspirational / stretch principles guiding future architecture decisions
│   ├── design/
│   │   ├── brand-inspiration.md             — brand/design inspiration notes
│   │   ├── dark-light-mode-support.md       — notes on dark/light mode adaptive design
│   │   ├── liquid-glass.md                  — iOS 26 Liquid Glass Swift/SwiftUI reference and visual exploration
│   │   ├── runbot-light-glass.html       — HTML prototype of the light glass UI
│   │   └── zap.svg                          — zap icon asset used in design explorations
│   ├── guides/
│   │   ├── development.md                   — local development setup and workflow
│   │   ├── deployment.md                    — release and deployment instructions
│   │   ├── ui-testing.md                    — UI test runner setup and instructions
│   │   ├── commenting-standard.md           — Swift code commenting conventions for the project
│   │   ├── dev-with-log-in-terminal.md      — how to run the app with live log output in Terminal
│   │   ├── stacked-prs.md                   — stacked PRs best-practices guide
│   │   ├── stacked-prs-best-practice.md     — additional stacked-PR workflow notes
│   │   └── useful-commands.md               — handy shell commands for development tasks
│   ├── legal/
│   │   ├── github-permission-rationale.md   — justification for requested GitHub OAuth scopes
│   │   └── privacy.md                       — privacy policy and data-handling notes
│   └── ui/
│       ├── nspopover-dynamic-width.md       — NSPopover dynamic-width positioning without side-jumps
│       ├── nspopover-dismiss-and-sheets.md  — NSPopover architecture: dismiss, sheets, and file pickers
│       ├── popover-side-jump-prevention.md  — definitive guide to preventing status-bar popover side-jumping
│       ├── status-bar-window.md             — status-bar window construction strategy
│       └── ui-architecture.md               — UI layer architecture reference and component responsibilities
│
├── Sources/
│   │
│   ├── GitHubClient/                     (pure-Swift library — no AppKit/UIKit; no RunBotCore dependency)
│   │   │
│   │   │   All GitHub networking, auth and token types live here. RunBotCore
│   │   │   and RunBot both depend on this target. GitHubClient has no dependency
│   │   │   on either of them — the inversion is bridged via the TokenStore and
│   │   │   GitHubLogger protocols injected at construction time.
│   │   │
│   │   ├── API/
│   │   │   ├── APICallCounter.swift         — tracks GitHub REST call timestamps in a rolling 60-minute window
│   │   │   ├── GitHubConstants.swift        — shared GitHub API base URLs and endpoint path constants
│   │   │   ├── GitHubHelpers.swift          — free helpers (e.g. fetchUserOrgs) over the GitHub API
│   │   │   ├── GitHubRateLimitHandler.swift — actor-isolated rate-limit state + RateLimitSnapshot
│   │   │   ├── GitHubRequestBuilder.swift   — builds authenticated URLRequests; resolveURL endpoint logic
│   │   │   ├── GitHubResponseDecoder.swift  — decodes/validates GitHub JSON responses; logs error bodies
│   │   │   ├── GitHubRunnerFetchers.swift   — free functions fetching runners and active jobs from the API
│   │   │   ├── GitHubScope.swift            — Scope enum: a single repo or an entire organisation
│   │   │   ├── GitHubURLHelpers.swift       — extracts owner/repo or org scope strings from GitHub HTML URLs
│   │   │   └── KeychainTokenStore.swift     — canonical SecItem* TokenStore implementation (kSecUseDataProtectionKeychain, upsert retry guard, GitHubLogger error logging)
│   │   │
│   │   ├── Auth/
│   │   │   ├── OAuthService.swift           — @MainActor GitHub OAuth Authorization Code flow service (injected TokenStore + GitHubLogger)
│   │   │   ├── OAuthServiceProtocol.swift   — abstraction over the OAuth flow; exposes isAuthenticated + hasAnyToken for UI consumers
│   │   │   └── TokenCache.swift             — process-wide token cache with invalidation (Synchronization.Mutex-guarded)
│   │   │
│   │   ├── Protocols/
│   │   │   ├── GitHubLogger.swift           — logging protocol injected into GitHubClient types (bridges to RunBotCore log())
│   │   │   └── TokenStore.swift             — token persistence protocol (load/save/delete); implemented by KeychainTokenStore
│   │   │
│   │   └── Transport/
│   │       ├── GitHubTransportProtocol.swift    — protocol describing all GitHub network operations
│   │       ├── GitHubTransport+Conformance.swift — GitHubTransport conformance to the transport protocol
│   │       ├── GitHubURLSessionTransport.swift  — concrete URLSession-backed GitHubTransport implementation
│   │       ├── GitHubTransportShim.swift        — module-level ghAPI / ghAPIPaginated transport symbols
│   │       └── GitHubTransportShims.swift       — shared default GitHubTransport instance + configure/read shims
│   │
│   ├── RunBot/                           (AppKit/SwiftUI app target — UI + lifecycle)
│   │   │
│   │   ├── main.swift                       — entry point; instantiates AppDelegate and starts the run loop
│   │   │
│   │   ├── App/
│   │   │   ├── AppDelegate.swift            — @MainActor app delegate; owns NSPopover architecture and top-level wiring; wires OAuthService with KeychainTokenStore + RunBotLogger
│   │   │   ├── AppDelegate+Navigation.swift  — navigation handling extension
│   │   │   ├── AppDelegate+OAuthCallback.swift — handles the OAuth callback URL delivered by the OS
│   │   │   ├── AppDelegate+PanelSetup.swift  — NSPopoverDelegate conformance and panel setup
│   │   │   ├── AppDelegate+Polling.swift    — OAuth sign-out subscription and poll-loop coordination
│   │   │   ├── AppDelegate+StatusItem.swift  — status-bar item creation and management
│   │   │   ├── AppDelegate+StoreSetup.swift  — wires app-lifecycle callbacks to store and service setup
│   │   │   └── PopoverLifecycleCoordinator.swift — popover lifecycle coordinator extracted from AppDelegate (#1374)
│   │   │
│   │   ├── DesignSystem/
│   │   │   ├── DesignTokens.swift           — appearance-adaptive Color helpers for light/dark mode
│   │   │   ├── PanelViewModifiers.swift     — centralised Liquid Glass card view modifier
│   │   │   └── RemovalAlertModifier.swift   — confirmation alert modifier for runner removal
│   │   │
│   │   ├── Utilities/
│   │   │   └── WindowGrabber.swift          — captures the hosting NSWindow of a SwiftUI view at first display
│   │   │
│   │   └── Views/
│   │       ├── Components/
│   │       │   ├── DonutStatusView.swift    — donut status indicator for the action row
│   │       │   ├── RingBuffer.swift         — fixed-capacity circular buffer (oldest-first values)
│   │       │   ├── SparklineView.swift      — mini sparkline graph (polyline stroke + gradient fill)
│   │       │   ├── SystemStatsView.swift    — CPU/memory/disk stats view
│   │       │   ├── SystemStatsViewModel.swift — observable VM that periodically samples system metrics
│   │       │   └── WorkflowContextMenuModifier.swift — workflow context-menu + pasteboard helper modifier
│   │       ├── Main/
│   │       │   ├── ActionRowView.swift      — row representing one GitHub Actions workflow run
│   │       │   ├── InlineJobRowsView.swift  — inline job rows with set-toggle helpers
│   │       │   ├── PanelContainerView.swift  — generic container chrome for the popover panel
│   │       │   ├── PanelHeaderView.swift    — panel top bar: system stats + settings/quit buttons
│   │       │   ├── PanelMainView.swift      — main panel body (regression guard, refs #52/#54/#57/#375-377)
│   │       │   ├── PanelMainView+Subviews.swift — shared glue + String helpers after view extraction
│   │       │   ├── RunnerRowViews.swift     — runner row views and local/cloud type icon
│   │       │   ├── WorkflowActionGroup+Progress.swift — RelativeTimeFormatter and progress helpers
│   │       │   └── Sheets/
│   │       │       ├── BranchSelectorSheet.swift — sheet for picking a branch to filter the failure hook (#560)
│   │       │       └── RepoSelectorSheet.swift — reusable searchable repo/org picker sheet (#580/#576)
│   │       ├── Settings/
│   │       │   ├── SettingsView.swift       — main settings view (all phases 1–6); reads auth state from oauthService.isAuthenticated/hasAnyToken
│   │       │   ├── SettingsView+Sections.swift — settings sections broken out for readability
│   │       │   ├── APICallCounterRow.swift  — settings row showing the live GitHub API call counter
│   │       │   ├── APICallCounterViewModel.swift — @Observable VM exposing live API call-counter state
│   │       │   ├── LocalRunnersView.swift   — full local-runner management screen
│   │       │   ├── ScopesView.swift         — full scope-management screen
│   │       │   └── Sheets/
│   │       │       ├── AddRunnerSheet.swift  — add-runner sheet root + URI constants
│   │       │       ├── AddRunnerSheet+FormFields.swift — form-field subviews and folder actions
│   │       │       ├── AddRunnerSheet+TokenSection.swift — token section + runner download-URL lookup
│   │       │       ├── AddRunnerSheet+Validation.swift — validation helpers and state-check predicates
│   │       │       ├── AddScopeSheet.swift   — add-scope sheet (ScopeType selection)
│   │       │       ├── FailureHookCommandSheet.swift — per-scope failure-hook command editor (#544)
│   │       │       ├── RunnerDetailSheet.swift — edit a single self-hosted runner
│   │       │       └── ScopeEditSheet.swift  — modal scope-edit sheet (atomic save, #1540)
│   │       └── StepLog/
│   │           ├── LogCopyButton.swift      — shared top-bar copy button (idle/loading/done/failed states)
│   │           └── StepLogView.swift        — step-log viewer with a strict layout/sizing contract
│   │
│   └── RunBotCore/                       (pure-logic target — no UI dependencies)
│       │
│       ├── FailureHook/
│       │   ├── FailureHookRunner.swift      — production shim for FailureHookRunnerUseCase
│       │   ├── FailureHookRunnerAdapters.swift — production adapters bridging deps to the use-case protocols
│       │   ├── FailureHookRunnerDependencies.swift — dependency protocols (incl. ScopePreferencesStoreProtocol)
│       │   └── FailureHookRunnerUseCase.swift — testable, DI'd replacement for the static FailureHookRunner
│       │
│       ├── GitHub/
│       │   └── Auth/
│       │       ├── GitHubTokenCache.swift   — githubToken() / invalidateTokenCache() free functions; wires TokenCache to KeychainTokenStore with RunBot service/account constants
│       │       └── OAuthSecrets.swift       — OAuth app credential constants (clientID + clientSecret bundled with binary)
│       │
│       ├── Preferences/
│       │   ├── AppPreferencesStore.swift    — @MainActor store persisting general app settings to UserDefaults
│       │   ├── AppPreferencesStoreProtocol.swift — abstracts the polling-interval preference for test doubles
│       │   └── NotificationPreferences.swift — persists notification preferences to UserDefaults
│       │
│       ├── Runner/
│       │   ├── Models/
│       │   │   ├── ActiveJob.swift          — a live or recently-completed GitHub Actions job
│       │   │   ├── AggregateStatus.swift    — overall connectivity state derived from the runner fleet
│       │   │   ├── CommitResult.swift       — outcome enum for SaveRunnerEditsUseCase (moved to Core, #1300)
│       │   │   ├── JobStatus.swift          — typed enums for GitHub Actions job status/conclusion
│       │   │   ├── LifecycleResult.swift    — result of a runner start/stop lifecycle operation
│       │   │   ├── Runner.swift             — API-decoded snapshot of a single self-hosted runner
│       │   │   ├── RunnerConfig.swift       — Codable representation of the .runner JSON config file
│       │   │   ├── RunnerEditDraft.swift    — editable draft of runner config (moved to Core, #1300)
│       │   │   ├── RunnerMetrics.swift      — CPU/memory utilisation snapshot for a worker process
│       │   │   ├── RunnerModel.swift        — locally-discovered runner found by scanning the filesystem
│       │   │   ├── RunnerProxyConfig.swift  — proxy configuration value type (moved to Core, #1300)
│       │   │   ├── RunnerState.swift        — observable read model populated by RunnerPoller
│       │   │   ├── RunnerStatus.swift       — typed representation of the GitHub API runner status field
│       │   │   └── WorkflowActionGroup.swift — workflow run group + type-safe GroupStatus
│       │   ├── Polling/
│       │   │   ├── IndexedScopedRunner.swift — immutable (scope, runner) carrier for two-phase fetch+enrich pipeline
│       │   │   ├── ObservationRelay.swift   — bridges RunnerPoller actor state to @Observable for SwiftUI
│       │   │   ├── PollLoopCoordinator.swift — owns the three Task handles driving RunnerPoller's poll loop
│       │   │   ├── PollResultBuilder.swift  — builds poll-cycle state; group/job state dependencies
│       │   │   ├── PollResults.swift        — value types carrying poll-cycle results (incl. JobPollResult)
│       │   │   ├── RunnerPoller.swift       — core poll-loop actor (renamed from RunnerStore, Step 10)
│       │   │   ├── RunnerPoller+ApplyResult.swift — applies enriched poll results back to RunnerPoller state
│       │   │   ├── RunnerPoller+Backfill.swift — backfill logic for runners missing from a poll cycle
│       │   │   ├── RunnerPoller+BackfillHelpers.swift — helper functions for the backfill extension
│       │   │   ├── RunnerPoller+FetchAndEnrich.swift — two-phase concurrent fetch + metrics-enrich pipeline
│       │   │   ├── RunnerPoller+InstallPathMap.swift — InstallPathMap lookups for runner enrichment
│       │   │   ├── RunnerPoller+PollBridge.swift — RunnerPoller poll-bridge extension (Step 10)
│       │   │   ├── RunnerPollerConformances.swift — protocol conformances for RunnerPoller deps (#1618)
│       │   │   ├── RunnerPollerObservers.swift — @MainActor observer wiring for RunnerPoller
│       │   │   └── RunnerPollerProtocol.swift — minimal interface for the GitHub poll-loop actor
│       │   ├── Protocols/
│       │   │   └── RunnerViewModelProtocol.swift — push-receiver interface for LocalRunnerStore updates
│       │   ├── Services/
│       │   │   ├── DefaultRunnerLabelsService.swift — live RunnerLabelsService delegating to patchRunnerLabels
│       │   │   ├── RunnerLabelsServiceProtocol.swift — runner labels service protocol (Phase 5, #1287/#1300)
│       │   │   ├── RunnerLifecycleService.swift — manages macOS launchctl runner lifecycle
│       │   │   ├── RunnerLifecycleServiceProtocol.swift — abstraction over launchctl start/stop/remove
│       │   │   ├── RunnerModelParser.swift  — reads installPath/.runner JSON and builds a RunnerModel
│       │   │   ├── RunnerStatusEnricher.swift — enriches RunnerModels with GitHub API status/labels/group
│       │   │   ├── RunnerStatusEnricherProtocol.swift — enricher protocol (Phase 6b, #1287/#1326)
│       │   │   ├── WorkflowActionGroupFetch.swift — WorkflowActionGroupFetcher + PR-number regex
│       │   │   └── WorkflowActionGroupFetcherProtocol.swift — fetcher protocol for existential storage
│       │   ├── Stores/
│       │   │   ├── LocalRunnerIndex.swift   — owns the UserDefaults name → install-path index
│       │   │   ├── LocalRunnerStore.swift   — actor owning the list of locally-installed runner agents
│       │   │   ├── RunnerConfigStore.swift  — reads/writes the .runner config file; RunnerConfigStoreError
│       │   │   ├── RunnerConfigStoreProtocol.swift — config-store protocol (Phase 5, #1287/#1300)
│       │   │   ├── RunnerProxyStore.swift   — actor owning all disk I/O for proxy config files
│       │   │   ├── RunnerProxyStoreError.swift — errors thrown while writing proxy config files
│       │   │   └── RunnerProxyStoreProtocol.swift — proxy-store protocol (Phase 5, #1287/#1300)
│       │   └── UseCases/
│       │       └── SaveRunnerEditsUseCase.swift — saves runner edits; LabelsPrerequisiteError (Phase 5, #1300)
│       │
│       ├── Scope/
│       │   ├── ScopeEntry.swift             — a single watched scope (repo/org) with enable/disable flag
│       │   ├── ScopePreferences.swift       — Codable snapshot of all per-scope user preferences
│       │   ├── ScopePreferencesStore.swift  — actor owning UserDefaults I/O for per-scope preferences
│       │   ├── ScopeStore.swift             — @MainActor store persisting the list of watched scopes
│       │   └── ScopeStoreProtocol.swift     — abstracts the active-scopes store for test doubles
│       │
│       ├── Services/
│       │   ├── LogFetcher.swift             — downloads and unzips GitHub Actions logs
│       │   ├── LoginItem.swift              — manages launch-at-login registration via SMAppService
│       │   ├── ProcessRunner.swift          — primitive for launching subprocesses with streaming output
│       │   └── TerminalLauncher.swift       — opens Terminal.app and runs a command via AppleScript
│       │
│       ├── State/
│       │   ├── NavState.swift               — navigation state enum
│       │   ├── PanelSheetState.swift        — process-lifetime sheet state owned by AppDelegate
│       │   └── PanelVisibilityState.swift   — panel visibility state (side-jump regression guard, #375-377)
│       │
│       ├── UseCases/
│       │   └── WorkflowActionsUseCase.swift — encapsulates all mutating workflow/job actions
│       │
│       └── Utilities/
│           ├── AnyJSON.swift                — type-erased Codable JSON value (no JSONSerialization)
│           ├── FormatElapsed.swift          — human-readable mm:ss elapsed-duration formatter
│           ├── ISO8601DateParser.swift      — shared actor-isolated ISO-8601 date parser
│           ├── Logger.swift                 — unified logging helpers (log() free function + LogCategory)
│           ├── ObservationLoop.swift        — re-registering withObservationTracking onChange wrapper
│           ├── RunBotLogger.swift           — GitHubLogger conformance; bridges GitHubClient log calls to log()
│           └── SystemStats.swift            — snapshot of CPU and memory metrics
│
└── Tests/
    ├── RunBotCoreTests/
    │   ├── APICallCounter+TestSeam.swift    — test-only seeding/reset extensions on APICallCounter
    │   ├── APICallCounterTests.swift        — unit tests for APICallCounter and its snapshot
    │   ├── ActiveJobAsCompletedTests.swift  — tests for ActiveJob.asCompleted(at:)
    │   ├── FailureHookRunnerUseCaseTests.swift — unit tests for FailureHookRunnerUseCase
    │   ├── GitHubRateLimitActorTests.swift  — rate-limit actor generation-guard/race tests
    │   ├── GitHubTokenCacheTests.swift      — token-cache tests (with isolation requirement)
    │   ├── GitHubTransportPaginatedTests.swift — integration tests for GitHubTransport.apiPaginated
    │   ├── GitHubTransportShimTests.swift   — tests for the module-level transport configure/read shims
    │   ├── LocalRunnerIndexTests.swift      — unit tests for LocalRunnerIndex
    │   ├── LogFetcherTests.swift            — unit tests for LogFetcher
    │   ├── ObservationLoopTests.swift       — unit tests for ObservationLoop invariants
    │   ├── OrgRunnerMetricsResolutionTests.swift — regression tests for org-scoped runner metrics (#1209/#1192)
    │   ├── RunBotCoreTests.swift         — top-level RunBotCore test suite
│   │   ├── SaveRunnerEditsUseCaseTests.swift — unit tests for SaveRunnerEditsUseCase (Phase 5, #1300)
    │   ├── ScopeEditSheetTests.swift        — atomic-save contract tests for the ScopeEditSheet rewrite (#1540)
    │   ├── StepLogViewScopeResolutionTests.swift — tests for StepLogView.loadLog() scope resolution (#1517)
    │   ├── WorkflowActionGroupFetcherTests.swift — unit tests for WorkflowActionGroupFetcher
    │   └── TestSupport/
    │       ├── TestDoubles.swift            — shared test doubles (#1447)
    │       └── TestFixtures.swift           — shared test fixtures (#1446)
    └── RunBotUITests/
        └── RunBotUITests.swift           — UI tests using real mouse interaction; run via xcodebuild on the self-hosted runner
```
