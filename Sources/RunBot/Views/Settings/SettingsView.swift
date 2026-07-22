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
// AppDelegate.resizeAndRepositionPanel() clamps the panel at 85% visibleFrame.
// No extra cap needed here — the panel cap IS the scroll boundary.
// ❌ NEVER move headerBar inside the ScrollView.
// ❌ NEVER replace .infinity with a fixed number.
// ❌ NEVER use GeometryReader for the height.
// ❌ NEVER add idealHeight to the root frame.
//
// WIDTH CONTRACT:
// .frame(idealWidth: 480) — only idealWidth needed. NSPanel handles bounds.
// ❌ NEVER remove idealWidth: 480.
//
// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
// is major major major.

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
    /// Injected rather than read from `appState` because `AppState` does not expose
    /// a `scopeStore` accessor — scopes are managed independently of runner state.
    /// Runners flow through `AppState.runnerState` (owned by `LocalRunnerStore`);
    /// scopes have no equivalent path, so direct injection is the only option.
    let scopeStore: ScopeStore

    // MARK: - Convenience accessors (avoid noisy appState.x at every call site)
    // ❌ NOT a leakage oversight — these are `internal` by Swift necessity, not by choice.
    // Swift `private` does not cross file boundaries; `SettingsView+Sections.swift`
    // (a separate file) needs these. `fileprivate` is also per-file in Swift, so it
    // would not help either. `internal` is the tightest access level available for
    // cross-file use within the same type. The intent is: readable by SettingsView
    // extension files in this module; not part of the public API of SettingsView.
    // If you are tempted to tighten these to `private`, note that Swift will not
    // allow it — the compiler will reject it at SettingsView+Sections.swift.

    /// Forwarded OAuth service from `appState`. Internal by necessity — see NOTE above.
    var oauthService: any OAuthServiceProtocol { appState.oauthService }
    /// Forwarded lifecycle service from `appState`. Internal by necessity — see NOTE above.
    var lifecycleService: any RunnerLifecycleServiceProtocol { appState.lifecycleService }
    /// Forwarded runner state from `appState`. Internal by necessity — see NOTE above.
    var runnerState: RunnerState { appState.runnerState }
    /// Forwarded auto-updater from `appState`. Internal by necessity — see NOTE above.
    var autoUpdater: AppUpdater { appState.autoUpdater }

    // MARK: - Local UI state

    /// Mirrors `LoginItem.isEnabled`; toggled by the Launch at Login switch.
    @State var launchAtLogin = LoginItem.isEnabled

    /// `true` when a valid OAuth token is stored in the keychain.
    /// Seeded from `oauthService.isAuthenticated` in `init` to avoid a false
    /// flash before `.onAppear` fires. Kept in sync by `onAppearAction()`'s streams.
    @State var isOAuthAuthenticated: Bool

    /// `true` when a CLI token (GH_TOKEN / GITHUB_TOKEN) is present but no OAuth token.
    /// Seeded from `oauthService` in `init` to avoid a false flash before `.onAppear`.
    @State var isCLIAuthenticated: Bool

    /// `true` while the OAuth sign-in flow is in progress.
    @State var isSigningIn = false

    /// Retains the sign-in listener Task so it is cancelled when the view disappears.
    @State private var signInTask: Task<Void, Never>?

    /// Retains the sign-out listener Task so it is cancelled when the view disappears.
    @State private var signOutTask: Task<Void, Never>?

    /// `true` while `LocalRunnersView` is displayed instead of the main settings scroll.
    @State var showLocalRunners = false

    /// `true` while `ScopesView` is displayed instead of the main settings scroll.
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

    // MARK: - Computed properties

    /// Full version string (preserves pre-release suffixes like `-beta.1`).
    var appVersion: String { Bundle.main.rbVersionString }

    /// Build number from `CFBundleVersion`.
    var appBuild: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }

    // MARK: - Body

    /// Root view: swaps between the settings scroll, `LocalRunnersView`, and `ScopesView`.
    var body: some View {
        log("【SettingsView.body】rendered — settings=\(ObjectIdentifier(settings)) betaChannel=\(settings.betaChannel)", category: .general)
        // Lifecycle modifiers live on the root (wrapping all branches) so
        // onAppearAction()/onDisappear fire only when the settings panel itself
        // opens/closes — NOT on every navigation to LocalRunnersView/ScopesView.
        // Attaching them to `settingsBody` caused needless re-reads and
        // Task recreation on every back-navigation.
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
        .task {
            // `onAppearAction` checks `oauthService.hasAnyToken` which reads
            // `ProcessInfo.processInfo.environment` directly. When the app is
            // launched via Finder (not a shell), env vars like `GH_TOKEN` are
            // absent from the process environment even if exported in the
            // user's shell profile — so `hasAnyToken` returns `false` and
            // `isCLIAuthenticated` stays unset, leaving the status light dark.
            //
            // `TokenCache.token()` runs the full resolution chain including a
            // login-shell fallback (`/bin/zsh -lc 'echo $GH_TOKEN'`), so it
            // finds the token regardless of launch method. We call it here
            // once on appear and flip `isCLIAuthenticated` when it resolves.
            //
            // Guard: skip if the user is already signed in via OAuth — in that
            // case neither status text nor the green dot reference `isCLIAuthenticated`.
            guard !isOAuthAuthenticated else { return }
            let token = await appState.github.token()
            isCLIAuthenticated = token != nil
            log("【SettingsView.task】github.token() resolved — isCLIAuthenticated=\(isCLIAuthenticated)", category: .general)
        }
        // FIX #2223 / #2216: run the update check via a SwiftUI-owned .task so it
        // fires on every entry path — including cold-open → Settings, where
        // .onAppear on an NSPanel-hosted root Group is not guaranteed to fire.
        //
        // Previously, onAppearAction() manually spawned updateCheckTask (an
        // unstructured Task) and onDisappear cancelled it. That covered
        // Main → Settings but missed the cold-open path.
        //
        // SwiftUI .task starts when the view appears and is automatically
        // cancelled when the view disappears — no @State handle or manual
        // cancel needed. This is strictly simpler and covers both paths:
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
    /// HEIGHT CONTRACT: headerBar is OUTSIDE the ScrollView — back button always visible.
    /// ❌ NEVER move headerBar inside the ScrollView.
    /// ❌ NEVER replace .infinity with a fixed number.
    /// If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
    /// UNDER ANY CIRCUMSTANCE. The regression we get when this comment is removed
    /// is major major major.
    private var settingsBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            // maxHeight: .infinity — fills all space the panel gives us.
            // AppDelegate caps the panel at 85% visibleFrame. That IS the limit.
            // ❌ NEVER move headerBar inside this ScrollView.
            // ❌ NEVER replace .infinity with a fixed number.
            // If you are an agent or human, DO NOT REMOVE THIS COMMENT, YOU ARE NOT ALLOWED
            // UNDER ANY CIRCUMSTANCE.
            ScrollView(.vertical, showsIndicators: true) {
                sectionsStack
            }
            .frame(maxHeight: .infinity)
        }
        .frame(idealWidth: 480, maxWidth: .infinity)
    }

    /// Vertical stack of all settings sections.
    ///
    /// Order: Account → Management → General → About
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
        .padding(.bottom, 16)
    }

    /// Runs on `.onAppear`: re-syncs auth state from `oauthService` and starts sign-in /
    /// sign-out listeners.
    ///
    /// Auth state is already seeded from `oauthService` in `init`, so this is a no-op
    /// on the first render. On subsequent appears (e.g. after a hide/show cycle) it
    /// re-reads the current state and re-registers the stream tasks.
    ///
    /// Update checking is intentionally NOT done here — it is owned by the SwiftUI
    /// .task modifier in body, which covers both cold-open and navigation paths
    /// (fix #2223). All tasks are cancelled before reassignment so a rapid open→open
    /// cycle cannot leak prior stream listeners.
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
