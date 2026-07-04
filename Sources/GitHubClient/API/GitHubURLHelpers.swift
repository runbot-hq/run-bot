// GitHubURLHelpers.swift
// GitHubClient
import Foundation

// MARK: - GitHub URL utilities

/// Extracts the `owner/repo` or `orgName` scope string from a GitHub HTML URL string.
///
/// - For repo-scoped URLs (`https://github.com/owner/repo`) returns `"owner/repo"`.
/// - For org-scoped URLs (`https://github.com/myorg`) returns `"myorg"`.
/// - Returns `nil` if `urlString` is nil, not a valid URL, or has no path components.
///
/// This is the canonical implementation shared across `RunBotCore`. Call sites that
/// already hold a typed `URL` value should prefer the `URL`-typed overload `scopeFromUrl(_:)`
/// to avoid a redundant `absoluteString` → `URL` round-trip.
///
/// - Note: `pathComponents` on `URL` includes `"/"` as the first component for absolute
///   URLs; the filter step removes it and empty strings so index 0 is always the owner/org name.
public func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString) else { return nil }
    return scopeFromUrl(url)
}

/// Extracts the `owner/repo` or `orgName` scope string from a typed `URL`.
///
/// - For repo-scoped URLs (`https://github.com/owner/repo`) returns `"owner/repo"`.
/// - For org-scoped URLs (`https://github.com/myorg`) returns `"myorg"`.
/// - Returns `nil` if the URL has no non-slash, non-empty path components.
///
/// This overload avoids the `absoluteString` → `URL(string:)` round-trip at call
/// sites that already hold a typed `URL` (e.g. `RunnerModel.gitHubUrl`).
///
/// - Note: `pathComponents` on `URL` includes `"/"` as the first component for absolute
///   URLs; the filter step removes both `"/"` and empty strings (which can appear in
///   malformed paths such as `https://github.com//acme`) so index 0 is always the
///   owner/org name and `parts.count` reflects only meaningful path segments.
public func scopeFromUrl(_ url: URL) -> String? {
    let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    if parts.count >= 2 { return parts[0] + "/" + parts[1] }
    if parts.count == 1 { return parts[0] }
    return nil
}
