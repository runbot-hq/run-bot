// GitHubAuthSource.swift
// GitHubClient

// MARK: - GitHubAuthSource

/// The explicit authentication source selected by the user.
///
/// Persisted via `AppStorage` / `UserDefaults` so the choice survives relaunches.
/// No migration is required because no released installation has this preference.
///
/// ## State model
/// The three cases map to three mutually exclusive app states:
/// - `.oauth`           — Keychain token present and selected.
/// - `.environment`     — env var selected (token may be `.checking`/`.unavailable`/`.available`).
/// - `.unauthenticated` — no source selected; env toggled off while OAuth is signed out.
///
/// `.unauthenticated` is not persisted on fresh installs — the default fallback
/// in `GitHubAuthentication.init` is `.oauth`. It is only written when the user
/// explicitly turns environment auth off while OAuth is signed out.
public enum GitHubAuthSource: String, Codable, Sendable, CaseIterable {
    /// Use the environment token (`GH_TOKEN` / `GITHUB_TOKEN`) for all requests.
    case environment
    /// Use the OAuth token stored in the Keychain for all requests.
    case oauth
    /// No authentication source is active. The user has explicitly opted out of
    /// both OAuth and environment auth. Requests will fail with 401.
    case unauthenticated
}
