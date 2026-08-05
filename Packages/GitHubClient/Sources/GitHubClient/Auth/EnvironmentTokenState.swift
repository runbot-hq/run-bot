// EnvironmentTokenState.swift
// GitHubClient

// MARK: - EnvironmentTokenState

/// The discovered state of the environment token (`GH_TOKEN` / `GITHUB_TOKEN`).
public enum EnvironmentTokenState: Equatable, Sendable {
    /// Discovery is still in progress (e.g. the login-shell probe is running).
    case checking
    /// No token was found in the process environment or login shell.
    case unavailable
    /// A token was found via the named environment variable.
    case available(variable: Variable)

    // MARK: - Variable

    /// The specific environment variable that contained the token.
    public enum Variable: Equatable, Sendable {
        /// `GH_TOKEN` was set in the environment.
        case ghToken
        /// `GITHUB_TOKEN` was set in the environment.
        case githubToken
    }
}
