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
    /// Defaults to `LocalRunnerStore.shared` — safe only after `AppState.start()` has called
    /// `LocalRunnerStore.configure(viewModel:)`. In production this is guaranteed because
    /// `SettingsView` is only constructed after `applicationDidFinishLaunching` completes.
    /// ⚠️ Do NOT use this default in SwiftUI Previews or unit tests — supply a configured
    /// store explicitly to avoid the `fatalError` in `LocalRunnerStore.shared`.
    var localRunnerStore: LocalRunnerStore = .shared
    // MARK: - Injected services
    /// Single coordinator for all domain-level state (oauth, lifecycle, runners, updater).
    /// Replaces four separate injected objects — see issue #2040.
    /// `AppState` has no singleton — the single instance is owned by `AppDelegate`
    /// and must be supplied explicitly by the caller. There is no safe default.
    let appState: AppState
    /// App-wide preference store (polling interval, popover arrow, beta channel, etc.).
    /// Injected as a concrete reference; `@Observable` types don't need `@State` wrapping.
    let settings: AppPreferencesStore
    /// Notification preference store (notify-on-success, notify-on-failure).
    /// Injected as a concrete reference; `@Observable` types don't need `@State` wrapping.
    let notifications: NotificationPreferences

    // MARK: - Convenience accessors (avoid noisy appState.x at every call site)
    // NOTE: `internal` (not `private`) — Swift `private` does not cross file boundaries;
    // `SettingsView+Sections.swift` reads these from a separate file.
    /// Forwarded OAuth service from `appState`.
    var oauthService: any OAuthServiceProtocol { appState.oauthService }
    /// Forwarded lifecycle service from `appState`.
    var lifecycleService: any RunnerLifecycleServiceProtocol { appState.lifecycleService }
    /// Forwarded runner state from `appState`.
    var runnerState: RunnerState { appState.runnerState }
    /// Forwarded auto-updater from `appState`.
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
    /// - Parameters:
    ///   - appState: The single domain coordinator owned by `AppDelegate`.
    init(
        onBack: @escaping () -> Void,
        appState: AppState,
        localRunnerStore: LocalRunnerStore = .shared,
        settings: AppPreferencesStore = .shared,
        notifications: NotificationPreferences = .shared
    ) {
        self.onBack = onBack
        self.appState = appState
        self.localRunnerStore = localRunnerStore
        self.settings = settings
        self.notifications = notifications
        _isOAuthAuthenticated = State(initialValue: appState.oauthService.isAuthenticated)
        _isCLIAuthenticated = State(initialValue: !appState.oauthService.isAuthenticated && appState.oauthService.hasAnyToken)
    }

    // MARK: - Computed properties
    /// Full version string (preserves pre-release suffixes like `-beta.1`).
    var appVersion: String { Bundle.main.rbVersionString }
    /// Build number from `CFBundleVersion`.
    var appBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // MARK: - Body
    /// Root view: swaps between the settings scroll, `LocalRunnersView`, and `ScopesView`.
    var body: some View {
        // Lifecycle modifiers live on the root (wrapping all branches) so
        // onAppearAction()/onDisappear fire only when the settings panel itself
        // opens/closes — NOT on every navigation to LocalRunnersView/ScopesView.
        // Attaching them to `settingsBody` caused needless re-reads and
        // Task recreation on every back-navigation.
        Group {
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
        .onDisappear {
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

    /// Runs on `.onAppear`: re-syncs auth state from `oauthService` and starts sign-in / sign-out listeners.
    ///
    /// Auth state is already seeded from `oauthService` in `init`, so this is a no-op
    /// on the first render. On subsequent appears (e.g. after a hide/show cycle) it
    /// re-reads the current state and re-registers the stream tasks.
    private func onAppearAction() { // skipcq: SW-R1002 — reviewed; complexity acceptable for this onAppear setup
        isOAuthAuthenticated = oauthService.isAuthenticated
        isCLIAuthenticated = !oauthService.isAuthenticated && oauthService.hasAnyToken
        #if DEBUG
        let envToken = oauthService.hasAnyToken
        log("SettingsView › onAppear — isAuthenticated=\(oauthService.isAuthenticated) hasAnyToken=\(envToken) isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
        #endif

        signInTask = Task { @MainActor in
            for await success in oauthService.makeSignInStream() {
                log("SettingsView › signInStream — success=\(success), updating auth state")
                isOAuthAuthenticated = success
                isCLIAuthenticated = !success && oauthService.hasAnyToken
                log("SettingsView › signInStream — isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
                isSigningIn = false
            }
        }

        signOutTask = Task { @MainActor in
            for await _ in oauthService.makeSignOutStream() {
                log("SettingsView › didSignOut — hasAnyToken=\(oauthService.hasAnyToken)")
                isOAuthAuthenticated = false
                isCLIAuthenticated = oauthService.hasAnyToken
                log("SettingsView › didSignOut — isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
            }
        }
    }

    // MARK: - Header
    /// Top bar with back button and “Settings” title.
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
        LoginItem.setEnabled(enabled)
        launchAtLogin = LoginItem.isEnabled
    }

    /// Initiates the OAuth sign-in flow via the injected `oauthService`.
    ///
    /// `makeSignInURL()` builds the authorization URL and stores the CSRF nonce.
    /// Opening the browser is the app layer's responsibility — `OAuthService` (Core)
    /// has no AppKit dependency and cannot call `NSWorkspace` directly.
    func signInWithGitHub() {
        log("SettingsView › signInWithGitHub — isSigningIn=true")
        isSigningIn = true
        if let url = oauthService.makeSignInURL() {
            NSWorkspace.shared.open(url)
        } else {
            log("SettingsView › signInWithGitHub: makeSignInURL returned nil — aborting")
            isSigningIn = false
        }
    }

    /// Signs out of GitHub via the injected `oauthService`.
    func signOutOfGitHub() {
        log("SettingsView › signOutOfGitHub — calling oauthService.signOut()")
        oauthService.signOut()
    }
}
