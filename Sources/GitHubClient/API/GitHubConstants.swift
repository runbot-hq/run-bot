// GitHubConstants.swift
// GitHubClient
import Foundation

public enum GitHubConstants {
    public static let apiBase = "https://api.github.com" // NOSONAR
    public static let base = "https://github.com" // NOSONAR
    public static let oauthRedirectURI = "runbot://oauth/callback" // NOSONAR
    public static let oauthScheme = "runbot" // NOSONAR
    public static let oauthHost = "oauth" // NOSONAR
    public static let userOrgsPath = "/user/orgs" // NOSONAR
    public static let userReposPath = "/user/repos" // NOSONAR
    public static let maxPageSize = 100
    public static let activeRunsPageSize = 50
}
