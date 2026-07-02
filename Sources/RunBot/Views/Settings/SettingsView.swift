// SettingsView.swift
// RunBot
import AppKit
import AppUpdater
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
    /// Defaults to `LocalRunnerStore.shared` so call sites that don't own the actor still compile.
    var localRunnerStore: LocalRunnerStore = .shared
    /// OAuth service injected from `AppDelegate`.
    /// Typed to protocol so tests can supply a stub without the live singleton.
    var oauthService: any OAuthServiceProtocol
    /// Runner lifecycle service injected from `AppDelegate` and forwarded into `LocalRunnersView`.
    /// Typed to protocol so tests can supply a stub without spawning real `svc.sh` processes.
    /// No default -- callers must supply the `AppDelegate`-owned instance explicitly.
    var lifecycleService: any RunnerLifecycleServiceProtocol

    // MARK: - Injected services
    /// App-wide preference store (polling interval, popover arrow, beta channel, etc.).
    /// Injected as a concrete reference; `@Observable` types don't need `@State` wrapping.
    let settings: AppPreferencesStore
    /// Notification preference store (notify-on-success, notify-on-failure).
    /// Injected as a concrete reference; `@Observable` types don't need `@State` wrapping.
    let notifications: NotificationPreferences
    /// Observable runner state — read to display the update available banner.
    /// Injected explicitly from `AppDelegate`; no default because `RunnerState` has no
    /// singleton — the single instance lives on `AppDelegate.runnerState`.
    let runnerState: RunnerState
    /// Auto-update driver injected from `AppDelegate`, used by the Install &
    /// Relaunch action in `aboutSection`. No default — the single instance lives
    /// on `AppDelegate.autoUpdater`.
    let autoUpdater: AppUpdater

    // MARK: - Local UI state
    /// Mirrors `LoginItem.isEnabled`; toggled by the Launch at Login switch.
    @State var launchAtLogin = LoginItem.isEnabled
    /// `true` when a valid OAuth token is stored in Keychain.
    @State var isOAuthAuthenticated = (Keychain.token != nil)
    /// `true` when a CLI token (GH_TOKEN / GITHUB_TOKEN) is present but no OAuth token.
    @State var isCLIAuthenticated = (Keychain.token == nil && githubToken() != nil)
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
    /// - Parameters:
    ///   - runnerState: The single `RunnerState` instance owned by `AppDelegate`.
    ///     Must be supplied explicitly — `RunnerState` has no singleton.
    init(
        onBack: @escaping () -> Void,
        oauthService: any OAuthServiceProtocol,
        lifecycleService: any RunnerLifecycleServiceProtocol,
        runnerState: RunnerState,
        autoUpdater: AppUpdater,
        localRunnerStore: LocalRunnerStore = .shared,
        settings: AppPreferencesStore = .shared,
        notifications: NotificationPreferences = .shared
    ) {
        self.onBack = onBack
        self.localRunnerStore = localRunnerStore
        self.oauthService = oauthService
        self.settings = settings
        self.notifications = notifications
        self.lifecycleService = lifecycleService
        self.runnerState = runnerState
        self.autoUpdater = autoUpdater
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
        // Attaching them to `settingsBody` caused needless Keychain re-reads and
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
                ScopesView(onBack: { showScopes = false })
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

    /// Runs on `.onAppear`: refreshes auth state and starts sign-in / sign-out listeners.
    private func onAppearAction() { // skipcq: SW-R1002 — reviewed; complexity acceptable for this onAppear setup
        let keychainToken = Keychain.token
        let envToken = githubToken()
        isOAuthAuthenticated = (keychainToken != nil)
        isCLIAuthenticated = (keychainToken == nil && envToken != nil)
        #if DEBUG
        // swiftlint:disable:next line_length
        log("SettingsView › onAppear — Keychain.token=\(keychainToken.map { "present(len=\($0.count))" } ?? "nil") githubToken=\(envToken.map { "present(len=\($0.count))" } ?? "nil") isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
        #endif

        // Replace the old `onCompletion` closure with a structured async stream.
        // This avoids the retained-closure / multiple-subscriber hazard (P9).
        signInTask = Task { @MainActor in
            for await success in oauthService.makeSignInStream() {
                log("SettingsView › signInStream — success=\(success), updating auth state")
                isOAuthAuthenticated = success
                isCLIAuthenticated = !success && githubToken() != nil
                log("SettingsView › signInStream — isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
                isSigningIn = false
            }
        }

        signOutTask = Task { @MainActor in
            for await _ in oauthService.makeSignOutStream() {
                let postToken = githubToken()
                log("SettingsView › didSignOut — githubToken post-signout=\(postToken.map { "present(len=\($0.count))" } ?? "nil")")
                isOAuthAuthenticated = false
                isCLIAuthenticated = postToken != nil
                log("SettingsView › didSignOut — isOAuthAuthenticated=\(isOAuthAuthenticated) isCLIAuthenticated=\(isCLIAuthenticated)")
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
