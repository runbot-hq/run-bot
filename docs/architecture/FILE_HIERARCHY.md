# 📁 File Hierarchy

A short description of every source file in the project.

---

```
run-bot/
├── Package.swift                            — SPM manifest; defines RunnerBar + RunnerBarCore targets and pulls in GitHubClient + AppUpdater as remote packages
├── project.yml                              — XcodeGen project definition
├── build.sh                                 — local build helper script
├── deploy.sh                                — deployment/release helper script
├── install.sh                               — runner installation helper script
├── README.md                                — project overview, screenshots, setup instructions
├── sonar-project.properties                 — SonarCloud project configuration
├── .swiftlint.yml                           — SwiftLint rule configuration
├── .periphery.yml                           — Periphery dead-code scanner configuration
│
├── docs/
│   ├── popover.md                           — notes on NSPopover usage and behaviour
│   ├── architecture/
│   │   ├── AGENTS.md                        — AI agent usage guidelines for this codebase
│   │   ├── ARCHITECTURE.md                  — high-level architecture overview
│   │   └── FILE_HIERARCHY.md                — this file; annotated map of the codebase
│   ├── design/
│   │   ├── brand-inspiration_developer-tools_2026-06-02.md — brand/design inspiration notes
│   │   ├── dark_light_mode_support.md       — notes on dark/light mode adaptive design
│   │   └── liquid-glass.md                  — liquid-glass visual design exploration
│   ├── guides/
│   │   ├── DEPLOYMENT.md                    — release and deployment instructions
│   │   ├── DEVELOPMENT.md                   — local development setup and workflow
│   │   ├── UI_TESTING.md                    — UI testing approach and instructions
│   │   ├── commenting-standard.md           — code commenting conventions for the project
│   │   └── dev-with-log-in-terminal.md      — how to run the app with live log output in Terminal
│   ├── legal-and-security/
│   │   ├── GitHub-Permission-Rationale.md   — justification for requested GitHub OAuth scopes
│   │   └── PRIVACY.md                       — privacy policy and data-handling notes
│   └── ui/
│       ├── nspopoer-without-jump-issues.md  — fix notes for NSPopover repositioning jumps
│       ├── status-bar-app-position-warning.md — notes on status-bar icon positioning edge cases
│       └── status-bar-window.md             — status-bar window construction notes
│
├── Sources/
│   │
│   ├── RunnerBarCore/                       (pure-logic target — no UI dependencies)
│   │   │
│   │   ├── GitHub/
│   │   │   ├── GitHubConstants.swift      — shared GitHub API base URLs and endpoint path constants
│   │   │   └── GitHubTransportShim.swift  — thin shim that routes requests through the active transport; holds the global ghRawTransport reference and a serial lock to guard replacement
│   │   │
│   │   ├── Runner/
│   │   │   ├── ActiveJob.swift            — model for a currently-running workflow job (name, status, started-at, URL)
│   │   │   ├── AggregateStatus.swift      — derives a single roll-up status from a collection of runner statuses
│   │   │   ├── JobStatus.swift            — enum of all possible GitHub Actions job states (queued, in_progress, completed, etc.)
│   │   │   ├── PollResultBuilder.swift    — assembles a PollResults value from raw API responses; handles vanished-job detection and failure-hook guard
│   │   │   ├── PollResults.swift          — value type carrying the full result of one poll cycle (runners + aggregate status)
│   │   │   ├── Runner.swift               — core Runner value type (id, name, OS, status, active jobs)
│   │   │   ├── RunnerMetrics.swift        — lightweight CPU/memory snapshot attached to a runner
│   │   │   ├── RunnerModel.swift          — Codable DTO that maps the GitHub REST runner JSON payload
│   │   │   ├── RunnerStatus.swift         — enum of runner lifecycle states (idle, active, offline, unknown)
│   │   │   ├── RunnerStatusEnricher.swift — merges live job data into a runner to produce an enriched status
│   │   │   ├── WorkflowActionGroup.swift  — groups related workflow runs under a single repo/branch key; exposes derived display props and elapsed time
│   │   │   └── WorkflowActionGroupFetch.swift — fetches and maps jobs for a WorkflowActionGroup from the GitHub API
│   │   │
│   │   ├── Scope/
│   │   │   ├── ScopeEntry.swift           — immutable value representing one monitored scope (org, repo, or user) with its enabled flag
│   │   │   └── ScopePreferencesStore.swift — reads and writes the list of ScopeEntry values to UserDefaults
│   │   │
│   │   ├── Services/
│   │   │   ├── LogFetcher.swift           — fetches raw workflow step log text from the GitHub API
│   │   │   └── ProcessRunner.swift        — runs a shell process and captures stdout/stderr
│   │   │
│   │   └── Utilities/
│   │       ├── ISO8601DateParser.swift    — fast ISO-8601 date parser used across the model layer
│   │       ├── Logger.swift               — os.Logger wrapper; category-scoped logging for RunnerBarCore
│   │       └── SystemStats.swift          — reads live CPU and disk usage via host_statistics / statvfs
│   │
│   └── RunnerBar/                           (UI target — AppKit + SwiftUI, macOS menu-bar app)
│       │
│       ├── main.swift                     — entry point; calls NSApplicationMain to launch the AppKit run loop
│       ├── Exports.swift                  — re-exports RunnerBarCore so UI code needs only one import
│       │
│       ├── App/
│       │   ├── AppDelegate.swift          — NSApplicationDelegate; owns lifecycle, sets up popover, triggers teardown
│       │   ├── AppDelegate+Navigation.swift — navigation helpers on AppDelegate (push/pop views, stepLog call-site)
│       │   ├── AppDelegate+OAuthCallback.swift — handles the OAuth redirect callback and exchanges the code for a token
│       │   ├── AppDelegate+PanelSetup.swift — configures the NSPopover and subscribes to close/open notifications
│       │   ├── AppDelegate+Polling.swift  — wires up the poll loop start/stop on panel open/close events
│       │   ├── AppDelegate+StatusItem.swift — creates the NSStatusItem and manages its menu-bar icon with triple-fallback
│       │   ├── AppDelegate+StoreSetup.swift — initialises and wires observable stores on launch
│       │   ├── NavState.swift             — observable navigation stack (history array, stepLog labels)
│       │   ├── PanelSheetState.swift      — tracks which sheet (if any) is currently presented in the panel
│       │   └── PanelVisibilityState.swift — publishes whether the popover panel is currently visible
│       │
│       ├── DesignSystem/
│       │   ├── DesignTokens.swift         — colour, spacing, and typography constants; adaptive() helper for light/dark
│       │   ├── PanelViewModifiers.swift   — reusable SwiftUI ViewModifiers (glass button style, panel-level padding, etc.)
│       │   └── RemovalAlertModifier.swift — ViewModifier that presents the runner-removal confirmation alert
│       │
│       ├── GitHub/
│       │   ├── Auth.swift                 — GitHub OAuth token cache; reads from Keychain
│       │   ├── GitHub.swift               — top-level GitHub API facade (fetch step log, raw URL session wrapper)
│       │   ├── GitHubRateLimitHandler.swift — centralised rate-limit state machine; surfaces banner when limit is hit
│       │   ├── GitHubRequestBuilder.swift — constructs authenticated URLRequests for the GitHub REST API
│       │   ├── GitHubResponseDecoder.swift — decodes and validates GitHub API JSON responses; surfaces typed errors
│       │   ├── GitHubURLSessionTransport.swift — URLSession-based REST transport; handles 401 sentinel, rate-limit atomicity, per-iteration token re-fetch
│       │   ├── Keychain.swift             — thin Keychain wrapper for storing/retrieving the OAuth token
│       │   ├── OAuthService.swift         — drives the GitHub OAuth Authorization Code flow (sign-in URL, code exchange, CSRF check, callback handling)
│       │   ├── Scope.swift                — enum with .repo(owner:name:) and .org(_:) cases; parses raw scope strings and produces the correct GitHub REST API path prefix
│       │   └── Secrets.swift             — holds the GitHub App client-id and client-secret constants
│       │
│       ├── Models/
│       │   ├── RunnerEditCommit.swift     — immutable snapshot of runner edits ready to be committed to the API
│       │   └── RunnerEditDraft.swift      — mutable draft state for in-progress runner edits in the UI
│       │
│       ├── Panel/
│       │   └── PanelChrome.swift          — applies window-level chrome (vibrancy, corner radius) to the panel
│       │
│       ├── Preferences/
│       │   ├── AppPreferencesStore.swift  — registers and persists app-level user preferences (launch-at-login, notification settings, etc.)
│       │   └── NotificationPreferences.swift — model + persistence for per-event notification opt-in preferences
│       │
│       ├── Runner/
│       │   ├── LocalRunnerIndex.swift     — persistent index mapping runner names to their install paths on disk
│       │   ├── LocalRunnerStore.swift     — @MainActor observable store of locally-registered runners; drives refresh and optimistic restore
│       │   ├── RunnerLifecycleService.swift — start/stop/remove lifecycle operations for a runner
│       │   ├── RunnerModelParser.swift    — parses raw GitHub API runner JSON into typed Runner values
│       │   ├── RunnerPollState.swift      — tracks the current polling phase and surfaces main.sync deadlock warnings
│       │   ├── RunnerStore+InstallPathMap.swift — extension mapping runner IDs to their local install paths
│       │   ├── RunnerStore+PollLoop.swift — extension containing the async poll-loop driver on RunnerStore
│       │   ├── RunnerStore.swift          — observable store that owns the authoritative list of Runner values for the UI
│       │   └── RunnerViewModel.swift      — @MainActor view-model bridging RunnerStore to SwiftUI; DI seam for testing
│       │
│       ├── Scope/
│       │   ├── ScopeDetailView.swift      — detail view for an individual monitored scope
│       │   ├── ScopeEntry.swift           — UI-layer scope entry model
│       │   └── ScopeStore.swift           — @MainActor observable store managing the list of monitored scopes
│       │
│       ├── Services/
│       │   ├── FailureHookRunner.swift    — executes the user-configured shell command on runner failure
│       │   ├── LoginItem.swift            — registers/deregisters the app as a login item via SMAppService
│       │   └── TerminalLauncher.swift     — opens a Terminal window and runs a given command string
│       │
│       ├── Utilities/
│       │   └── WindowGrabber.swift        — utility for obtaining the NSWindow reference from a SwiftUI scene
│       │
│       └── Views/
│           ├── Components/
│           │   ├── DonutStatusView.swift      — circular donut chart showing aggregate runner status
│           │   ├── SparklineView.swift        — mini sparkline graph for metrics history
│           │   ├── SystemStatsView.swift      — header stats display (CPU, memory)
│           │   ├── SystemStatsViewModel.swift — view-model feeding live system stats into SystemStatsView
│           │   └── WorkflowContextMenuModifier.swift — context-menu modifier for workflow action rows
│           ├── Main/
│           │   ├── ActionRowView.swift        — row view for a single workflow action entry
│           │   ├── InlineJobRowsView.swift    — renders the inline expandable job-step rows inside a runner row
│           │   ├── PanelContainerView.swift   — top-level NSViewRepresentable that hosts the SwiftUI panel inside the NSPopover
│           │   ├── PanelHeaderView.swift      — header bar of the panel showing app title, system stats, and settings button
│           │   ├── PanelMainView.swift        — root SwiftUI view of the popover panel; owns polling start and rate-limit banner
│           │   ├── PanelMainView+Subviews.swift — subview decomposition of PanelMainView (row containers, branch/tag pills, etc.)
│           │   ├── RunnerRowViews.swift       — SwiftUI views for rendering individual runner rows in the panel list
│           │   └── WorkflowProgressExtensions.swift — SwiftUI extensions for mapping workflow status to progress-indicator state
│           ├── Settings/
│           │   ├── AddRunnerSheet.swift       — sheet for registering a new self-hosted runner (token fetch, timeout, keyWindow handling)
│           │   ├── AddRunnerSheet+FormFields.swift — form field subviews for AddRunnerSheet (name, URL, labels)
│           │   ├── AddRunnerSheet+TokenSection.swift — token-fetch section of the AddRunnerSheet
│           │   ├── AddRunnerSheet+Validation.swift — input validation logic for AddRunnerSheet
│           │   ├── AddScopeSheet.swift        — sheet for adding a new monitored scope (org/repo/user picker, manual entry)
│           │   ├── FailureHookCommandSheet.swift — sheet for editing the failure-hook shell command and inserting variables
│           │   ├── LocalRunnersView.swift     — settings sub-view listing locally installed self-hosted runners
│           │   ├── RunnerDetailSheet.swift    — sheet showing runner metadata and a copy-to-pasteboard token action
│           │   ├── ScopesView.swift           — settings sub-view for managing monitored scopes
│           │   ├── SettingsView.swift         — main Settings tab view (login, notifications, scopes, runners, failure hook)
│           │   └── SettingsView+Sections.swift — section decomposition helpers for SettingsView
│           ├── Sheets/
│           │   ├── BranchSelectorSheet.swift  — sheet for picking a branch filter for a runner scope
│           │   └── RepoSelectorSheet.swift    — sheet for selecting a repository within the current scope
│           └── StepLog/
│               ├── LogCopyButton.swift        — button that copies the current step log to the clipboard with visual feedback
│               └── StepLogView.swift          — full-screen log viewer for a workflow step; fetches, parses, and displays raw log text
│
└── Tests/
    ├── RunnerBarCoreTests/
    │   ├── OrgRunnerMetricsResolutionTests.swift — tests for org-level runner metrics resolution logic
    │   └── RunnerBarCoreTests.swift         — unit tests for RunnerBarCore models and logic
    └── RunnerBarUITests/
        └── RunnerBarUITests.swift           — UI test suite for RunnerBar
```
