// GitHubScope.swift
// GitHubClient

import Foundation

// MARK: - Scope

/// Represents a GitHub monitoring scope — either a single repository or an entire organisation.
public enum Scope {
    /// A single repository identified by owner and repo name.
    case repo(owner: String, name: String)
    /// An entire GitHub organisation.
    case org(String)

    /// Parses a raw scope string (e.g. "owner/repo" or "orgname") into a typed `Scope`.
    /// Returns `nil` for empty or malformed input.
    public static func parse(_ string: String) -> Scope? {
        let parts = string.split(separator: "/", maxSplits: 1).map(String.init)
        if parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty {
            return .repo(owner: parts[0], name: parts[1])
        }
        if parts.count == 1, !parts[0].isEmpty {
            return .org(parts[0])
        }
        return nil
    }

    /// The GitHub REST API path prefix for this scope.
    /// e.g. "repos/owner/repo" or "orgs/orgname"
    public var apiPrefix: String {
        switch self {
        case .repo(let owner, let name): return "repos/\(owner)/\(name)"
        case .org(let org): return "orgs/\(org)"
        }
    }
}
