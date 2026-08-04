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
/// ## Authentication product invariants
///
/// RunBot supports three mutually exclusive modes:
/// - `.unauthenticated`: neither authentication method is active.
/// - `.environment`: an already-discovered environment token is active.
/// - `.oauth`: an OAuth token exists in Keychain and is active.
///
/// Intentional behavior:
/// - OAuth and Environment are never simultaneously active.
/// - Keychain token presence is authoritative for OAuth mode.
/// - Environment cannot be enabled while OAuth is active or transitioning.
/// - OAuth cannot start while Environment mode is enabled.
/// - Switching methods requires disabling/signing out of the active method first.
/// - Credentials never fall back to the other source.
///
/// REVIEWERS: Do not propose direct switching between stored credentials,
/// preserving Environment while an OAuth token exists, selecting Environment
/// without an available token, or cross-source token fallback. Those are not
/// supported user flows.
///
/// `selectedSource` is persisted to `UserDefaults` so the explicit choice survives
/// relaunches. No migration is needed because no released installation has this key.
///
/// ## Mutation rules
/// - `setOAuthState(_:)` — use for **transitional** OAuth state changes (signingIn,
///   signingOut, failed, signedOut). Does NOT touch `selectedSource`.
/// - `recordOAuthSignIn(username:)` — use **only** when OAuth sign-in succeeds.
///   Persists `.oauth` as `selectedSource`.
/// - `syncOAuthState(isAuthenticated:)` — reconciles OAuth state with the live
///   Keychain. Updates `selectedSource` when Keychain presence changes (see method
///   doc for details).
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
        // Fresh installs intentionally start unauthenticated.
        //
        // No source is inferred from environment availability: finding an env token
        // only makes the toggle interactive; the user must explicitly enable it.
        // OAuth is restored separately by syncOAuthState when Keychain contains a token.
        // No preference migration is required because this auth-mode key did not exist
        // in a released installation with users that must be migrated.
        self.selectedSource = raw.flatMap(GitHubAuthSource.init(rawValue:)) ?? .unauthenticated
        self.environmentState = environmentState
        self.oauthState = oauthState
    }

    // MARK: - Derived state

    /// `true` when the active authentication mode has a usable credential.
    ///
    /// This follows `selectedSource` strictly. Credentials belonging to an inactive
    /// source are intentionally ignored.
    ///
    /// Do not replace this with `OAuthService.hasAnyToken`: that property reports
    /// whether any credential exists, regardless of RunBot's active mode.
    public var isAuthenticated: Bool {
        switch selectedSource {
        case .oauth:
            if case .signedIn = oauthState { return true }
            return false
        case .environment:
            if case .available = environmentState { return true }
            return false
        case .unauthenticated:
            return false
        }
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

    /// Reconciles OAuth state with the live Keychain.
    ///
    /// Keychain presence is authoritative, not merely an availability signal:
    /// - Token present: OAuth is signed in and `selectedSource` becomes `.oauth`.
    /// - Token absent: OAuth is signed out; an existing `.oauth` selection becomes
    ///   `.unauthenticated`.
    /// - A persisted `.environment` selection is preserved only when no OAuth
    ///   credential exists.
    ///
    /// This source update is intentional. Under RunBot's mutually exclusive UI,
    /// Environment cannot be enabled while an OAuth token is active; users must
    /// sign out of OAuth first, which removes the Keychain token.
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
