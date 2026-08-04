// GitHubAuthSource.swift
// GitHubClient

// MARK: - GitHubAuthSource

/// The explicit authentication source selected by the user.
///
/// Persisted via `AppStorage` / `UserDefaults` so the choice survives relaunches.
/// No migration is required because no released installation has this preference.
public enum GitHubAuthSource: String, Codable, Sendable, CaseIterable {
    /// Use the environment token (`GH_TOKEN` / `GITHUB_TOKEN`) for all requests.
    case environment
    /// Use the OAuth token stored in the Keychain for all requests.
    case oauth
}
