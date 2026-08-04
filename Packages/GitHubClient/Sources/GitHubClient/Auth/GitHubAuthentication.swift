// GitHubAuthentication.swift
// GitHubClient

import Foundation
import Observation

// MARK: - GitHubAuthentication

/// Observable authentication state for the GitHubClient.
///
/// Holds the user-selected authentication source, the discovered environment-token
/// state, and the current OAuth flow state. This is the single source of truth that
/// both the Settings UI and the request resolver read from.
///
/// `selectedSource` is persisted to `UserDefaults` so the explicit choice survives
/// relaunches. No migration is needed because no released installation has this key.
///
/// ## Mutation rules
/// - `setOAuthState(_:)` — use for **transitional** OAuth state changes (signingIn,
///   signingOut, failed, signedOut). Does NOT touch `selectedSource`.
/// - `recordOAuthSignIn(username:)` — use **only** when OAuth sign-in succeeds.
///   Persists `.oauth` as `selectedSource` and clears env auth invariant.
/// - `syncOAuthState(isAuthenticated:)` — passive re-sync on Settings appear;
///   updates `oauthState` WITHOUT touching the persisted `selectedSource`.
/// - `setSelectedSource(_:)` — explicit user selection; persisted immediately.
/// - `setEnvironmentState(_:)` — updates discovery state; no source side-effects.
///
/// ## Usage
/// - Inject into SwiftUI via `@Environment` or pass as a direct dependency.
/// - Mutate only through the `set*` / `record*` / `sync*` methods above.
@MainActor
@Observable
public final class GitHubAuthentication {

    // MARK: - UserDefaults key

    /// The `UserDefaults` key used to persist `selectedSource` across launches.
    static let defaultsKey = "com.runbot.GitHubAuthSource"

    // MARK: - Published state

    /// The explicit authentication source selected by the user.
    /// Persisted across launches; defaults to `.unauthenticated` on fresh installations
    /// so both the environment toggle and the OAuth sign-in button are enabled until the
    /// user makes an explicit choice.
    public private(set) var selectedSource: GitHubAuthSource

    /// The current state of the environment token discovery.
    public private(set) var environmentState: EnvironmentTokenState

    /// The current state of the OAuth authentication flow.
    public private(set) var oauthState: OAuthState

    // MARK: - Init

    /// Creates an instance, restoring `selectedSource` from `UserDefaults`.
    ///
    /// - Parameters:
    ///   - environmentState: Initial env-token state. Defaults to `.checking`.
    ///   - oauthState: Initial OAuth state. Defaults to `.signedOut`.
    ///   - defaults: The `UserDefaults` instance used for source persistence.
    ///     Defaults to `.standard`; override in tests to avoid polluting the
    ///     real defaults database.
    public init(
        environmentState: EnvironmentTokenState = .checking,
        oauthState: OAuthState = .signedOut,
        defaults: UserDefaults = .standard
    ) {
        self._defaults = defaults
        let raw = defaults.string(forKey: Self.defaultsKey)
        // Fresh installs default to .unauthenticated (not .oauth) so both the
        // environment toggle and the OAuth sign-in button are enabled in the third
        // UI state (#2172 / #2456). .oauth is written only by recordOAuthSignIn().
        self.selectedSource = raw.flatMap(GitHubAuthSource.init(rawValue:)) ?? .unauthenticated
        self.environmentState = environmentState
        self.oauthState = oauthState
    }

    // MARK: - Mutations

    /// Sets the user-selected authentication source and persists it.
    ///
    /// This is the authoritative write path for explicit user selections.
    /// Do not assign `selectedSource` directly.
    public func setSelectedSource(_ source: GitHubAuthSource) {
        selectedSource = source
        _defaults.set(source.rawValue, forKey: Self.defaultsKey)
    }

    /// Updates the environment-token discovery state.
    ///
    /// Pure state update — no effect on `selectedSource`.
    public func setEnvironmentState(_ state: EnvironmentTokenState) {
        environmentState = state
    }

    /// Updates the OAuth flow state for **transitional** changes.
    ///
    /// Use this for: `.signingIn`, `.signingOut`, `.failed`, `.signedOut`.
    /// Does **not** touch `selectedSource` — use `recordOAuthSignIn(username:)`
    /// when a sign-in succeeds so the persisted choice is updated correctly.
    ///
    /// - Important: Never call this with `.signedIn` from `onAppearAction` or
    ///   any passive re-sync path — use `syncOAuthState(isAuthenticated:)` instead.
    public func setOAuthState(_ state: OAuthState) {
        oauthState = state
    }

    /// Records a **successful** OAuth sign-in.
    ///
    /// - Sets `oauthState` to `.signedIn(username:)`.
    /// - Persists `selectedSource` as `.oauth` — sign-in success always activates OAuth.
    /// - Clears any env-auth invariant: environment cannot remain selected while
    ///   OAuth is signed in.
    ///
    /// This is the only path that should write `.oauth` to `selectedSource` as
    /// a side-effect of OAuth flow progression. All other OAuth state transitions
    /// use `setOAuthState(_:)` which does not touch `selectedSource`.
    public func recordOAuthSignIn(username: String?) {
        oauthState = .signedIn(username: username)
        setSelectedSource(.oauth)
    }

    /// Passively re-syncs `oauthState` from the live Keychain state, and
    /// reconciles `selectedSource` so that Keychain presence is authoritative.
    ///
    /// Called from `onAppearAction()` and `AppState.start()` to reflect the
    /// current Keychain credential state. When a Keychain token exists,
    /// `selectedSource` is set to `.oauth` — the Keychain is authoritative.
    /// When no Keychain token exists, `.oauth` is reverted to `.unauthenticated`
    /// so both methods are available, but an explicit `.environment` choice is
    /// preserved.
    ///
    /// - Parameter isAuthenticated: `true` if `oauthService.isAuthenticated`.
    public func syncOAuthState(isAuthenticated: Bool) {
        if isAuthenticated {
            oauthState = .signedIn(username: nil)

            if selectedSource != .oauth {
                setSelectedSource(.oauth)
            }
        } else {
            oauthState = .signedOut

            if selectedSource == .oauth {
                setSelectedSource(.unauthenticated)
            }
        }
    }

    // MARK: - Private

    /// The `UserDefaults` instance used for persisting `selectedSource`.
    private let _defaults: UserDefaults
}
