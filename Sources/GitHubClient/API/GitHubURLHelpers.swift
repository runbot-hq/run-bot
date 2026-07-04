// GitHubURLHelpers.swift
// GitHubClient
import Foundation

public func scopeFromHtmlUrl(_ urlString: String?) -> String? {
    guard let urlString,
          let url = URL(string: urlString) else { return nil }
    return scopeFromUrl(url)
}

public func scopeFromUrl(_ url: URL) -> String? {
    let parts = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    if parts.count >= 2 { return parts[0] + "/" + parts[1] }
    if parts.count == 1 { return parts[0] }
    return nil
}
