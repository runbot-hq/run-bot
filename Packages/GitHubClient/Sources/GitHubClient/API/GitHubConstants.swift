// GitHubConstants.swift
// GitHubClient
import Foundation

// MARK: - Shared GitHub URI constants
//
// Centralises the two base URLs that appear across transport, OAuth, scanner,
// and view layers so SonarCloud no longer flags them as hardcoded URIs.
// All consumers must import this file (same module — no import needed).

/// Shared base URLs and path constants used across GitHub transports, OAuth, and links.
public enum GitHubConstants {
    /// Base URL for the GitHub REST API.
    public static let apiBase = "https://api.github.com" // NOSONAR — intentional centralisation of hardcoded URI
    /// Base URL for the GitHub web interface.
    public static let base = "https://github.com" // NOSONAR — intentional centralisation of hardcoded URI

    // MARK: - OAuth URI constants

    /// The custom-scheme redirect URI registered for the RunBot OAuth app.
    /// GitHub redirects to this URI after the user authorises (or denies) sign-in.
    /// Must match the value registered in the GitHub OAuth app settings exactly.
    public static let oauthRedirectURI = "runbot://oauth/callback" // NOSONAR — intentional centralisation of hardcoded URI
    /// The URL scheme component of `oauthRedirectURI`.
    /// Used by `AppDelegate.application(_:open:)` to filter incoming URLs.
    public static let oauthScheme = "runbot" // NOSONAR — intentional centralisation of hardcoded URI
    /// The host component of `oauthRedirectURI`.
    /// Used by `AppDelegate.application(_:open:)` alongside `oauthScheme`.
    public static let oauthHost = "oauth" // NOSONAR — intentional centralisation of hardcoded URI

    // MARK: - User API path constants

    /// GitHub REST API path for listing organisations the authenticated user belongs to.
    /// Query parameters (e.g. `per_page`) are appended by the caller — see `GitHubConstants.maxPageSize`.
    public static let userOrgsPath = "/user/orgs" // NOSONAR — intentional centralisation of hardcoded URI
    /// GitHub REST API path for listing repositories visible to the authenticated user.
    /// Query parameters (e.g. `per_page`, `sort`) are appended by the caller — see `GitHubConstants.maxPageSize`.
    public static let userReposPath = "/user/repos" // NOSONAR — intentional centralisation of hardcoded URI

    // MARK: - Pagination constants

    /// Maximum page size accepted by the GitHub REST API (`per_page` parameter).
    /// GitHub API hard cap — do not increase beyond 100.
    /// Used for jobs, branches, orgs, and repos where all results are required.
    public static let maxPageSize = 100
    /// Page size used for active workflow-run queries (in_progress / queued).
    /// Smaller than `maxPageSize` because active run counts are typically low.
    public static let activeRunsPageSize = 50
}
