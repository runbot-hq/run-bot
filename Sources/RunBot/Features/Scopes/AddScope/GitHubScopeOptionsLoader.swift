// GitHubScopeOptionsLoader.swift
// RunBot

import GitHubClient

// MARK: - GitHubScopeOptions

/// Typed result of a combined repositories + organisations fetch.
///
/// `Sendable` so the value can be handed from a background `Task` to `@MainActor`
/// state writes without a Swift 6 concurrency warning.
struct GitHubScopeOptions: Sendable {
    /// `owner/repo` full names visible to the authenticated user.
    let repositories: [String]
    /// Organisation login names visible to the authenticated user.
    let organizations: [String]

    /// `true` when both arrays are empty — indicates a fetch failure or no credentials.
    var isEmpty: Bool {
        repositories.isEmpty && organizations.isEmpty
    }
}

// MARK: - GitHubScopeOptionsLoader

/// Single point of truth for fetching GitHub scope options (repos + orgs).
///
/// Both `AddRunnerSheet` and `AddScopeSheet` consume this loader so the two
/// sheets cannot diverge in what data they present. Previously each sheet
/// maintained its own fetch implementation; this type replaces both.
///
/// ## Usage
/// ```swift
/// let options = await GitHubScopeOptionsLoader.load()
/// repos = options.repositories
/// orgs  = options.organizations
/// ```
enum GitHubScopeOptionsLoader {
    /// Fetches repositories and organisations sequentially and returns a typed result.
    ///
    /// Runs `fetchUserRepos()` then `fetchUserOrgs()` on the cooperative thread pool.
    /// Returns an `GitHubScopeOptions` with empty arrays on network or auth failure —
    /// callers are responsible for surfacing an appropriate error state.
    static func load() async -> GitHubScopeOptions {
        let repositories = await fetchUserRepos()
        let organizations = await fetchUserOrgs()
        return GitHubScopeOptions(
            repositories: repositories,
            organizations: organizations
        )
    }
}
