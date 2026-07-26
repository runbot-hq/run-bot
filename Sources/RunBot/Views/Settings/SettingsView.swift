// SettingsView.swift
// RunBot

import AppKit
import AppUpdater
import GitHubClient
import RunBotCore
import ServiceManagement
import SwiftUI

// MARK: - SettingsView

// Settings view — complete implementation for all phases 1-6.
//
// HEIGHT CONTRACT:
// headerBar is OUTSIDE the ScrollView — back button always visible.
// ScrollView uses maxHeight: .infinity to fill all remaining panel space.
// AppDelegate.resizeAndRepositionPanel() clamps the panel at 85% visibleFrame
// via MBK's maxHeight in clamp(). That IS the hard ceiling.
// settingsBody uses .fixedSize(horizontal: false, vertical: true) so MBK's
// GeometryReader reports SettingsView's own natural height, not the main panel's.
// sectionsStack (scroll content) uses .fixedSize(horizontal: false, vertical: true)
// so the ScrollView knows the full content height before applying the maxHeight cap.
// No extra cap needed here — the MBK clamp IS the scroll boundary.
// ❌ NEVER move headerBar inside the ScrollView.
// ❌ NEVER replace .infinity with a fixed number.
// ❌ NEVER use GeometryReader for the height.
// ❌ NEVER add idealHeight to the root frame.
// ❌ NEVER remove .fixedSize(horizontal: false, vertical: true) from settingsBody.
// ❌ NEVER remove .fixedSize(horizontal: false, vertical: true) from sectionsStack.
//
// WIDTH CONTRACT:
// settingsBody uses .frame(width: 480) — a HARD fixed width.
// idealWidth is only a preference and is overridden by the panel's offered width
// when navigating from PanelMainView (~650pt). .frame(width: 480) ignores the
// offered width entirely and forces Settings to always be 480pt.
// ❌ NEVER use .frame(idealWidth: 480, maxWidth: .infinity) — idealWidth is ignored
//    when the parent offers a larger width (inherits main panel width regression).
// ❌ NEVER use .fixedSize() (both axes) — Settings content natural width >> 480pt.
// ❌ NEVER remove the width: 480 — Settings will inherit the main panel width.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

// ACCESS LEVEL NOTE — why so many `var` instead of `private var`:
// Swift `private` is file-scoped. SettingsView is split across multiple files
// (SettingsView.swift, SettingsView+Sections.swift, etc.). Any property or
// method that an extension file reads or writes MUST be `internal` (the default
// `var`) — `private` and `fileprivate` both restrict to the declaring file only.
// Properties that are ONLY used inside this file (SettingsView.swift) are
// `private var` as normal. The split is intentional — not a visibility leak.
// ❌ Do NOT tighten `var` to `private var` without checking SettingsView+Sections.swift
//    first — the compiler will reject it there.

/// Root settings view. Navigation rows lead to `LocalRunnersView` and `ScopesView`.
/// See HEIGHT/WIDTH CONTRACT comments above before making layout changes.
///
/// No `onRestartPolling` callback is needed — all `ScopeStore` mutations are
/// observed by `RunnerPoller`'s `withObservationTracking` loop automatically.
struct SettingsView: View {

    // MARK: - Inputs

    /// Callback invoked when the user taps the back button.
    let onBack: () -> Void

    /// The local runner actor forwarded into `LocalRunnersView`.
    ///
    /// WHY THIS EXISTS AS A STORED PROPERTY:
    /// `LocalRunnersView` is a subview that does not have `@Environment(AppState.self)`
    /// in scope — it receives `localRunnerStore` as a direct parameter. `SettingsView`
    /// acts as the handoff point, extracting the store from `appState.localRunnerStore`
    /// and passing it down. This computed property is that handoff slot.
    ///
    /// WHY THIS IS COMPUTED (not a stored `var`):
    /// Resolving `appState.localRunnerStore` eagerly in `init` — even via `??` — calls
    /// the computed getter on `AppState`, which `fatalError`s if `start()` hasn't seeded
    /// `_localRunnerStore` yet. That makes any Preview or test that constructs
    /// `SettingsView(appState: AppState())` without calling `start()` crash in init,
    /// violating the zero-cost-init promise documented on `AppState`.
    ///
    /// The fix: store only the optional override in `_localRunnerStoreOverride` (set once
    /// in init, never triggers the getter), and resolve lazily via this computed property
    /// at render time — when `start()` is guaranteed to have run in production.
    ///
    /// For tests/Previews that need a specific store: pass it explicitly as
    /// `localRunnerStore:` in the init — it is stored in `_localRunnerStoreOverride`
    /// and returned here without ever touching `appState.localRunnerStore`.
    ///
    /// ⚠️ Do NOT convert this back to a stored `var` with an eager init-time resolution —
    /// that re-introduces the fatalError trip-wire described above.
    private var localRunnerStore: LocalRunnerStore {
        _localRunnerStoreOverride ?? appState.localRunnerStore
    }

    /// Backing slot for the `localRunnerStore` computed property.
    /// `nil` in production (resolved from `appState` at render time).
    /// Set explicitly in tests/Previews via `init(localRunnerStore:)`.
    private var _localRunnerStoreOverride: LocalRunnerStore?

    // MARK: - Injected services

    /// Single coordinator for all domain-level state (oauth, lifecycle, runners, updater).
    /// Replaces four separate injected objects — see issue #2040.
    /// `AppState` has no singleton — the single instance is owned by `AppDelegate`
    /// and must be supplied explicitly by the caller. There is no safe default.
    let appState: AppState

    /// App-wide preference store (polling interval, popover arrow, beta channel, etc.).
    ///
    /// FIX #2174: was `let` — `Bindable(settings)` constructed inside a computed-var body
    /// creates a transient wrapper whose write is silently discarded at end of body
    /// evaluation, so the backing store is never mutated and `onChange` never fires.
    /// `@Bindable var` makes SwiftUI track the reference stably across render cycles and
    /// lets us use `$settings.betaChannel` / `$settings.showPopoverArrow` directly.
    @Bindable var settings: AppPreferencesStore

    /// Notification preference store (notify-on-success, notify-on-failure).
    ///
    /// FIX #2174: same `let` → `@Bindable var` fix as `settings` above.
    /// `generalSection` previously used `Bindable(notifications)` in a computed var,
    /// which had the same silent-drop problem. Now uses `$notifications.notificationMode`.
    @Bindable var notifications: NotificationPreferences

    /// Scope store — injected so SwiftUI can track `@Observable` mutations reactively.
    ///
    /// `let` not `@Bindable`: no two-way bindings into `scopeStore` are needed from this
    /// file — mutations happen inside `ScopesView` which receives the store directly.
    /// `@Bindable` would be misleading here since nothing uses `$scopeStore.*`.
    /// If a binding is ever needed, convert to `@Bindable var`.
    ///
    /// Injected rather than read from `appState` because `AppState` does not expose
    /// a `scopeStore` accessor — scopes are managed independently of runner state.
    /// Runners flow through `AppState.runnerState` (owned by `LocalRunnerStore`);
    /// scopes have no equivalent path, so direct injection is the only option.
    let scopeStore: ScopeStore

    // MARK: - Convenience accessors (avoid noisy appState.x at every call site)
    // These are `internal` (bare `var`) by Swift necessity — see ACCESS LEVEL NOTE
    // at the top of this file. `private` would break SettingsView+Sections.swift.

    /// Forwarded OAuth service from `appState`. Internal by necessity — see ACCESS LEVEL NOTE.
    var oauthService: any OAuthServiceProtocol { appState.oauthService }
    /// Forwarded lifecycle service from `appState`. Internal by necessity — see ACCESS LEVEL NOTE.
    var lifecycleService: any RunnerLifecycleServiceProtocol { appState.lifecycleService }
    /// Forwarded runner state from `appState`. Internal by necessity — see ACCESS LEVEL NOTE.
    var runnerState: RunnerState { appState.runnerState }
    /// Forwarded auto-updater from `appState`. Internal by necessity — see ACCESS LEVEL NOTE.
    var autoUpdater: AppUpdater { appState.autoUpdater }

    // MARK: - Computed properties

    /// Full version string (preserves pre-release suffixes like `-beta.1`).
    /// Internal by necessity — read by `SettingsView+Sections.swift`. See ACCESS LEVEL NOTE.
    var appVersion: String { Bundle.main.rbVersionString }

    /// Build number from `CFBundleVersion`.
    /// Internal by necessity — read by `SettingsView+Sections.swift`. See ACCESS LEVEL NOTE.
    var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }

    // MARK: - Local UI state
    //
    // Access level split — why some are `private` and others are not:
    //   `private`  — signInTask, signOutTask: only ever touched inside THIS file
    //               (onAppearAction spawns them, onDisappear cancels them).
    //               No extension file reads or writes these — private is correct.
    //   `internal` — everything else: read or written by SettingsView+Sections.swift
    //               (e.g. section views read isOAuthAuthenticated, isSigningIn,
    //               launchAtLogin; navigation sections toggle showLocalRunners/showScopes).
    //               Must be internal — see ACCESS LEVEL NOTE at top of file.

    /// Mirrors `LoginItem.isEnabled`; toggled by the Launch at Login switch.
    /// Internal by necessity — read/written by `SettingsView+Sections.swift`. See ACCESS LEVEL NOTE.
    @State var launchAtLogin = LoginItem.isEnabled

    /// `true` when a valid OAuth token is stored in the keychain.
    /// Seeded from `oauthService.isAuthenticated` in `init` to avoid a false flash
    /// before `.onAppear` fires. Kept in sync by `onAppearAction()`'s streams.
    /// Internal by necessity — read by `SettingsView+Sections.swift`. See ACCESS LEVEL NOTE.
    @State var isOAuthAuthenticated: Bool

    /// `true` when a CLI token (GH_TOKEN / GITHUB_TOKEN) is present but no OAuth token.
    /// Seeded from `oauthService` in `init` to avoid a false flash before `.onAppear`.
    /// Written twice per appear: once synchronously by onAppearAction() as a fast-path
    /// seed, and once asynchronously by Task 1 as the authoritative resolved value.
    /// See Task 1 comment in body for the write-ordering details and known rapid-reopen gap.
    /// Internal by necessity — read by `SettingsView+Sections.swift`. See ACCESS LEVEL NOTE.
    @State var isCLIAuthenticated: Bool

    /// `true` while the OAuth sign-in flow is in progress.
    /// Internal by necessity — read by `SettingsView+Sections.swift` (sign-in button state).
    /// See ACCESS LEVEL NOTE.
    @State var isSigningIn = false

    /// Retains the sign-in listener Task so it can be cancelled on disappear.
    /// `private` — only touched inside this file (onAppearAction / onDisappear).
    /// No extension file accesses this. See LOCAL UI STATE access-level split above.
    @State private var signInTask: Task<Void, Never>?

    /// Retains the sign-out listener Task so it can be cancelled on disappear.
    /// `private` — only touched inside this file (onAppearAction / onDisappear).
    /// No extension file accesses this. See LOCAL UI STATE access-level split above.
    @State private var signOutTask: Task<Void, Never>?

    /// `true` while `LocalRunnersView` is displayed instead of the main settings scroll.
    /// Internal by necessity — toggled by `SettingsView+Sections.swift`. See ACCESS LEVEL NOTE.
    @State var showLocalRunners = false

    /// `true` while `ScopesView` is displayed instead of the main settings scroll.
    /// Internal by necessity — toggled by `SettingsView+Sections.swift`. See ACCESS LEVEL NOTE.
    @State var showScopes = false

    // MARK: - Init

    /// Creates the view with injected dependencies.
    ///
    /// `isOAuthAuthenticated` and `isCLIAuthenticated` are seeded synchronously from
    /// `oauthService` here rather than defaulting to `false` and correcting in
    /// `.onAppear`. Both properties are backed by a synchronous Keychain read, so
    /// the cost is identical and the one-render false-flash is eliminated.
    ///
    /// `localRunnerStore` is stored as an optional override and resolved lazily in the
    /// `localRunnerStore` computed property at render time. This avoids calling
    /// `appState.localRunnerStore` during init, which would fatalError if `start()`
    /// hasn't been called yet (violating AppState's zero-cost-init promise).
    ///
    /// - Parameters:
    ///   - appState: The single domain coordinator owned by `AppDelegate`.
    ///   - localRunnerStore: Optional store override for tests/Previews. When `nil`
    ///     (the default), resolved lazily from `appState.localRunnerStore` at render time.
    init(
        onBack: @escaping () -> Void,
        appState: AppState,
        localRunnerStore: LocalRunnerStore? = nil,
        settings: AppPreferencesStore = .shared,
        notifications: NotificationPreferences = .shared,
        scopeStore: ScopeStore = .shared
    ) {
        self.onBack = onBack
        self.appState = appState
        self._localRunnerStoreOverride = localRunnerStore
        // @Bindable var — assign via _settings/_notifications wrappers
        self._settings = Bindable(settings)
        self._notifications = Bindable(notifications)
        self.scopeStore = scopeStore
        _isOAuthAuthenticated = State(initialValue: appState.oauthService.isAuthenticated)
        _isCLIAuthenticated = State(initialValue: !appState.oauthService.isAuthenticated && appState.oauthService.hasAnyToken)
        log("【SettingsView.init】settings=\(ObjectIdentifier(settings)) betaChannel=\(settings.betaChannel)", category: .general)
        log("【SettingsView.init】notifications=\(ObjectIdentifier(notifications))", category: .general)
    }

    // MARK: - Body

    /// Root view: swaps between the settings scroll, `LocalRunnersView`, and `ScopesView`.
    ///
    /// The `log()` call at the top of body is intentional — it is a pure side-effect-free
    /// diagnostic that does not mutate state and does not affect the view tree. SwiftUI
    /// may call body multiple times; the log helps trace unexpected re-render frequency
    /// in debug builds. It is not a state mutation and does not violate SwiftUI's
    /// no-side-effects-in-body rule (which targets state writes, not logging).
    var body: some View {
        log("【SettingsView.body】rendered — settings=\(ObjectIdentifier(settings)) betaChannel=\(settings.betaChannel)", category: .general)
        // Lifecycle modifiers live on the root Group (wrapping all branches) so
        // onAppearAction()/onDisappear fire only when the settings panel itself
        // opens/closes — NOT on every navigation to LocalRunnersView/ScopesView.
        // Attaching them to `settingsBody` caused needless re-reads and Task
        // recreation on every back-navigation. The Group has no layout impact —
        // it is a transparent modifier container, not a VStack/HStack.
        // ❌ Do NOT replace the root Group with a VStack/HStack — Group is transparent;
        //    a layout container would change the view's layout identity and affect
        //    the modifier-firing semantics described above.
        return Group {
            if showLocalRunners {
                LocalRunnersView(
                    onBack: { showLocalRunners = false },
                    isAuthenticated: isOAuthAuthenticated || isCLIAuthenticated,
                    localRunnerStore: localRunnerStore,
                    lifecycleService: lifecycleService
                )
            } else if showScopes {
                ScopesView(onBack: { showScopes = false }, oauthService: oauthService)
            } else {
                settingsBody
            }
        }
        .onAppear(perform: onAppearAction)
        // TASK 1 of 2 — CLI token resolution.
        // Resolves isCLIAuthenticated via the login-shell fallback for Finder-launched
        // apps where env vars are absent from the process environment.
        //
        // THIS TASK IS INTENTIONALLY INDEPENDENT of task 2 below.
        // SwiftUI runs multiple .task modifiers concurrently with no ordering guarantee.
        // Task 2 (update check) reads runnerState from appState by value at call time
        // and has NO dependency on isCLIAuthenticated or the result of this task.
        // ❌ Do NOT merge these two tasks to "add ordering" unless checkAndHandle is
        //    changed to require auth state — if that ever changes, sequence them
        //    explicitly inside a single .task instead of relying on chaining order.
        //
        // isCLIAuthenticated write ordering (pre-existing, not introduced here):
        // onAppearAction() writes isCLIAuthenticated synchronously from
        // oauthService.hasAnyToken as a fast-path best-effort seed — it is cheap
        // and keeps the UI correct for the common case without waiting for the network.
        // This task then overwrites it once github.token() resolves asynchronously
        // as the authoritative value (covers Finder-launch env var absence).
        //
        // Known gap — rapid open→open cycle:
        // On a rapid open→open (panel re-shown without onDisappear), onAppearAction()
        // re-runs and resets isCLIAuthenticated to the sync seed value. However,
        // SwiftUI does NOT re-fire .task unless view identity changes or the view
        // fully disappears/reappears — so the async authoritative overwrite does
        // not run again. isCLIAuthenticated stays at the sync seed on that cycle.
        // This is pre-existing behaviour; not introduced by this PR. In practice
        // the sync seed (oauthService.hasAnyToken) is correct for most users and
        // the gap only affects Finder-launched apps with shell-only env var tokens.
        .task {
            // Guard: skip if the user is already signed in via OAuth — in that
            // case neither status text nor the green dot reference `isCLIAuthenticated`.
            guard !isOAuthAuthenticated else { return }
            let token = await appState.github.token()
            isCLIAuthenticated = token != nil
            log("【SettingsView.task1】github.token() resolved — isCLIAuthenticated=\(isCLIAuthenticated)", category: .general)
        }
        // TASK 2 of 2 — Update check (FIX #2223 / #2216).
        // Fires on every entry path — including cold-open → Settings, where
        // .onAppear on an NSPanel-hosted root Group is not guaranteed to fire.
        // SwiftUI owns the task lifetime: starts on appear, cancelled on disappear.
        //
        // INTENTIONALLY CONCURRENT with task 1 above — no ordering dependency.
        // checkAndHandle(state:) receives runnerState by value (computed property
        // returning appState.runnerState at call time). It does NOT read
        // isCLIAuthenticated and does NOT depend on task 1 completing first.
        // If that ever changes, sequence both calls inside a single .task.
        //
        // NSPanel teardown assumption (tracked in issue #2231):
        // .task reliability here depends on the NSPanel host fully deiniting the
        // SwiftUI view tree on close, which resets task identity so this task
        // relaunches on the next open. If the panel is ever changed to retain the
        // view tree across closes (partial teardown), .task and .onAppear would
        // be equally unreliable for the cold-open path and an .id() modifier to
        // force identity reset would be required instead. See #2231.
        //
        // Entry-path matrix:
        //   • Cold-open → Settings : .task fires ✅
        //   • Main → Settings nav  : .task fires ✅
        //   • Back-nav sub-views   : root Group does not re-appear → no extra check ✅
        //   • Settings closed mid-check: SwiftUI cancels automatically ✅
        //
        // Principle P9: structured concurrency — no manual Task or DispatchQueue.
        .task {
            await autoUpdater.checkAndHandle(state: runnerState)
        }
        .onDisappear {
            log("【SettingsView.onDisappear】cancelling signInTask/signOutTask", category: .general)
            // Cancel and unconditionally nil the sign-in task — the for-await loop
            // exits promptly on cancellation (AsyncStream respects task cancellation)
            // so isSigningIn will never flip back via the stream after this point.
            // Nilling here ensures a re-opened panel never shows a stale spinner.
            signInTask?.cancel()
            signInTask = nil
            signOutTask?.cancel()
            signOutTask = nil
            // Reset isSigningIn so a close-during-flow doesn't leave a stale spinner
            // on the next open. The stream task is already cancelled above, so the
            // for-await loop will not reset it — we must do it explicitly here.
            isSigningIn = false
        }
    }

    /// The main settings layout (header + sections scroll).
    ///
    /// Extracted from `body` so `LocalRunnersView` and `ScopesView` can replace it cleanly
    /// without any structural duplication.
    ///
    /// WIDTH CONTRACT: .frame(width: 480) — HARD fixed width. Always 480pt, never inherits
    /// the main panel's committed width. idealWidth is NOT used because it is only a
    /// preference and is overridden by the parent's offered width (~650pt from PanelMainView).
    /// HEIGHT CONTRACT: .fixedSize(horizontal: false, vertical: true) — Settings reports its
    /// own natural height to MBK's GeometryReader, NOT the main panel's offered height.
    /// ❌ NEVER move headerBar inside the ScrollView.
    /// ❌ NEVER use .frame(idealWidth:) — idealWidth is a preference, not a constraint.
    /// ❌ NEVER remove .frame(width: 480) — Settings will inherit main panel width.
    /// ❌ NEVER remove .fixedSize(horizontal: false, vertical: true) — height regression.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            ScrollView(.vertical, showsIndicators: true) {
                sectionsStack
            }
            .frame(maxHeight: .infinity)
        }
        // WIDTH: hard fixed at 480pt — never inherits the main panel's offered width.
        // ❌ NEVER change to .frame(idealWidth:) — that is a preference, not a constraint.
        .frame(width: 480)
        // HEIGHT: fixedSize(v:true) tells SwiftUI to use Settings' own natural height.
        // Without this, MBK's GeometryReader receives the offered height from the main
        // panel and Settings inherits the main panel's height instead of its own.
        // ❌ NEVER remove — height-inheritance regression.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Vertical stack of all settings sections.
    ///
    /// Order: Account → Management → General → About
    ///
    /// .fixedSize(horizontal: false, vertical: true) is LOAD-BEARING.
    /// Forces this VStack to report its natural height to the ScrollView in settingsBody
    /// so it knows the full content height before applying the maxHeight cap.
    /// ❌ NEVER remove this — ScrollView will not report correct content height.
    private var sectionsStack: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountSection
            Divider()
            managementSection
            Divider()
            generalSection
            Divider()
            aboutSection
        }
        // LOAD-BEARING — see sectionsStack doc comment above.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.bottom, 16)
    }

    /// Runs on `.onAppear`: re-syncs auth state from `oauthService` and starts sign-in /
    /// sign-out listeners.
    ///
    /// WHY auth state is re-seeded here even though init already seeds it:
    /// `init` seeds once at construction time. On a hide/show cycle the view is NOT
    /// reconstructed — the same instance reappears. onAppearAction re-syncs so the
    /// status light and sign-in button always reflect the live keychain state at the
    /// moment the panel becomes visible, not the state at first construction.
    /// This is not redundant — it is a deliberate re-read for the re-appear case.
    ///
    /// Update checking is intentionally NOT done here — it is owned by Task 2 of 2
    /// in body (.task modifier), which covers both cold-open and navigation paths
    /// (fix #2223). All tasks are cancelled before reassignment so a rapid open→open
    /// cycle cannot leak prior stream listeners.
    ///
    /// isCLIAuthenticated is written synchronously here as a fast-path seed.
    /// Task 1 in body overwrites it asynchronously with the authoritative value
    /// once github.token() resolves. On a rapid open→open cycle, Task 1 does not
    /// re-fire — see the Task 1 comment in body for the known gap and rationale.
    private func onAppearAction() { // skipcq: SW-R1002 — reviewed; complexity acceptable for this onAppear setup
        isOAuthAuthenticated = oauthService.isAuthenticated
        isCLIAuthenticated = !oauthService.isAuthenticated && oauthService.hasAnyToken
        log("【SettingsView.onAppear】auth=\(oauthService.isAuthenticated) hasToken=\(oauthService.hasAnyToken)", category: .general)
        log("【SettingsView.onAppear】settings=\(ObjectIdentifier(settings)) betaChannel=\(settings.betaChannel)", category: .general)

        // Cancel before reassigning — guards against the rapid open→open case
        // where the panel is re-shown without an intervening onDisappear, which
        // would otherwise silently leak the prior task.
        signInTask?.cancel()
        signInTask = Task { @MainActor in
            for await success in oauthService.makeSignInStream() {
                log("【SettingsView.signInStream】success=\(success) — updating auth state", category: .general)
                isOAuthAuthenticated = success
                isCLIAuthenticated = !success && oauthService.hasAnyToken
                log("【SettingsView.signInStream】OAuth=\(isOAuthAuthenticated) CLI=\(isCLIAuthenticated)", category: .general)
                isSigningIn = false
            }
        }

        signOutTask?.cancel()
        signOutTask = Task { @MainActor in
            for await _ in oauthService.makeSignOutStream() {
                log("【SettingsView.signOutStream】didSignOut — hasAnyToken=\(oauthService.hasAnyToken)", category: .general)
                isOAuthAuthenticated = false
                isCLIAuthenticated = oauthService.hasAnyToken
                log("【SettingsView.signOutStream】OAuth=\(isOAuthAuthenticated) CLI=\(isCLIAuthenticated)", category: .general)
            }
        }
    }

    // MARK: - Header

    /// Top bar with back button and "Settings" title.
    private var headerBar: some View {
        HStack {
            Button(action: onBack, label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .medium))
                    Text("Settings").font(.headline)
                }
                .foregroundColor(.primary)
            })
            .buttonStyle(.plain)
            Spacer()
        }
        .padding(.horizontal, RBSpacing.md).padding(.top, 12).padding(.bottom, 8)
    }

    // MARK: - Helpers

    /// Applies or removes the Login Item entry based on `enabled`, then
    /// syncs `launchAtLogin` to the actual system state via `LoginItem.isEnabled`.
    /// On success the value is unchanged; on failure the toggle snaps back automatically.
    func applyLaunchAtLogin(_ enabled: Bool) {
        log("【SettingsView.applyLaunchAtLogin】enabled=\(enabled)", category: .general)
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
        log("【SettingsView.applyLaunchAtLogin】result LoginItem.isEnabled=\(LoginItem.isEnabled)", category: .general)
    }

    /// Initiates the OAuth sign-in flow via the injected `oauthService`.
    ///
    /// `makeSignInURL()` builds the authorization URL and stores the CSRF nonce.
    /// Opening the browser is the app layer's responsibility — `OAuthService` (Core)
    /// has no AppKit dependency and cannot call `NSWorkspace` directly.
    func signInWithGitHub() {
        log("【SettingsView.signInWithGitHub】isSigningIn=true", category: .general)
        isSigningIn = true
        if let url = oauthService.makeSignInURL() {
            NSWorkspace.shared.open(url)
        } else {
            log("【SettingsView.signInWithGitHub】makeSignInURL returned nil — aborting", category: .general)
            isSigningIn = false
        }
    }

    /// Signs out of GitHub via the injected `oauthService`.
    func signOutOfGitHub() {
        log("【SettingsView.signOutOfGitHub】calling oauthService.signOut()", category: .general)
        oauthService.signOut()
    }
}
