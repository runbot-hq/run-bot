// AppDelegate+OAuthCallback.swift
// RunBot

import AppKit
import GitHubClient
import RunBotCore

/// AppDelegate extension handling the OAuth callback URL delivered by the OS.
extension AppDelegate {

    // MARK: - OAuth URL callback

    /// Handles the OAuth callback URL (`runbot://oauth/…`) delivered by the OS
    /// after the user authorises the GitHub OAuth flow in the browser.
    /// - Parameters:
    ///   - _: The NSApplication instance (unused).
    ///   - urls: The array of URLs opened by the OS; only the first matching OAuth URL is consumed.
    func application(_ _: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: {
            $0.scheme == GitHubConstants.oauthScheme && $0.host == GitHubConstants.oauthHost
        }) else { return }
        oauthService.handleCallback(url)
    }
}
