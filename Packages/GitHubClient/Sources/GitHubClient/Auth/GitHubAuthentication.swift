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
/// ## Usage
/// - Inject into SwiftUI via `@Environment` or pass as a direct dependency.
/// - Mutate only through the `set*` methods, which apply the correct side-effects
///   (persistence, source auto-selection after OAuth success).
@MainActor
@Observable
public final class GitHubAuthentication {

    // MARK: - UserDefaults key

    /// The `UserDefaults` key used to persist `selectedSource` across launches.
    static let defaultsKey = "com.runbot.GitHubAuthSource"

    // MARK: - Published state

    /// The explicit authentication source selected by the user.
    /// Persisted across launches; defaults to `.oauth` on fresh installations.
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
        self.selectedSource = raw.flatMap(GitHubAuthSource.init(rawValue:)) ?? .oauth
        self.environmentState = environmentState
        self.oauthState = oauthState
    }

    // MARK: - Mutations

    /// Sets the user-selected authentication source and persists it.
    ///
    /// This is the authoritative write path — do not assign `selectedSource` directly.
    public func setSelectedSource(_ source: GitHubAuthSource) {
        selectedSource = source
        _defaults.set(source.rawValue, forKey: Self.defaultsKey)
    }

    /// Updates the environment-token discovery state.
    public func setEnvironmentState(_ state: EnvironmentTokenState) {
        environmentState = state
    }

    /// Updates the OAuth state.
    ///
    /// When the new state is `.signedIn`, `selectedSource` is automatically
    /// switched to `.oauth` — a successful sign-in always activates OAuth.
    public func setOAuthState(_ state: OAuthState) {
        oauthState = state
        if case .signedIn = state {
            setSelectedSource(.oauth)
        }
    }

    // MARK: - Private

    /// The `UserDefaults` instance used for persisting `selectedSource`.
    private let _defaults: UserDefaults
}
